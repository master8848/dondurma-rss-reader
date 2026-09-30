/// Prompt → file path resolution (promptlib, pure-Dart).
///
/// Single place that maps a saved prompt to its absolute on-disk Markdown
/// file, using the same resolution the store itself uses to read/write:
///
/// * categorized prompts → [PromptStore.resolveCategoryDir] semantics:
///   a bound category resolves through its [RepoBinding]
///   (`localPath` + `pathInRepo` via [RepoRegistry.joinRepoPath], so
///   precreated category folders and renamed/migrated categories follow
///   their binding); unbound categories — and bindings whose repo was
///   removed — fall back to `<root>/prompts/<slug>/`
///   ([RepoRegistry.defaultCategoryDir]).
/// * subscribed (offline-cache) mirrors → `<root>/subscriptions/<slug>/`,
///   mirroring [PromptStore.materializeSubscribedItem] + the feed-engine
///   prune path (`slugifyTitle(folder)`).
/// * everything else → legacy `<root>/library/*.md`
///   ([PromptStore.save] / [PromptStore.forkToLibrary]).
///
/// Every prompt the store manages lives in one of those files on disk and
/// syncs via git, so an "Open In" button gated on `existsOnDisk(path)` can
/// resolve a real path for saved prompts instead of staying hidden.
///
/// Two layers (both pure, no I/O — visibility stays `existsOnDisk` in the
/// widget layer):
///
/// * [resolvePromptDir] / [promptFilePath] below predict the write path for
///   a category/feed/filename triple. They cannot see title renames (saves
///   reuse the existing path) or optimize snapshots (`<stem>.v<N>.md`),
///   which keep the same id under a different filename.
/// * The exact file for a doc id is [PromptStore.pathForId] (id-based scan
///   over `library/` + `prompts/` + `subscriptions/`); UI layers that have
///   a store/controller must prefer it and use this file's helpers only as
///   the documented fallback/prediction.
///
/// Pure-Dart (no Flutter) so it stays unit-testable with plain `dart test`,
/// like everything else under `lib/promptlib/`.
library;

import 'dart:io';

import 'prompt_doc.dart';
import 'prompt_store.dart';
import 'repo_mapping.dart';

/// Directory owning a prompt's Markdown file.
///
/// Mirrors the store's write routing ([PromptStore.resolveCategoryDir] for
/// categories, `<root>/subscriptions/<slug>/` for feed mirrors,
/// `<root>/library/` for legacy/uncategorized prompts):
///
/// * non-empty [category] → `registry.resolveCategoryDir(category)` when a
///   [registry] is attached (precreated folders, renames, and cross-repo
///   migrations follow the binding), else `<root>/prompts/<slug>/`.
///   Bindings whose repo was removed fall back to the default dir — never
///   throws for bad data, matching `resolveCategoryDir`.
/// * empty [category] + non-empty [feedSlug] → the offline subscription
///   mirror `<root>/subscriptions/<slugifyTitle(feedSlug)>/`.
/// * otherwise → legacy `<root>/library/`.
///
/// An empty or path-escaping [category] (rejected by
/// [RepoRegistry.normalizeSlug]) is treated as uncategorized → `library/`,
/// never throws: the resolver must stay total for UI visibility checks.
/// Only a blank [root] throws [ArgumentError] (no store root to resolve
/// against — callers have nothing on disk without one).
String resolvePromptDir({
  required String root,
  RepoRegistry? registry,
  String? category,
  String? feedSlug,
}) {
  if (root.trim().isEmpty) {
    throw ArgumentError('promptlib: root must not be empty');
  }
  final String slug = RepoRegistry.normalizeSlug(category ?? '');
  if (slug.isNotEmpty) {
    final RepoRegistry? reg = registry;
    if (reg != null) {
      try {
        return reg.resolveCategoryDir(slug, rootOverride: root);
      } on StateError {
        // Memory-only registry without a root: fall through to default.
      }
    }
    return RepoRegistry.defaultCategoryDir(root, slug);
  }
  final String feed = (feedSlug ?? '').trim();
  if (feed.isNotEmpty) {
    final String sep = Platform.pathSeparator;
    return '$root$sep${PromptStore.subscriptionsDirName}$sep'
        '${slugifyTitle(feed)}';
  }
  return '$root${Platform.pathSeparator}${PromptStore.libraryDirName}';
}

/// Absolute disk path for a saved prompt file.
///
/// `promptFilePath(prompt, {registry, root})` covers the common case: pass
/// the doc plus the store root (and the attached [RepoRegistry], if any);
/// [category]/[feedSlug]/[fileSlug] override the doc-derived hints:
///
/// * [category] — the `prompts/<category>/` folder (precreated or bound;
///   renames/migrations follow the registry binding).
/// * [feedSlug] — the `subscriptions/<feed>/` offline mirror folder.
/// * [fileSlug] — filename stem (defaults to `slugifyTitle(prompt.title)`,
///   the same stem [PromptStore.save]/[saveToCategory]/
///   [materializeSubscribedItem] use for new files).
///
/// Returns `null` only when truly unresolvable: blank [root], or a blank
/// effective [fileSlug] with an untitled prompt. Never throws for bad
/// *data* (invalid categories fall back to `library/`); throws
/// [ArgumentError] only for a blank [root], like [resolvePromptDir].
///
/// Caveat: title renames reuse the existing file and optimize snapshots
/// write `<stem>.v<N>.md`, so a title-derived guess can miss. Callers with
/// a store must prefer the exact id-based lookup
/// ([PromptStore.pathForId]) and use this as the prediction fallback.
String? promptFilePath(
  PromptDoc prompt, {
  required String root,
  RepoRegistry? registry,
  String? category,
  String? feedSlug,
  String? fileSlug,
}) {
  if (root.trim().isEmpty) return null;
  final String raw =
      (fileSlug ?? '').trim().isEmpty ? prompt.title : fileSlug!.trim();
  final String stem =
      slugifyTitle(raw.isEmpty ? prompt.id : raw);
  if (stem.trim().isEmpty) return null;
  final String dir = resolvePromptDir(
    root: root,
    registry: registry,
    category: category,
    feedSlug: feedSlug,
  );
  return '$dir${Platform.pathSeparator}$stem.md';
}
