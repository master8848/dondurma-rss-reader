/// File-backed prompt store owning `library/` + `subscriptions/<feed>/` (WP1).
///
/// Pure-Dart, no Flutter. Layout contract:
/// * `<root>/library/*.md` — the user's own prompts, the source of truth.
///   Only ever written by [save] / [forkToLibrary].
/// * `<root>/subscriptions/<feed>/*.md` — fetched items mirrored by
///   [materializeSubscribedItem]. This side never overwrites `library/`;
///   explicit copies go through [forkToLibrary] (same id, `source_feed`
///   preserved, reads favour `library/`), while [saveInPlace] edits the
///   mirror file itself so offline changes sync via git.
///
/// Divergence note vs ARCHITECTURE.md section 1: the pseudocode there takes
/// a `FeedItem` in `materializeSubscribedItem`. `FeedItem` lives in
/// `lib/models/` and imports `package:flutter/material.dart`, which would
/// break the pure-Dart core, so WP1 takes primitive fields instead
/// (`id`/`title`/`body`/… following the same stable-ID conventions).
/// A thin WP2/WP3 adapter can bridge `FeedItem` → this signature.
///
/// Versioning (repomap workstream, additive — `library/` behavior kept):
/// * Every doc carries `version` (default 1) + optional `supersedes`.
/// * [save]/[saveToCategory] edit in place: same file, version + 1.
/// * [saveOptimizedSnapshot] writes a new `<slug>.v<N+1>.md` snapshot with
///   the same id and `supersedes` pointing at the previous file.
/// * Reads are latest-per-id: highest version wins, then newest `updated`,
///   then scope (`library/` > `prompts/` > `subscriptions/`).
/// * `prompts/<category>/` holds categorized Markdown (see `repo_mapping.dart`
///   for which repo owns each category). Legacy `library/` files without a
///   `version` key parse as version 1 and are otherwise untouched.
///
/// Duplicate IDs: rejected on write ([DuplicateIdException] when *different*
/// `library/` files already hold the id), namespaced on read (`library/`
/// wins ties over `prompts/`, which wins over `subscriptions/`; higher
/// versions always win first). Same-id *different-version* files are
/// intentional history (snapshots), not duplicates — only same-id
/// same-version collisions land in [duplicateIds].
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
import 'offline_marking.dart' show isOfflineFilePath;
import 'prompt_doc.dart';
import 'repo_mapping.dart';

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

enum _Scope { library, prompt, subscription }

/// One parsed doc holding an id, with its scope resolved.
///
/// Returned by [PromptStore.scopedDocsForId] so sync/version UI can compare
/// the user's copy against the subscription mirror without re-scanning the
/// filesystem itself.
class PromptScopeDoc {
  /// Absolute file path holding the doc.
  final String path;

  /// The parsed doc.
  final PromptDoc doc;

  /// True for `library/` files (the user's own copy).
  final bool isLibrary;

  /// True for `subscriptions/<feed>/` mirror files (last fetched state).
  final bool isSubscription;

  /// `prompts/<category>/` files are neither library nor subscription.
  const PromptScopeDoc({
    required this.path,
    required this.doc,
    required this.isLibrary,
    required this.isSubscription,
  });
}

class _Entry {
  final String path;
  final _Scope scope;
  final String? feedSlug; // set for subscription scope
  final String? category; // set for prompt (prompts/<category>/) scope
  final PromptDoc doc;

  const _Entry({
    required this.path,
    required this.scope,
    required this.doc,
    this.feedSlug,
    this.category,
  });
}

/// File-backed store. Create with an optional [GitService] for auto-commit
/// on [save]; without one the store works local-only.
class PromptStore {
  static const String libraryDirName = 'library';
  static const String subscriptionsDirName = 'subscriptions';

  final GitService? _git;
  FeedConfig _feedConfig = const FeedConfig();
  RepoRegistry? _repoRegistry;

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

  /// Optional category→repo registry used by [saveToCategory],
  /// [resolveCategoryDir], and [saveOptimizedSnapshot] to locate
  /// `prompts/<category>/` dirs. When `null`, categories resolve to the
  /// default local dir (`<root>/prompts/<slug>/`).
  set repoRegistry(RepoRegistry? value) => _repoRegistry = value;
  RepoRegistry? get repoRegistry => _repoRegistry;

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

  /// Points the store at [libraryRoot], creating `library/`,
  /// `prompts/`, and `subscriptions/` when absent. Safe to call repeatedly.
  Future<void> init({required String libraryRoot}) async {
    if (libraryRoot.trim().isEmpty) {
      throw ArgumentError('promptlib: libraryRoot must not be empty');
    }
    _libraryRoot = libraryRoot;
    await _libraryDir.create(recursive: true);
    await Directory('$libraryRoot${Platform.pathSeparator}$promptsDirName')
        .create(recursive: true);
    await _subscriptionsDir.create(recursive: true);
    await _scan(); // warms duplicateIds / skippedFiles
  }

  /// Lists local prompts across `library/` + `prompts/` + `subscriptions/`
  /// (latest version per id).
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

  /// Returns the latest doc for [id], or `null` when unknown.
  ///
  /// Latest-per-id: highest `version` wins, then newest `updated`, then
  /// scope (`library/` > `prompts/` > `subscriptions/`).
  Future<PromptDoc?> getById(String id) async {
    final List<_Entry> entries = await _scan();
    _Entry? best;
    for (final _Entry e in entries) {
      if (e.doc.id != id) continue;
      if (best == null || _isNewer(e, best)) best = e;
    }
    return best?.doc;
  }

  /// Filesystem path of the latest file holding [id], or `null` when
  /// unknown. Useful for `supersedes` links and history views.
  Future<String?> pathForId(String id) async {
    final List<_Entry> entries = await _scan();
    _Entry? best;
    for (final _Entry e in entries) {
      if (e.doc.id != id) continue;
      if (best == null || _isNewer(e, best)) best = e;
    }
    return best?.path;
  }

  /// Every parsed doc holding [id], with its scope resolved
  /// (`library/` vs `prompts/<category>/` vs `subscriptions/<feed>/`).
  ///
  /// Additive read-only helper for sync/version UI: the store's
  /// latest-per-id reads ([getById]/[pathForId]) collapse scopes, but a
  /// local-vs-remote verdict needs the user's copy *and* the subscription
  /// mirror side by side. Malformed files stay skipped (see [skippedFiles]).
  Future<List<PromptScopeDoc>> scopedDocsForId(String id) async {
    final List<_Entry> all = await _collectAll();
    final List<PromptScopeDoc> out = <PromptScopeDoc>[];
    for (final _Entry e in all) {
      if (e.doc.id != id) continue;
      out.add(PromptScopeDoc(
        path: e.path,
        doc: e.doc,
        isLibrary: e.scope == _Scope.library,
        isSubscription: e.scope == _Scope.subscription,
      ));
    }
    out.sort((PromptScopeDoc a, PromptScopeDoc b) =>
        a.path.compareTo(b.path));
    return out;
  }

  /// True when [id]'s resolved file lives under `subscriptions/`.
  ///
  /// Offline is a location state, not a type: backed by subscriptions-scope
  /// membership of the exact id lookup ([pathForId], same rule as
  /// [isOfflineFilePath]). Unknown ids are not offline; an id forked into
  /// `library/` resolves there, so it is not offline either.
  Future<bool> isOffline(String id) async {
    return isOfflineFilePath(await pathForId(id), libraryRoot);
  }

  /// Exact id lookup (same scan as [pathForId]) returning both the resolved
  /// file path and its offline state. Prefer this over separate [pathForId]
  /// + [isOffline] calls in row builders to avoid scanning twice per row.
  /// File location still resolves through the [pathForId] rule; the
  /// prediction fallback for unmaterialized paths is `promptFilePath`
  /// (`prompt_paths.dart`), which covers `subscriptions/<slug>/` mirrors.
  Future<({String? path, bool isOffline})> fileStateFor(String id) async {
    final String? path = await pathForId(id);
    if (path == null) return (path: null, isOffline: false);
    return (path: path, isOffline: isOfflineFilePath(path, libraryRoot));
  }

  /// Edits a doc back to its SAME file (any scope): no fork, no duplicate.
  ///
  /// Finds the latest file holding [doc.id] (same resolution as [pathForId])
  /// and rewrites it in place with `version` bumped by one (same rule as
  /// [save]). Offline (`subscriptions/`) edits land in the mirror file
  /// itself so git sync picks them up. Unknown ids fall back to [save] (a
  /// new `library/` file). Best-effort [GitService.autoCommit] afterwards;
  /// git failures never break the save.
  Future<PromptDoc> saveInPlace(PromptDoc doc) async {
    if (doc.id.trim().isEmpty) {
      throw ArgumentError('promptlib: cannot save a doc with an empty id');
    }
    final List<_Entry> all = await _collectAll();
    final List<_Entry> owned =
        all.where((_Entry e) => e.doc.id == doc.id).toList();
    owned.sort(_compareEntries);
    if (owned.isEmpty) return save(doc);

    final _Entry latest = owned.last;
    final int disk = latest.doc.version;
    final int version = doc.version > disk ? doc.version : disk + 1;

    final DateTime now = DateTime.now().toUtc();
    final PromptDoc saved = doc.copyWith(
      created: () => doc.created ?? latest.doc.created ?? now,
      updated: () => now,
      version: version,
    );
    await File(latest.path).writeAsString(fm.serialize(saved));
    await _scan();

    final GitService? git = _git;
    if (git != null) {
      try {
        final String name = latest.path.split(Platform.pathSeparator).last;
        await git.autoCommit('promptlib: save $name');
      } catch (_) {
        // Best-effort: local-only degradation when git is missing/broken.
      }
    }
    return saved;
  }

  /// Writes [doc] to `library/<slug>.md` and returns the saved doc
  /// (with `updated` stamped to now, `created` preserved or set).
  ///
  /// In-place edit: when the id already lives in `library/`, the existing
  /// path is reused so title renames keep git history, and `version` bumps
  /// by one (`max(doc.version, on-disk version)`, plus one unless the caller
  /// already bumped past it). New ids keep `doc.version` (default 1).
  /// A *different* `library/` file owning the same id throws
  /// [DuplicateIdException]. Best-effort [GitService.autoCommit] afterwards;
  /// git failures never break the save.
  Future<PromptDoc> save(PromptDoc doc) async {
    if (doc.id.trim().isEmpty) {
      throw ArgumentError('promptlib: cannot save a doc with an empty id');
    }
    final List<_Entry> all = await _collectAll();
    final List<_Entry> owned = all
        .where((_Entry e) =>
            e.scope == _Scope.library && e.doc.id == doc.id)
        .toList();
    if (owned.length > 1) {
      owned.sort((_Entry a, _Entry b) => a.path.compareTo(b.path));
      throw DuplicateIdException(
        id: doc.id,
        existingPath: owned.first.path,
        newPath: owned[1].path,
      );
    }

    final int version;
    if (owned.isNotEmpty) {
      final int disk = owned.single.doc.version;
      version = doc.version > disk ? doc.version : disk + 1;
    } else {
      version = doc.version < 1 ? 1 : doc.version;
    }

    final DateTime now = DateTime.now().toUtc();
    final PromptDoc saved = doc.copyWith(
      created: () => doc.created ?? now,
      updated: () => now,
      version: version,
    );

    String target;
    if (owned.isNotEmpty) {
      target = owned.single.path;
    } else {
      final String base = slugifyTitle(
        saved.title.isEmpty ? saved.id : saved.title,
      );
      target = await _uniqueLibraryPath(base);
    }
    await File(target).writeAsString(fm.serialize(saved));
    await _scan();

    final GitService? git = _git;
    if (git != null) {
      try {
        final String name = target.split(Platform.pathSeparator).last;
        await git.autoCommit('promptlib: save $name');
      } catch (_) {
        // Best-effort: local-only degradation when git is missing/broken.
      }
    }
    return saved;
  }

  /// Creates a brand-new prompt with a fresh UUID (never title-derived —
  /// renames stay stable by construction), version 1, and writes it to
  /// `library/` (no category) or `prompts/<category>/`.
  Future<PromptDoc> createPrompt({
    required String title,
    String body = '',
    List<String> tags = const [],
    String? category,
    String? sourceFeed,
  }) async {
    final DateTime now = DateTime.now().toUtc();
    final PromptDoc doc = PromptDoc(
      id: generateUuidV4(),
      title: title.isEmpty ? 'Untitled' : title,
      tags: List<String>.from(tags),
      sourceFeed: sourceFeed,
      created: now,
      updated: now,
      body: body,
      version: 1,
    );
    final String slug = RepoRegistry.normalizeSlug(category ?? '');
    if (slug.isEmpty) {
      return save(doc);
    }
    return saveToCategory(doc, slug);
  }

  /// Filesystem directory for [categorySlug]: through [_repoRegistry] when
  /// set, else `<root>/prompts/<slug>/`. Throws [ArgumentError] on empty or
  /// path-escaping slugs.
  String resolveCategoryDir(String categorySlug) {
    final String slug = RepoRegistry.normalizeSlug(categorySlug);
    if (slug.isEmpty) {
      throw ArgumentError(
          'promptlib: categorySlug must be a single path segment');
    }
    final RepoRegistry? reg = _repoRegistry;
    if (reg != null) {
      try {
        return reg.resolveCategoryDir(slug, rootOverride: libraryRoot);
      } on StateError {
        // Registry without a root (memory-only): fall through to default.
      }
    }
    return RepoRegistry.defaultCategoryDir(libraryRoot, slug);
  }

  /// Writes [doc] to `prompts/<category>/<slug>.md`.
  ///
  /// In-place edit within the category: when the id already has a file in
  /// that dir, the latest one is reused and `version` bumps by one (same
  /// rule as [save]); otherwise a new `<slug>.md` base file keeps
  /// `doc.version` (default 1). Ids living in *other* dirs are left alone —
  /// reads resolve latest-per-id globally. The category metadata file
  /// (`.promptlib/category.yaml`) gains the slug best-effort when a
  /// registry is attached; failures never break the save.
  Future<PromptDoc> saveToCategory(PromptDoc doc, String categorySlug) async {
    if (doc.id.trim().isEmpty) {
      throw ArgumentError('promptlib: cannot save a doc with an empty id');
    }
    final String dir = resolveCategoryDir(categorySlug);
    await Directory(dir).create(recursive: true);
    final String slug = RepoRegistry.normalizeSlug(categorySlug);

    final List<_Entry> all = await _collectAll();
    final List<_Entry> owned = all
        .where((_Entry e) =>
            e.scope == _Scope.prompt &&
            e.doc.id == doc.id &&
            _canonical(_dirOf(e.path)) == _canonical(dir))
        .toList();
    owned.sort((_Entry a, _Entry b) => _compareEntries(a, b));

    final int version;
    if (owned.isNotEmpty) {
      final int disk = owned.last.doc.version;
      version = doc.version > disk ? doc.version : disk + 1;
    } else {
      version = doc.version < 1 ? 1 : doc.version;
    }

    final DateTime now = DateTime.now().toUtc();
    final PromptDoc saved = doc.copyWith(
      created: () => doc.created ?? now,
      updated: () => now,
      version: version,
    );

    String target;
    if (owned.isNotEmpty) {
      target = owned.last.path;
    } else {
      final String base =
          slugifyTitle(saved.title.isEmpty ? saved.id : saved.title);
      target = await _uniquePathIn(dir, base);
    }
    await File(target).writeAsString(fm.serialize(saved));
    await _scan();

    final RepoRegistry? reg = _repoRegistry;
    if (reg != null) {
      try {
        await reg.ensureCategory(slug, rootOverride: libraryRoot);
      } catch (_) {
        // Best-effort: category metadata never breaks a save.
      }
    }
    final GitService? git = _git;
    if (git != null) {
      try {
        final String name = target.split(Platform.pathSeparator).last;
        await git.autoCommit('promptlib: save $name');
      } catch (_) {
        // Best-effort: local-only degradation when git is missing/broken.
      }
    }
    return saved;
  }

  /// Snapshots an optimized rewrite as a new `<slug>.v<N+1>.md` file.
  ///
  /// Same [doc.id], version one past the highest on-disk version for that
  /// id (or `doc.version` when the caller already bumped past it), and
  /// `supersedes` set to the previous file (repo-relative when under the
  /// store root, else the basename). The previous file is left untouched —
  /// history stays on disk and [listLatestPerId]/[getById] surface the new
  /// snapshot. The snapshot lands next to the latest file, or in
  /// `prompts/<category>/` when [category] is given (or the id is new and
  /// no category is given, in `library/`).
  Future<PromptDoc> saveOptimizedSnapshot(PromptDoc doc,
      {String? category}) async {
    if (doc.id.trim().isEmpty) {
      throw ArgumentError('promptlib: cannot snapshot a doc with an empty id');
    }
    final List<_Entry> all = await _collectAll();
    final List<_Entry> owned =
        all.where((_Entry e) => e.doc.id == doc.id).toList();
    owned.sort((_Entry a, _Entry b) => _compareEntries(a, b));
    final _Entry? latest = owned.isEmpty ? null : owned.last;

    final int disk = latest?.doc.version ?? 0;
    int version = doc.version > disk ? doc.version : disk + 1;
    if (version < 1) version = 1;

    String dir;
    final String slug = RepoRegistry.normalizeSlug(category ?? '');
    if (slug.isNotEmpty) {
      dir = resolveCategoryDir(slug);
    } else if (latest != null) {
      dir = _dirOf(latest.path);
    } else {
      dir = _libraryDir.path;
    }
    await Directory(dir).create(recursive: true);

    String base;
    if (latest != null) {
      base = _stemOf(latest.path);
    } else {
      base = slugifyTitle(doc.title.isEmpty ? doc.id : doc.title);
    }
    base = _stripVersionSuffix(base);
    String target =
        '$dir${Platform.pathSeparator}$base.v$version.md';
    int n = 2;
    while (await File(target).exists()) {
      target = '$dir${Platform.pathSeparator}$base.v$version-$n.md';
      n++;
    }

    final DateTime now = DateTime.now().toUtc();
    final String? prev = latest?.path;
    final PromptDoc saved = doc.copyWith(
      created: () => doc.created ?? latest?.doc.created ?? now,
      updated: () => now,
      version: version,
      supersedes: () => prev == null
          ? null
          : RepoRegistry.relativeOrBase(libraryRoot, prev),
    );
    await File(target).writeAsString(fm.serialize(saved));
    await _scan();

    final GitService? git = _git;
    if (git != null) {
      try {
        final String name = target.split(Platform.pathSeparator).last;
        await git.autoCommit('promptlib: optimize $name');
      } catch (_) {
        // Best-effort: local-only degradation when git is missing/broken.
      }
    }
    return saved;
  }

  /// Latest doc per id, newest first by (version, updated).
  ///
  /// Same dedupe as [listLocal] but explicit: highest `version` wins, then
  /// newest `updated`. Optional [category] restricts to one
  /// `prompts/<category>/` folder; [query]/[tags]/[type] filter like
  /// [listLocal]. Malformed files are skipped (see [skippedFiles]).
  Future<List<PromptDoc>> listLatestPerId({
    String? category,
    String? query,
    Set<String>? tags,
    FeedType? type,
  }) async {
    final List<_Entry> entries = await _scan();
    final String slug = RepoRegistry.normalizeSlug(category ?? '');
    final String? q = query?.trim().toLowerCase();
    final Set<String>? tagFilter =
        tags == null ? null : tags.map((String t) => t.toLowerCase()).toSet();
    final List<_Entry> kept = <_Entry>[];
    for (final _Entry e in entries) {
      if (slug.isNotEmpty &&
          (e.scope != _Scope.prompt || e.category != slug)) {
        continue;
      }
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
      kept.add(e);
    }
    kept.sort((_Entry a, _Entry b) => _compareEntries(b, a));
    return kept.map((_Entry e) => e.doc).toList();
  }

  /// Mirrors one fetched item into `subscriptions/<feedSlug>/<slug>.md`.
  ///
  /// Never touches `library/`. Updating the same upstream id within the
  /// same feed rewrites that feed's mirror file; the same id arriving in a
  /// *different* feed writes a separate namespaced file (read favours
  /// `library/` first).
  ///
  /// Identical refreshes skip the write: when the existing mirror already
  /// carries the same id/title/tags/body, it is returned as-is (no
  /// `updated` re-stamp, no mtime churn, no git noise). Timestamps and
  /// `version` are not content, so they never trigger a rewrite on their
  /// own — sync UI compares content hashes, not mtimes.
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
      // Identical refresh: same words already on disk — keep the file (and
      // its timestamps) untouched instead of re-stamping `updated: now`.
      try {
        final PromptDoc onDisk = fm.parse(await File(existing).readAsString());
        if (onDisk.id == id &&
            onDisk.title == (title.isEmpty ? 'Untitled' : title) &&
            _sameTags(onDisk.tags, tags) &&
            onDisk.body == body) {
          return onDisk;
        }
      } catch (_) {
        // Unreadable mirror: fall through and overwrite it below.
      }
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

  /// Fork-on-copy: copies a subscribed doc into `library/` so the copy can
  /// evolve independently of the subscription mirror. The copy keeps the
  /// same id (read resolution favours `library/`) and preserves the
  /// `source_feed` link. Idempotent: when the id already lives in `library/`,
  /// returns it. For offline edits that stay in the mirror file itself
  /// (no fork), see [saveInPlace].
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

  /// Broadcast stream firing (debounced) on `library/`, `prompts/`, or
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
    if (e.scope == _Scope.library || e.scope == _Scope.prompt) {
      return FeedType.prompt;
    }
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
    return _uniquePathIn(_libraryDir.path, base);
  }

  Future<String> _uniquePathIn(String dir, String base) async {
    String candidate = '$dir${Platform.pathSeparator}$base.md';
    int n = 2;
    while (await File(candidate).exists()) {
      candidate = '$dir${Platform.pathSeparator}$base-$n.md';
      n++;
    }
    return candidate;
  }

  /// Lower is better: `library/` (0) beats `prompts/` (1) beats
  /// `subscriptions/` (2) on full ties.
  int _scopeRank(_Scope scope) {
    switch (scope) {
      case _Scope.library:
        return 0;
      case _Scope.prompt:
        return 1;
      case _Scope.subscription:
        return 2;
    }
  }

  /// Negative when [a] is older, positive when newer, zero on full tie.
  /// Order: higher `version`, then newer `updated` (null counts as oldest),
  /// then scope rank, then path (stable, first wins).
  int _compareEntries(_Entry a, _Entry b) {
    if (a.doc.version != b.doc.version) {
      return a.doc.version.compareTo(b.doc.version);
    }
    final DateTime? au = a.doc.updated;
    final DateTime? bu = b.doc.updated;
    if (au != null || bu != null) {
      if (au == null) return -1;
      if (bu == null) return 1;
      final int c = au.compareTo(bu);
      if (c != 0) return c;
    }
    final int r = _scopeRank(b.scope).compareTo(_scopeRank(a.scope));
    if (r != 0) return r;
    return a.path.compareTo(b.path);
  }

  bool _isNewer(_Entry candidate, _Entry current) =>
      _compareEntries(candidate, current) > 0;

  String _canonical(String dir) {
    String d = dir.replaceAll('\\', '/');
    while (d.endsWith('/') && d.length > 1) {
      d = d.substring(0, d.length - 1);
    }
    return d.toLowerCase();
  }

  String _dirOf(String path) {
    final int i = path.lastIndexOf(Platform.pathSeparator);
    return i < 0 ? '.' : path.substring(0, i);
  }

  /// Order-sensitive tag equality for the identical-refresh skip in
  /// [materializeSubscribedItem] (mirrors are written verbatim, so order is
  /// stable; a reorder still counts as a change worth rewriting).
  static bool _sameTags(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  String _stemOf(String path) {
    final int sep = path.lastIndexOf(Platform.pathSeparator);
    final String base =
        sep < 0 ? path : path.substring(sep + 1);
    return base.toLowerCase().endsWith('.md')
        ? base.substring(0, base.length - 3)
        : base;
  }

  /// Strips a trailing `.v<N>` snapshot suffix so the next snapshot does
  /// not stack (`foo.v2.md` → `foo`, next is `foo.v3.md`).
  String _stripVersionSuffix(String stem) {
    final RegExpMatch? m =
        RegExp(r'^(.*)\.v(\d+)$').firstMatch(stem);
    if (m == null) return stem;
    final String rest = m.group(1)!;
    return rest.isEmpty ? stem : rest;
  }

  /// Full rescan. Latest-per-id wins (highest `version`, then newest
  /// `updated`, then scope `library/` > `prompts/` > `subscriptions/`);
  /// same-id same-version collisions and skips are recorded for
  /// [duplicateIds]/[skippedFiles]. Never throws for bad *content* (files
  /// are skipped); throws only when the root itself is unreadable.
  Future<List<_Entry>> _scan() async {
    final List<_Entry> all = await _collectAll();
    final Map<String, _Entry> byId = <String, _Entry>{};
    for (final _Entry e in all) {
      final _Entry? first = byId[e.doc.id];
      if (first == null) {
        byId[e.doc.id] = e;
      } else if (_isNewer(e, first)) {
        byId[e.doc.id] = e;
      }
    }
    return byId.values.toList();
  }

  /// Every parsed Markdown file: `library/` + `prompts/` (recursive, with
  /// category = first segment under `prompts/`) + `subscriptions/`.
  /// Side effect: refreshes [duplicateIds]/[skippedFiles]. Same-id
  /// *different-version* files are history, not duplicates — only same-id
  /// same-version collisions are reported.
  Future<List<_Entry>> _collectAll() async {
    final String root = libraryRoot; // throws when uninitialized
    final List<_Entry> all = <_Entry>[];
    final Map<String, List<String>> dups = <String, List<String>>{};
    final List<String> skipped = <String>[];
    final Map<String, Map<int, String>> seen = <String, Map<int, String>>{};

    void add(_Entry e) {
      all.add(e);
      final Map<int, String> versions =
          seen.putIfAbsent(e.doc.id, () => <int, String>{});
      final String? firstPath = versions[e.doc.version];
      if (firstPath == null) {
        versions[e.doc.version] = e.path;
      } else if (firstPath != e.path) {
        dups.putIfAbsent(e.doc.id, () => <String>[]).add(e.path);
      }
    }

    Future<void> scanDir(Directory dir, _Scope scope) async {
      if (!await dir.exists()) return;
      await for (final FileSystemEntity e
          in dir.list(recursive: true, followLinks: false)) {
        if (e is! File) continue;
        if (!e.path.toLowerCase().endsWith('.md')) continue;
        String? feedSlug;
        String? category;
        if (scope == _Scope.subscription) {
          feedSlug = e.parent.path
              .split(Platform.pathSeparator)
              .last;
        } else if (scope == _Scope.prompt) {
          category = _promptCategoryFor(root, e.path);
        }
        try {
          final PromptDoc doc = fm.parse(await e.readAsString());
          add(_Entry(
            path: e.path,
            scope: scope,
            feedSlug: feedSlug,
            category: category,
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
      Directory('$root${Platform.pathSeparator}$promptsDirName'),
      _Scope.prompt,
    );
    await scanDir(
      Directory('$root${Platform.pathSeparator}$subscriptionsDirName'),
      _Scope.subscription,
    );

    _duplicateIds = Map<String, List<String>>.unmodifiable(dups);
    _skippedFiles = List<String>.unmodifiable(skipped);
    return all;
  }

  /// Category of a file under `<root>/prompts/`: first path segment, or
  /// `''` for files directly under `prompts/`.
  String _promptCategoryFor(String root, String filePath) {
    final String prefix =
        '$root${Platform.pathSeparator}$promptsDirName${Platform.pathSeparator}';
    if (!filePath.startsWith(prefix)) return '';
    final String rest = filePath.substring(prefix.length);
    final int i = rest.indexOf(Platform.pathSeparator);
    return i < 0 ? '' : rest.substring(0, i).toLowerCase();
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
    listenDir(Directory(
      '$libraryRoot${Platform.pathSeparator}$promptsDirName',
    ));
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
