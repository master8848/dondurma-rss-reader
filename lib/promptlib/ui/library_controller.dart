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

  /// Writes [doc] to `library/<slug>.md` (rename-stable path).
  Future<PromptDoc> save(PromptDoc doc) => store.save(doc);

  /// Fork-on-edit: copies a subscribed doc into `library/` so edits never
  /// mutate the subscription mirror. Idempotent when already in `library/`.
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
          name: (name == null || name.trim().isEmpty) ? prev.name : name!,
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
