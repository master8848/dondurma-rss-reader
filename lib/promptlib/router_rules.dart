/// Category-to-folder routing + folder cache rules for the WP2 feed engine.
///
/// Pure-Dart, dependency-free: like everything under `lib/promptlib/`, this
/// file must never import `package:flutter/*` so the core stays unit-testable
/// with plain `dart test`.
///
/// Routing answers: "an item tagged with categories C lands in which
/// `subscriptions/<folder>/` directory?" The engine ([FeedEngine]) calls
/// [RouterRules.route] per item; a `null` result means "keep the feed's own
/// folder". The default rules are empty (everything keeps the feed folder),
/// so routing is strictly opt-in via user rules.
///
/// Folder cache rules ([FolderCacheRules]) bound how many mirror files a
/// `subscriptions/<folder>/` directory may hold. Eviction is opt-in
/// ([FolderCacheRules.evictOldest]); by default nothing is ever deleted.
library;

import 'dart:io';

/// User-configured mapping from feed category tags to subscription folders.
///
/// Matching is case-insensitive on trimmed tags; the first matching category
/// in the item's tag order wins. When nothing matches, [defaultFolder] is
/// returned (which itself may be `null` = keep the feed folder).
class RouterRules {
  /// Normalized (`trim().toLowerCase()`) category -> folder name.
  final Map<String, String> categoryToFolder;

  /// Folder used when no category matches, or `null` to keep the feed folder.
  final String? defaultFolder;

  RouterRules({
    Map<String, String> categoryToFolder = const <String, String>{},
    this.defaultFolder,
  }) : categoryToFolder = Map<String, String>.unmodifiable(
          <String, String>{
            for (final MapEntry<String, String> e in categoryToFolder.entries)
              e.key.trim().toLowerCase(): e.value,
          },
        );

  /// Routes [categories] to a folder name, or `null` to keep the feed folder.
  String? route(Iterable<String> categories) {
    for (final String raw in categories) {
      final String key = raw.trim().toLowerCase();
      if (key.isEmpty) continue;
      final String? folder = categoryToFolder[key];
      if (folder != null) return folder;
    }
    return defaultFolder;
  }

  @override
  String toString() =>
      'RouterRules(rules: $categoryToFolder, defaultFolder: $defaultFolder)';
}

/// Bounds the size of a `subscriptions/<folder>/` mirror directory.
///
/// Mirrors [FeedService.maxItemsPerFeed] (= 50) as the default cap so the
/// offline cache stays bounded the same way the in-memory feed list is.
/// Eviction only runs when [evictOldest] is `true`; otherwise [pruneFolder]
/// only reports the overflow without deleting anything, so the default
/// configuration can never delete user files.
class FolderCacheRules {
  /// Maximum `.md` files kept per folder before overflow is reported/pruned.
  final int maxFilesPerFolder;

  /// When `true`, [pruneFolder] deletes the oldest files beyond
  /// [maxFilesPerFolder] (by modification time, oldest first).
  final bool evictOldest;

  const FolderCacheRules({
    this.maxFilesPerFolder = 50,
    this.evictOldest = false,
  }) : assert(maxFilesPerFolder > 0, 'maxFilesPerFolder must be positive');

  /// Counts `.md` files directly inside [dirPath].
  ///
  /// Returns `(fileCount, overflow)` where overflow is
  /// `max(0, fileCount - maxFilesPerFolder)`. When [evictOldest] is true,
  /// deletes the oldest overflow files first and returns the post-prune
  /// counts. A missing directory counts as `(0, 0)`. Never throws for
  /// unreadable entries (they are skipped); throws only when [dirPath]
  /// exists but is not a directory.
  Future<({int fileCount, int overflow, int removed})> pruneFolder(
    String dirPath,
  ) async {
    final Directory dir = Directory(dirPath);
    // A missing directory counts as empty (offline-fresh state), never an
    // error. An existing non-directory still throws (FileSystemException
    // from list), per the contract.
    if (!await dir.exists()) {
      return (fileCount: 0, overflow: 0, removed: 0);
    }
    final List<_FileAge> files = <_FileAge>[];
    await for (final FileSystemEntity e in dir.list(followLinks: false)) {
      if (e is! File) continue;
      if (!e.path.toLowerCase().endsWith('.md')) continue;
      DateTime modified;
      try {
        modified = await e.lastModified();
      } catch (_) {
        continue; // unreadable entry: skip, never crash
      }
      files.add(_FileAge(e, modified));
    }
    files.sort(
      ( _FileAge a, _FileAge b) => a.modified.compareTo(b.modified),
    );
    final int overflow =
        files.length <= maxFilesPerFolder ? 0 : files.length - maxFilesPerFolder;
    if (!evictOldest || overflow == 0) {
      return (fileCount: files.length, overflow: overflow, removed: 0);
    }
    int removed = 0;
    for (int i = 0; i < overflow; i++) {
      try {
        await files[i].file.delete();
        removed++;
      } catch (_) {
        // Best-effort eviction: keep going, report what was removed.
      }
    }
    return (fileCount: files.length - removed, overflow: overflow - removed, removed: removed);
  }

  @override
  String toString() =>
      'FolderCacheRules(maxFilesPerFolder: $maxFilesPerFolder, '
      'evictOldest: $evictOldest)';
}

class _FileAge {
  final File file;
  final DateTime modified;
  const _FileAge(this.file, this.modified);
}
