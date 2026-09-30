/// Merge-conflict resolution primitives (WP5).
///
/// Pure `dart:io` file helpers used by [ProcessGitService.resolveConflict].
/// The git plumbing itself (`git show :2/:3:`, `checkout --ours/--theirs`,
/// `add`) stays in `git_service.dart`; this file owns the parts that must
/// never lose data:
///
/// * [ConflictChoice]: keep-mine, keep-theirs, or a caller-supplied manual
///   merge.
/// * [preserveBothCopies]: before a manual resolution overwrites the
///   worktree file, both stage blobs are written to sibling backup files.
///   Backups never overwrite existing files (numeric suffix) and never
///   leave the file's own directory.
/// * [hasConflictMarkers]: detects leftover `<<<<<<<`/`=======`/`>>>>>>>`
///   markers so callers can warn instead of committing a half-merge.

import 'dart:io';

/// Which side wins in [ProcessGitService.resolveConflict].
enum ConflictChoice {
  /// Current branch (`--ours`).
  mine,

  /// Incoming branch (`--theirs`).
  theirs,

  /// Caller-supplied merged text (`manualContent`). Both stage blobs are
  /// preserved to sibling `.bak` files first — nothing is lost.
  manual,
}

/// Sibling backup path for [choice] next to [filePath], e.g.
/// `library/note.md` → `library/note.md.conflict-mine.bak`.
String backupPathFor(String filePath, ConflictChoice choice) {
  final String suffix = choice == ConflictChoice.mine
      ? 'mine'
      : 'theirs';
  return '$filePath.conflict-$suffix.bak';
}

/// Returns a free path based on [base]: [base] itself when absent,
/// otherwise `<base>-2`, `<base>-3`, … Never overwrites.
Future<String> nonCollidingPath(String base) async {
  if (!await FileSystemEntity.isDirectory(base) &&
      !await FileSystemEntity.isFile(base)) {
    return base;
  }
  int n = 2;
  while (true) {
    final String candidate = '$base-$n';
    if (!await FileSystemEntity.isDirectory(candidate) &&
        !await FileSystemEntity.isFile(candidate)) {
      return candidate;
    }
    n++;
  }
}

/// Writes [mineContent] and [theirsContent] to sibling backups of
/// [filePath] (`*.conflict-mine.bak` / `*.conflict-theirs.bak`, with
/// numeric suffixes when those already exist).
///
/// Returns the two backup paths actually written, `[mineBackup,
/// theirsBackup]`. Existing files are never overwritten, caller files are
/// never touched — only the two new backups are created.
Future<List<String>> preserveBothCopies({
  required String filePath,
  required String mineContent,
  required String theirsContent,
}) async {
  final String mineBase = backupPathFor(filePath, ConflictChoice.mine);
  final String theirsBase =
      backupPathFor(filePath, ConflictChoice.theirs);
  final String mineBackup = await nonCollidingPath(mineBase);
  // When both bases collide identically (should not happen — different
  // suffixes — but be safe), resolve the second against the first.
  final String theirsBackup = await nonCollidingPath(theirsBase);
  await File(mineBackup).writeAsString(mineContent);
  await File(theirsBackup).writeAsString(theirsContent);
  return <String>[mineBackup, theirsBackup];
}

/// True when [content] still contains git merge-conflict markers.
bool hasConflictMarkers(String content) {
  for (final String line in content.split('\n')) {
    if (line.startsWith('<<<<<<< ') ||
        line.startsWith('>>>>>>> ') ||
        line == '=======') {
      return true;
    }
  }
  return false;
}
