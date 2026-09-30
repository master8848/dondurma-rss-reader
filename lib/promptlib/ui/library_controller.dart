/// WP4 UI support: pure-Dart controller over [PromptStore].
///
/// No Flutter imports: this file stays unit-testable with plain `dart test`,
/// like everything else under `lib/promptlib/`.
///
/// Responsibilities (INTERFACE CONTRACT):
/// * [list] delegates to `PromptStore.listLocal` with query/tag/type filter.
/// * [getById] / [save] delegate to the store (`save` auto-commits downstream
///   when the store was constructed with a [GitService]).
/// * [setFeedType] updates the per-feed type in memory (via [FeedEngine] when
///   one is attached, else directly on the store's registry) **and** persists
///   `.promptlib/feeds.yaml` via [serializeFeedsYaml], because WP1's
///   [FeedConfig] is load/parse-only (no YAML writer) and WP2's
///   `FeedEngine.setFeedType` is in-memory only.
library;

import 'dart:io';

import '../feed_config.dart';
import '../feed_engine.dart';
import '../prompt_doc.dart';
import '../prompt_store.dart';
import '../repo_mapping.dart';
import '../version_ux.dart';

/// Row data for one prompt id: resolved file path + offline state + sync
/// verdict, fetched together so list rows need a single future.
typedef PromptRowData = ({
  String? path,
  bool isOffline,
  ItemSyncState syncState,
});

/// Thin UI-facing controller. Create, call [init], then use [list]/[save].
class LibraryController {
  final PromptStore store;
  final String libraryRoot;
  final FeedEngine? engine;

  FeedConfig _config = const FeedConfig();

  LibraryController({
    required this.store,
    required this.libraryRoot,
    this.engine,
    RepoRegistry? repoRegistry,
  }) {
    if (repoRegistry != null) store.repoRegistry = repoRegistry;
  }

  /// Category→repo registry passthrough to `store.resolveCategoryDir`.
  set repoRegistry(RepoRegistry? value) => store.repoRegistry = value;
  RepoRegistry? get repoRegistry => store.repoRegistry;

  /// Current feed registry (loaded by [init], kept in sync by [setFeedType]).
  FeedConfig get feedConfig => _config;

  /// Convenience view of [feedConfig] entries for feed-list UIs.
  List<FeedConfigEntry> get feeds => _config.feeds;

  /// Points the store at [libraryRoot] and loads `.promptlib/feeds.yaml`
  /// (missing file yields an empty registry, per [FeedConfig.load]).
  Future<void> init() async {
    await store.init(libraryRoot: libraryRoot);
    _config = await FeedConfig.load(libraryRoot);
    store.feedConfig = _config;
  }

  /// Lists local prompts across `library/` + `subscriptions/`.
  /// Filter semantics mirror `PromptStore.listLocal`: case-insensitive
  /// substring [query] over title + body + tags, AND-semantics [tags],
  /// and [type] (`library/` items count as [FeedType.prompt]).
  Future<List<PromptDoc>> list({
    String? query,
    Set<String>? tags,
    FeedType? type,
  }) =>
      store.listLocal(query: query, tags: tags, type: type);

  /// Returns the doc for [id], or `null` when unknown.
  Future<PromptDoc?> getById(String id) => store.getById(id);

  /// Filesystem path of the latest file holding [id], or `null` when
  /// unknown. Delegates to `PromptStore.pathForId` — the exact id-based
  /// lookup (rename- and snapshot-proof), used by "Open In" buttons so
  /// saved prompts resolve to their real file instead of staying hidden.
  Future<String?> pathForId(String id) => store.pathForId(id);

  /// True when [id]'s resolved file lives under `subscriptions/`
  /// (offline-saved article mirror). Offline is a location state, not a
  /// type — see `PromptStore.isOffline`.
  Future<bool> isOffline(String id) => store.isOffline(id);

  /// Resolved file path + offline state for [id] in a single scan.
  /// Prefer this in row builders over separate [pathForId] + [isOffline]
  /// calls. See `PromptStore.fileStateFor`.
  Future<({String? path, bool isOffline})> fileStateFor(String id) =>
      store.fileStateFor(id);

  PromptSyncTracker? _syncTracker;

  /// Tri-state tracker over [store] (journal at
  /// `<libraryRoot>/.promptlib/sync_baselines.json`). Lazy: the journal
  /// loads on first use. Constructing the tracker wires the store's
  /// mirror-write hook, so feed refreshes move the recorded remote hash.
  Future<PromptSyncTracker> _sync() async {
    final PromptSyncTracker? ready = _syncTracker;
    if (ready != null) return ready;
    final BaselineJournal journal = await BaselineJournal.load(
      '$libraryRoot${Platform.pathSeparator}.promptlib'
      '${Platform.pathSeparator}sync_baselines.json',
    );
    final PromptSyncTracker tracker = PromptSyncTracker(
      store: store,
      journal: journal,
      engine: engine,
    );
    _syncTracker = tracker;
    return tracker;
  }

  /// Tri-state verdict for [id] (memoized ~15 min; `force` recomputes).
  /// Never throws — failures degrade to [ItemSyncState.unknown].
  Future<ItemSyncState> syncStateFor(String id, {bool force = false}) async {
    try {
      final PromptSyncTracker tracker = await _sync();
      final PromptSyncSnapshot snap = await tracker.check(id, force: force);
      return snap.state;
    } catch (_) {
      return ItemSyncState.unknown;
    }
  }

  /// Full snapshot for [id] (verdict + local/remote docs). Never throws —
  /// returns an unknown snapshot on failure so banners always have
  /// something to render.
  Future<PromptSyncSnapshot> syncSnapshotFor(
    String id, {
    bool force = false,
  }) async {
    try {
      return await (await _sync()).check(id, force: force);
    } catch (_) {
      return PromptSyncSnapshot(id: id, state: ItemSyncState.unknown);
    }
  }

  /// Row data for [id]: resolved path + offline state + sync verdict in one
  /// future for list rows. Never throws (unknown verdict on failure).
  Future<PromptRowData> rowDataFor(String id) async {
    final ({String? path, bool isOffline}) file = await fileStateFor(id);
    final ItemSyncState state = await syncStateFor(id);
    return (path: file.path, isOffline: file.isOffline, syncState: state);
  }

  /// Takes the source version for [id] (Update action). Returns the saved
  /// doc, or `null` when there is nothing to take. Never throws.
  Future<PromptDoc?> takeSyncUpdate(String id) async {
    try {
      return await (await _sync()).takeUpdate(id);
    } catch (_) {
      return null;
    }
  }

  /// Keeps the local copy for [id] (Keep-mine action): clears the badge
  /// until the source actually moves again. Never throws.
  Future<void> keepSyncMine(String id) async {
    try {
      await (await _sync()).keepMine(id);
    } catch (_) {
      // Dismissal must never fail the UI.
    }
  }

  /// Source-vs-mine bodies for [id] for the diff view (`null` when either
  /// side is missing). Never throws.
  Future<({String oldText, String newText})?> syncDiffFor(String id) async {
    try {
      return await (await _sync()).diffTexts(id);
    } catch (_) {
      return null;
    }
  }

  /// Best-effort fresh fetch of [id]'s source feed, then a re-check (Check-
  /// for-updates action). Never throws.
  Future<ItemSyncState> refreshSourceFor(String id) async {
    try {
      return (await (await _sync()).refreshAndCheck(id)).state;
    } catch (_) {
      return ItemSyncState.unknown;
    }
  }

  /// Writes [doc] to `library/<slug>.md` (rename-stable path).
  Future<PromptDoc> save(PromptDoc doc) => store.save(doc);

  /// Edits [doc] back to its SAME file (any scope): no fork, no duplicate.
  /// Offline (`subscriptions/`) edits stay in the mirror file so git sync
  /// picks them up — see `PromptStore.saveInPlace`.
  Future<PromptDoc> saveInPlace(PromptDoc doc) => store.saveInPlace(doc);

  /// Fork-on-copy: copies a subscribed doc into `library/` (idempotent when
  /// already there). Explicit copies only — offline edits stay in the
  /// mirror via [saveInPlace].
  Future<PromptDoc> forkToLibrary(String id) => store.forkToLibrary(id);

  /// Sets the per-feed type and persists `.promptlib/feeds.yaml`.
  ///
  /// When an [engine] is attached its registry is updated (which also pushes
  /// the config into the store); otherwise the controller updates the store
  /// registry directly. Either way the YAML file is rewritten afterwards so
  /// the registry survives restarts and syncs through the repo.
  Future<void> setFeedType({
    required String feedUrl,
    required FeedType type,
    String? name,
  }) async {
    if (engine != null) {
      engine!.setFeedType(feedUrl: feedUrl, type: type, name: name);
      _config = engine!.feedConfig;
    } else {
      final List<FeedConfigEntry> entries =
          List<FeedConfigEntry>.from(_config.feeds);
      final int at =
          entries.indexWhere((FeedConfigEntry e) => e.url == feedUrl);
      if (at == -1) {
        entries.add(FeedConfigEntry(
          url: feedUrl,
          name: (name == null || name.trim().isEmpty) ? feedUrl : name,
          type: type,
        ));
      } else {
        final FeedConfigEntry prev = entries[at];
        entries[at] = FeedConfigEntry(
          url: prev.url,
          name: (name == null || name.trim().isEmpty) ? prev.name : name,
          type: type,
        );
      }
      _config = FeedConfig(entries);
      store.feedConfig = _config;
    }
    await _persistFeedsYaml();
  }

  Future<void> _persistFeedsYaml() async {
    final File file = File('$libraryRoot/${FeedConfig.relativePath}');
    await file.parent.create(recursive: true);
    await file.writeAsString(serializeFeedsYaml(_config));
  }

  /// Serializes [config] to the `feeds.yaml` schema that [FeedConfig.parse]
  /// reads (`feeds:` list of `{url, name, type}`). Round-trips through
  /// [FeedConfig.parse], including names with quotes/colons (double-quoted
  /// with minimal escaping).
  static String serializeFeedsYaml(FeedConfig config) {
    final StringBuffer out = StringBuffer()..writeln('feeds:');
    for (final FeedConfigEntry e in config.feeds) {
      out
        ..writeln('  - url: ${_yamlQuote(e.url)}')
        ..writeln('    name: ${_yamlQuote(e.name)}')
        ..writeln('    type: ${feedTypeToString(e.type)}');
    }
    return out.toString();
  }

  static String _yamlQuote(String value) {
    if (RegExp(r'^[A-Za-z0-9_.\-/:]+$').hasMatch(value) && value.isNotEmpty) {
      return value;
    }
    final String escaped = value
        .replaceAll(r'\', r'\\')
        .replaceAll('"', r'\"')
        .replaceAll('\n', r'\n');
    return '"$escaped"';
  }
}
