/// File-backed prompt store owning `library/` + `subscriptions/<feed>/` (WP1).
///
/// Pure-Dart, no Flutter. Layout contract:
/// * `<root>/library/*.md` — the user's own prompts, the source of truth.
///   Only ever written by [save] / [forkToLibrary].
/// * `<root>/subscriptions/<feed>/*.md` — fetched items mirrored by
///   [materializeSubscribedItem]. This side never overwrites `library/`;
///   editing a subscribed item forks it into `library/` ([forkToLibrary])
///   while the `source_feed` link is preserved.
///
/// Divergence note vs ARCHITECTURE.md section 1: the pseudocode there takes
/// a `FeedItem` in `materializeSubscribedItem`. `FeedItem` lives in
/// `lib/models/` and imports `package:flutter/material.dart`, which would
/// break the pure-Dart core, so WP1 takes primitive fields instead
/// (`id`/`title`/`body`/… following the same stable-ID conventions).
/// A thin WP2/WP3 adapter can bridge `FeedItem` → this signature.
///
/// Duplicate IDs: rejected on write ([DuplicateIdException] when a *different*
/// `library/` file already holds the id), namespaced on read (`library/`
/// wins over `subscriptions/`, first path wins within a scope). All
/// collisions are exposed via [duplicateIds] for diagnostics/tests.
///
/// Unreadable or malformed files never break a scan: they are skipped and
/// recorded in [skippedFiles].

import 'dart:async';
import 'dart:io';

import 'feed_config.dart';
import 'front_matter.dart' as fm;
import 'git_service.dart';
import 'prompt_doc.dart';

/// Thrown by [PromptStore.save] when a different `library/` file already
/// owns the doc id. Rename the doc id or remove the other file.
class DuplicateIdException implements Exception {
  final String id;
  final String existingPath;
  final String newPath;

  const DuplicateIdException({
    required this.id,
    required this.existingPath,
    required this.newPath,
  });

  @override
  String toString() => 'DuplicateIdException: id "$id" is already owned by '
      '$existingPath (rejected write to $newPath)';
}

enum _Scope { library, subscription }

class _Entry {
  final String path;
  final _Scope scope;
  final String? feedSlug; // set for subscription scope
  final PromptDoc doc;

  const _Entry({
    required this.path,
    required this.scope,
    required this.doc,
    this.feedSlug,
  });
}

/// File-backed store. Create with an optional [GitService] for auto-commit
/// on [save]; without one the store works local-only.
class PromptStore {
  static const String libraryDirName = 'library';
  static const String subscriptionsDirName = 'subscriptions';

  final GitService? _git;
  FeedConfig _feedConfig = const FeedConfig();

  String? _libraryRoot;
  Map<String, List<String>> _duplicateIds = const {};
  List<String> _skippedFiles = const [];

  StreamController<void>? _watchController;
  final List<StreamSubscription<FileSystemEvent>> _watchSubs =
      <StreamSubscription<FileSystemEvent>>[];
  Timer? _watchDebounce;

  PromptStore({GitService? git, FeedConfig feedConfig = const FeedConfig()})
      : _git = git,
        _feedConfig = feedConfig;

  /// Optional registry used to resolve subscription feed types for the
  /// [FeedType] filter of [listLocal]. Reload via `FeedConfig.load(root)`.
  set feedConfig(FeedConfig value) => _feedConfig = value;

  /// Ids seen under more than one path during the last scan:
  /// `id -> extra paths` (first/library path wins on read).
  Map<String, List<String>> get duplicateIds => _duplicateIds;

  /// Files skipped during the last scan (unreadable or malformed).
  List<String> get skippedFiles => _skippedFiles;

  bool get isInitialized => _libraryRoot != null;

  String get libraryRoot {
    final String? root = _libraryRoot;
    if (root == null) {
      throw StateError('promptlib: PromptStore.init() must be called first');
    }
    return root;
  }

  Directory get _libraryDir => Directory(
        '$libraryRoot${Platform.pathSeparator}$libraryDirName',
      );

  Directory get _subscriptionsDir => Directory(
        '$libraryRoot${Platform.pathSeparator}$subscriptionsDirName',
      );

  /// Points the store at [libraryRoot], creating `library/` and
  /// `subscriptions/` when absent. Safe to call repeatedly.
  Future<void> init({required String libraryRoot}) async {
    if (libraryRoot.trim().isEmpty) {
      throw ArgumentError('promptlib: libraryRoot must not be empty');
    }
    _libraryRoot = libraryRoot;
    await _libraryDir.create(recursive: true);
    await _subscriptionsDir.create(recursive: true);
    await _scan(); // warms duplicateIds / skippedFiles
  }

  /// Lists local prompts across `library/` + `subscriptions/`.
  ///
  /// * [query]: case-insensitive substring over title + body + tags.
  /// * [tags]: every requested tag must be present (AND semantics).
  /// * [type]: `library/` items count as [FeedType.prompt]; subscription
  ///   items resolve through [feedConfig] by feed slug, defaulting to
  ///   [FeedType.other] when the feed is unregistered.
  Future<List<PromptDoc>> listLocal({
    String? query,
    Set<String>? tags,
    FeedType? type,
  }) async {
    final List<_Entry> entries = await _scan();
    final String? q = query?.trim().toLowerCase();
    final Set<String>? tagFilter =
        tags == null ? null : tags.map((String t) => t.toLowerCase()).toSet();
    final List<PromptDoc> out = <PromptDoc>[];
    for (final _Entry e in entries) {
      final PromptDoc d = e.doc;
      if (q != null && q.isNotEmpty) {
        final String haystack =
            '${d.title}\n${d.body}\n${d.tags.join(' ')}'.toLowerCase();
        if (!haystack.contains(q)) continue;
      }
      if (tagFilter != null && tagFilter.isNotEmpty) {
        final Set<String> docTags =
            d.tags.map((String t) => t.toLowerCase()).toSet();
        if (!tagFilter.every(docTags.contains)) continue;
      }
      if (type != null && _entryType(e) != type) continue;
      out.add(d);
    }
    return out;
  }

  /// Returns the doc for [id], or `null` when unknown.
  /// Namespaced resolution: `library/` wins over `subscriptions/`.
  Future<PromptDoc?> getById(String id) async {
    final List<_Entry> entries = await _scan();
    _Entry? sub;
    for (final _Entry e in entries) {
      if (e.doc.id != id) continue;
      if (e.scope == _Scope.library) return e.doc;
      sub ??= e;
    }
    return sub?.doc;
  }

  /// Writes [doc] to `library/<slug>.md` and returns the saved doc
  /// (with `updated` stamped to now, `created` preserved or set).
  ///
  /// Rename-stable: when the id already lives in `library/`, the existing
  /// path is reused so title renames keep git history. A *different*
  /// `library/` file owning the same id throws [DuplicateIdException].
  /// Best-effort [GitService.autoCommit] afterwards; git failures never
  /// break the save.
  Future<PromptDoc> save(PromptDoc doc) async {
    if (doc.id.trim().isEmpty) {
      throw ArgumentError('promptlib: cannot save a doc with an empty id');
    }
    final List<_Entry> entries = await _scan();
    String? existingPath;
    for (final _Entry e in entries) {
      if (e.scope == _Scope.library && e.doc.id == doc.id) {
        existingPath = e.path;
        break;
      }
    }
    for (final _Entry e in entries) {
      if (e.scope == _Scope.library &&
          e.doc.id == doc.id &&
          e.path != existingPath) {
        throw DuplicateIdException(
          id: doc.id,
          existingPath: e.path,
          newPath: existingPath ?? '',
        );
      }
    }

    final DateTime now = DateTime.now().toUtc();
    final PromptDoc saved = doc.copyWith(
      created: () => doc.created ?? now,
      updated: () => now,
    );

    String target;
    if (existingPath != null) {
      target = existingPath;
    } else {
      final String base = slugifyTitle(
        saved.title.isEmpty ? saved.id : saved.title,
      );
      target = await _uniqueLibraryPath(base);
    }
    await File(target).writeAsString(fm.serialize(saved));
    await _scan();

    if (_git != null) {
      try {
        final String name = target.split(Platform.pathSeparator).last;
        await _git!.autoCommit('promptlib: save $name');
      } catch (_) {
        // Best-effort: local-only degradation when git is missing/broken.
      }
    }
    return saved;
  }

  /// Mirrors one fetched item into `subscriptions/<feedSlug>/<slug>.md`.
  ///
  /// Never touches `library/`. Updating the same upstream id within the
  /// same feed rewrites that feed's mirror file; the same id arriving in a
  /// *different* feed writes a separate namespaced file (read favours
  /// `library/` first).
  Future<PromptDoc> materializeSubscribedItem({
    required String feedSlug,
    required String id,
    required String title,
    String body = '',
    List<String> tags = const [],
    String? sourceUrl,
    DateTime? published,
  }) async {
    final String safeSlug = slugifyTitle(feedSlug.isEmpty ? 'feed' : feedSlug);
    if (id.trim().isEmpty) {
      throw ArgumentError(
          'promptlib: materialize needs a stable non-empty id');
    }
    final Directory feedDir = Directory(
      '${_subscriptionsDir.path}${Platform.pathSeparator}$safeSlug',
    );
    await feedDir.create(recursive: true);

    String? existing;
    await for (final FileSystemEntity e
        in feedDir.list(followLinks: false)) {
      if (e is! File || !e.path.toLowerCase().endsWith('.md')) continue;
      try {
        if (fm.parse(await e.readAsString()).id == id) {
          existing = e.path;
          break;
        }
      } catch (_) {
        continue; // malformed mirror files are overwritten below if slugged
      }
    }

    final DateTime now = DateTime.now().toUtc();
    final PromptDoc doc = PromptDoc(
      id: id,
      title: title.isEmpty ? 'Untitled' : title,
      tags: List<String>.from(tags),
      sourceFeed: sourceUrl != null && sourceUrl.isNotEmpty
          ? sourceUrl
          : safeSlug,
      created: published?.toUtc() ?? now,
      updated: now,
      body: body,
    );

    String target;
    if (existing != null) {
      target = existing;
    } else {
      final String base =
          slugifyTitle(title.isEmpty ? id : title);
      target =
          '${feedDir.path}${Platform.pathSeparator}$base.md';
      int n = 2;
      while (await File(target).exists()) {
        target =
            '${feedDir.path}${Platform.pathSeparator}$base-$n.md';
        n++;
      }
    }
    await File(target).writeAsString(fm.serialize(doc));
    await _scan();
    return doc;
  }

  /// Fork-on-edit: copies a subscribed doc into `library/` so edits never
  /// mutate the subscription mirror. The copy keeps the same id (read
  /// resolution favours `library/`) and preserves the `source_feed` link.
  /// Idempotent: when the id already lives in `library/`, returns it.
  Future<PromptDoc> forkToLibrary(String id) async {
    final List<_Entry> entries = await _scan();
    for (final _Entry e in entries) {
      if (e.scope == _Scope.library && e.doc.id == id) return e.doc;
    }
    _Entry? sub;
    for (final _Entry e in entries) {
      if (e.scope == _Scope.subscription && e.doc.id == id) {
        sub = e;
        break;
      }
    }
    if (sub == null) {
      throw StateError('promptlib: cannot fork unknown id "$id"');
    }
    final DateTime now = DateTime.now().toUtc();
    final PromptDoc forked = sub.doc.copyWith(
      updated: () => now,
    );
    final String base = slugifyTitle(
      forked.title.isEmpty ? forked.id : forked.title,
    );
    final String target = await _uniqueLibraryPath(base);
    await File(target).writeAsString(fm.serialize(forked));
    await _scan();
    return forked;
  }

  /// Broadcast stream firing (debounced) on `library/` or
  /// `subscriptions/` changes. Requires [init] first.
  Stream<void> watch() {
    if (!isInitialized) {
      throw StateError('promptlib: PromptStore.init() must be called first');
    }
    _watchController ??= StreamController<void>.broadcast(
      onCancel: _cancelWatch,
      onListen: _startWatch,
    );
    return _watchController!.stream;
  }

  /// Cancels watch subscriptions. Call [GitService.dispose] separately
  /// if a git service was provided (this store does not own it).
  Future<void> dispose() async {
    await _cancelWatch();
    await _watchController?.close();
    _watchController = null;
  }

  // ---- internals ----

  FeedType _entryType(_Entry e) {
    if (e.scope == _Scope.library) return FeedType.prompt;
    final String? slug = e.feedSlug;
    if (slug != null) {
      for (final FeedConfigEntry f in _feedConfig.feeds) {
        if (slugifyTitle(f.name) == slug || f.url == slug) {
          return f.type;
        }
      }
    }
    return FeedType.other;
  }

  Future<String> _uniqueLibraryPath(String base) async {
    String candidate =
        '${_libraryDir.path}${Platform.pathSeparator}$base.md';
    int n = 2;
    while (await File(candidate).exists()) {
      candidate =
          '${_libraryDir.path}${Platform.pathSeparator}$base-$n.md';
      n++;
    }
    return candidate;
  }

  /// Full rescan. Library entries index first so they win id collisions;
  /// collisions and skips are recorded for [duplicateIds]/[skippedFiles].
  /// Never throws for bad *content* (files are skipped); throws only when
  /// the root itself is unreadable.
  Future<List<_Entry>> _scan() async {
    final String root = libraryRoot; // throws when uninitialized
    final Map<String, _Entry> byId = <String, _Entry>{};
    final Map<String, List<String>> dups = <String, List<String>>{};
    final List<String> skipped = <String>[];

    void add(_Entry e) {
      final _Entry? first = byId[e.doc.id];
      if (first == null) {
        byId[e.doc.id] = e;
      } else {
        // Library scope wins over subscription scope on read.
        if (first.scope == _Scope.subscription &&
            e.scope == _Scope.library) {
          dups.putIfAbsent(e.doc.id, () => <String>[]).add(first.path);
          byId[e.doc.id] = e;
        } else {
          dups.putIfAbsent(e.doc.id, () => <String>[]).add(e.path);
        }
      }
    }

    Future<void> scanDir(Directory dir, _Scope scope) async {
      if (!await dir.exists()) return;
      await for (final FileSystemEntity e
          in dir.list(recursive: true, followLinks: false)) {
        if (e is! File) continue;
        if (!e.path.toLowerCase().endsWith('.md')) continue;
        String? feedSlug;
        if (scope == _Scope.subscription) {
          feedSlug = e.parent.path
              .split(Platform.pathSeparator)
              .last;
        }
        try {
          final PromptDoc doc = fm.parse(await e.readAsString());
          add(_Entry(
            path: e.path,
            scope: scope,
            feedSlug: feedSlug,
            doc: doc,
          ));
        } catch (_) {
          skipped.add(e.path); // malformed/unreadable: skip, never crash
        }
      }
    }

    await scanDir(
      Directory('$root${Platform.pathSeparator}$libraryDirName'),
      _Scope.library,
    );
    await scanDir(
      Directory('$root${Platform.pathSeparator}$subscriptionsDirName'),
      _Scope.subscription,
    );

    _duplicateIds = Map<String, List<String>>.unmodifiable(dups);
    _skippedFiles = List<String>.unmodifiable(skipped);
    return byId.values.toList();
  }

  void _startWatch() {
    _cancelWatch().ignore();
    void listenDir(Directory dir) {
      try {
        final StreamSubscription<FileSystemEvent> sub = dir
            .watch(recursive: true)
            .listen((_) => _notifyWatch());
        _watchSubs.add(sub);
      } catch (_) {
        // Watching is best-effort (e.g. network mounts); polling callers
        // still get correct data from listLocal/getById rescans.
      }
    }

    listenDir(_libraryDir);
    listenDir(_subscriptionsDir);
  }

  void _notifyWatch() {
    _watchDebounce?.cancel();
    _watchDebounce = Timer(
      const Duration(milliseconds: 250),
      () {
        if (_watchController != null && !_watchController!.isClosed) {
          _watchController!.add(null);
        }
      },
    );
  }

  Future<void> _cancelWatch() async {
    _watchDebounce?.cancel();
    _watchDebounce = null;
    for (final StreamSubscription<FileSystemEvent> s in _watchSubs) {
      try {
        await s.cancel();
      } catch (_) {
        // ignore: cancellation is best-effort
      }
    }
    _watchSubs.clear();
  }
}
