/// Git versioning + sync via the system `git` binary (WP1).
///
/// Pure-Dart (`dart:io` `Process` shell-out only). Interface matches
/// ARCHITECTURE.md section 2 exactly. Degrades to local-only when no `git`
/// binary is present: every operation throws [GitNotAvailableException]
/// with a clear install hint instead of failing obscurely. History is never
/// rewritten — no force push, no hard reset, no destructive auto-resolve.

import 'dart:async';
import 'dart:io';

/// Thrown when the system `git` binary cannot be found.
///
/// Promptlib works local-only without git; callers should catch this and
/// continue without versioning/sync.
class GitNotAvailableException implements Exception {
  final String message;
  const GitNotAvailableException([
    this.message =
        'promptlib: system `git` binary not found. Install git to enable '
        'versioning and sync; library files still work local-only.',
  ]);

  @override
  String toString() => 'GitNotAvailableException: $message';
}

/// Thrown when `git` runs but reports failure (auth errors, conflicts, …).
/// The raw stderr is preserved so callers can surface it plainly.
class GitException implements Exception {
  final String message;
  final int exitCode;
  final String stderr;

  const GitException(this.message, {this.exitCode = -1, this.stderr = ''});

  @override
  String toString() =>
      'GitException: $message (exit $exitCode)${stderr.isEmpty ? '' : '\n$stderr'}';
}

/// One commit header from [GitService.log].
class CommitInfo {
  final String hash;
  final String author;
  final DateTime? date;
  final String message;

  const CommitInfo({
    required this.hash,
    required this.author,
    required this.date,
    required this.message,
  });

  @override
  String toString() => 'CommitInfo($hash, $author, $message)';
}

/// Versioning + sync contract (ARCHITECTURE.md section 2).
abstract class GitService {
  /// True when a system `git` binary responds to `--version`.
  Future<bool> get isGitAvailable;

  /// Stage + commit promptlib paths with [message]. Debounced: rapid
  /// successive calls coalesce into one commit.
  Future<void> autoCommit(String message);

  /// Push to the user's remote. Auth errors surface plainly via
  /// [GitException] (stderr preserved).
  Future<void> push();

  /// Fast-forward-only pull. Conflicts are reported via [GitException] and
  /// never auto-resolved destructively.
  Future<void> pull();

  /// Recent commit headers, optionally scoped to [path].
  Future<List<CommitInfo>> log({String? path, int limit = 50});

  /// Restores [path] to revision [rev] (`git checkout <rev> -- <path>`).
  /// Never touches any other file.
  Future<void> revertFile({required String path, required String rev});
}

/// [GitService] implemented by shelling out to the system `git` binary.
class ProcessGitService implements GitService {
  /// Repository working directory (the folder containing `library/` and
  /// `.promptlib/`).
  final String workingDirectory;

  /// Trailing-edge debounce window for [autoCommit].
  final Duration debounce;

  /// Promptlib-owned paths staged by [autoCommit]. Scoped so unrelated
  /// repo files are never swept into prompt commits.
  static const List<String> managedPaths = <String>[
    'library',
    'subscriptions',
    '.promptlib',
  ];

  bool? _availableCache;
  Timer? _debounceTimer;
  final List<String> _pendingMessages = <String>[];

  ProcessGitService({
    required this.workingDirectory,
    this.debounce = const Duration(seconds: 2),
  });

  @override
  Future<bool> get isGitAvailable async {
    if (_availableCache != null) return _availableCache!;
    try {
      final ProcessResult r = await Process.run(
        'git',
        const ['--version'],
        workingDirectory: workingDirectory,
      );
      _availableCache = r.exitCode == 0;
    } on ProcessException {
      _availableCache = false;
    }
    return _availableCache!;
  }

  Future<ProcessResult> _run(List<String> args) async {
    try {
      return await Process.run(
        'git',
        args,
        workingDirectory: workingDirectory,
      );
    } on ProcessException catch (e) {
      throw GitNotAvailableException(
        'promptlib: system `git` binary not found ($e). Install git to '
        'enable versioning and sync; library files still work local-only.',
      );
    }
  }

  @override
  Future<void> autoCommit(String message) async {
    _pendingMessages.add(message);
    _debounceTimer?.cancel();
    _debounceTimer = Timer(debounce, () {
      // Fire-and-forget by design: callers awaiting exact commit timing
      // should call [flush] instead. Errors are intentionally swallowed
      // here — a failed auto-commit must never break saving a prompt.
      flush().ignore();
    });
  }

  /// Immediately stages + commits any messages pending from [autoCommit].
  /// No-op when nothing is pending or nothing changed.
  Future<void> flush() async {
    _debounceTimer?.cancel();
    _debounceTimer = null;
    if (_pendingMessages.isEmpty) return;
    final String message = _pendingMessages.length == 1
        ? _pendingMessages.single
        : '${_pendingMessages.first} (+${_pendingMessages.length - 1} more)';
    _pendingMessages.clear();

    final List<String> existing = <String>[];
    for (final String p in managedPaths) {
      final String full =
          '$workingDirectory${Platform.pathSeparator}$p';
      if (await FileSystemEntity.isDirectory(full) ||
          await FileSystemEntity.isFile(full)) {
        existing.add(p);
      }
    }
    if (existing.isEmpty) return;
    final ProcessResult add =
        await _run(['add', '--', ...existing]);
    if (add.exitCode != 0) {
      throw GitException(
        'promptlib: git add failed',
        exitCode: add.exitCode,
        stderr: '${add.stderr}'.trim(),
      );
    }
    final ProcessResult commit =
        await _run(['commit', '-m', message]);
    if (commit.exitCode != 0) {
      final String out = '${commit.stdout}${commit.stderr}';
      // Nothing staged = success for debounce purposes.
      if (out.contains('nothing to commit') ||
          out.contains('no changes added to commit')) {
        return;
      }
      throw GitException(
        'promptlib: git commit failed',
        exitCode: commit.exitCode,
        stderr: out.trim(),
      );
    }
  }

  @override
  Future<void> push() async {
    final ProcessResult r = await _run(['push']);
    if (r.exitCode != 0) {
      throw GitException(
        'promptlib: git push failed (check remote + credentials)',
        exitCode: r.exitCode,
        stderr: '${r.stderr}'.trim(),
      );
    }
  }

  @override
  Future<void> pull() async {
    final ProcessResult r = await _run(['pull', '--ff-only']);
    if (r.exitCode != 0) {
      throw GitException(
        'promptlib: git pull --ff-only failed (diverged or conflicting '
        'changes; resolve manually — nothing was auto-resolved)',
        exitCode: r.exitCode,
        stderr: '${r.stdout}${r.stderr}'.trim(),
      );
    }
  }

  @override
  Future<List<CommitInfo>> log({String? path, int limit = 50}) async {
    final int n = limit < 1 ? 1 : (limit > 200 ? 200 : limit);
    final List<String> args = <String>[
      'log',
      '--format=%H%x1f%an%x1f%aI%x1f%s',
      '-n',
      '$n',
    ];
    if (path != null && path.isNotEmpty) args.addAll(['--', path]);
    final ProcessResult r = await _run(args);
    if (r.exitCode != 0) {
      throw GitException(
        'promptlib: git log failed',
        exitCode: r.exitCode,
        stderr: '${r.stderr}'.trim(),
      );
    }
    final List<CommitInfo> out = <CommitInfo>[];
    for (final String line in '${r.stdout}'.split('\n')) {
      if (line.trim().isEmpty) continue;
      final List<String> parts = line.split('\x1f');
      if (parts.length < 4) continue;
      out.add(CommitInfo(
        hash: parts[0],
        author: parts[1],
        date: DateTime.tryParse(parts[2]),
        message: parts.sublist(3).join('\x1f'),
      ));
    }
    return out;
  }

  @override
  Future<void> revertFile(
      {required String path, required String rev}) async {
    if (path.isEmpty || rev.isEmpty) {
      throw ArgumentError('promptlib: revertFile needs path + rev');
    }
    final ProcessResult r =
        await _run(['checkout', rev, '--', path]);
    if (r.exitCode != 0) {
      throw GitException(
        'promptlib: git checkout $rev -- $path failed',
        exitCode: r.exitCode,
        stderr: '${r.stderr}'.trim(),
      );
    }
  }

  /// Cancels a pending debounced commit. Call [flush] first if the pending
  /// commit must not be lost.
  void dispose() {
    _debounceTimer?.cancel();
    _debounceTimer = null;
  }
}
