/// Git versioning + sync via the system `git` binary (WP1 core, WP5 push/manage).
///
/// Pure-Dart (`dart:io` `Process` shell-out only). Interface matches
/// ARCHITECTURE.md section 2, extended in WP5 with real-conflict detection
/// ([GitService.conflictedFiles]) and no-data-loss resolution
/// ([GitService.resolveConflict]). Degrades to local-only when no `git`
/// binary is present: every operation throws [GitNotAvailableException]
/// with a clear install hint instead of failing obscurely. History is never
/// rewritten — no force push, no hard reset, no destructive auto-resolve.
///
/// Typical diverged-remote recovery (push rejected as non-fast-forward,
/// `pull` --ff-only refuses to merge):
/// 1. `git fetch origin` + `git merge origin/<branch>` (raw git; may leave
///    unmerged paths),
/// 2. [GitService.conflictedFiles] to list them,
/// 3. [GitService.resolveConflict] per path (mine/theirs/manual — manual
///    preserves both copies to sibling `.bak` files first),
/// 4. commit + [GitService.push].

import 'dart:async';
import 'dart:io';

import 'conflict_resolve.dart';

export 'conflict_resolve.dart' show ConflictChoice;

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

/// Versioning + sync contract (ARCHITECTURE.md section 2, WP5 extensions).
abstract class GitService {
  /// True when a system `git` binary responds to `--version`.
  Future<bool> get isGitAvailable;

  /// Throws [GitNotAvailableException] with an install hint when no `git`
  /// binary is available. Called first by every mutating/query operation;
  /// callers may also call it directly to degrade to local-only mode.
  Future<void> ensureAvailable();

  /// Stage + commit promptlib paths with [message]. Debounced: rapid
  /// successive calls coalesce into one commit. Messages are normalized to
  /// the conventional `promptlib(<scope>): …` form, where scope is one of
  /// `library`, `subscriptions`, `.promptlib` (see [conventionalMessage]).
  Future<void> autoCommit(String message);

  /// Push to the user's remote. Auth errors surface plainly via
  /// [GitException] (stderr preserved, hint included).
  Future<void> push();

  /// Fast-forward-only pull. Diverged remotes and conflicts are reported
  /// via [GitException] and never auto-resolved destructively. After a
  /// manual fetch+merge, use [conflictedFiles] + [resolveConflict].
  Future<void> pull();

  /// Paths with unresolved merge conflicts (unmerged index entries).
  /// Empty when clean. Never throws for a clean tree.
  Future<List<String>> conflictedFiles();

  /// Porcelain (`git status --porcelain`) lines for diagnostics.
  Future<List<String>> statusShort();

  /// Resolves the merge conflict at [path] (repo-relative, e.g.
  /// `library/note.md`):
  ///
  /// * [ConflictChoice.mine] — keep the current branch (`--ours`).
  /// * [ConflictChoice.theirs] — keep the incoming branch (`--theirs`).
  /// * [ConflictChoice.manual] — write [manualContent] (required,
  ///   non-empty); both stage blobs are first preserved to sibling
  ///   `*.conflict-mine.bak` / `*.conflict-theirs.bak` files (numeric
  ///   suffix when taken), so no data is lost.
  ///
  /// Throws [GitException] when [path] is not currently conflicted, and
  /// [ArgumentError] for empty/escaping paths or a missing [manualContent].
  /// Leaves the resolution staged (`git add`); committing + pushing is the
  /// caller's step. Never touches any other file.
  Future<void> resolveConflict({
    required String path,
    required ConflictChoice choice,
    String? manualContent,
  });

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

  /// Git executable to shell out to. Defaults to `git` from `PATH`;
  /// override (e.g. in tests) to simulate a missing binary.
  final String gitBinary;

  /// Trailing-edge debounce window for [autoCommit].
  final Duration debounce;

  /// Promptlib-owned paths staged by [autoCommit]. Scoped so unrelated
  /// repo files are never swept into prompt commits.
  static const List<String> managedPaths = <String>[
    'library',
    'subscriptions',
    '.promptlib',
  ];

  /// Fallback commit identity, used ONLY when the user's git config provides
  /// no identity (see [isMissingIdentityError]). Passed per-invocation via
  /// `-c user.name=… -c user.email=…` so user/repo config files are never
  /// written to — the app never runs `git config user.*`. App-only address,
  /// never a personal one.
  static const String fallbackAuthorName = 'Prompt RSS';
  static const String fallbackAuthorEmail = 'prompt-rss@local';

  bool? _availableCache;
  Timer? _debounceTimer;
  final List<String> _pendingMessages = <String>[];

  /// Extra environment variables merged into every `Process.run` call
  /// (overriding the inherited process environment). Used in tests to
  /// isolate `HOME` / git config discovery; `null` (default) inherits
  /// the current process environment unchanged.
  final Map<String, String>? environment;

  ProcessGitService({
    required this.workingDirectory,
    this.gitBinary = 'git',
    this.debounce = const Duration(seconds: 2),
    this.environment,
  });

  /// True when [output] (stdout+stderr of a failed `git commit`) indicates
  /// a missing commit identity, matched case-insensitively. Callers use
  /// this to decide whether a single `-c user.name/email` retry is valid.
  static bool isMissingIdentityError(String output) {
    final String lower = output.toLowerCase();
    return lower.contains('author identity unknown') ||
        lower.contains('unable to auto-detect email address') ||
        lower.contains('empty ident') ||
        lower.contains('please tell me who you are');
  }

  @override
  Future<bool> get isGitAvailable async {
    if (_availableCache != null) return _availableCache!;
    try {
      final ProcessResult r = await Process.run(
        gitBinary,
        const ['--version'],
        workingDirectory: workingDirectory,
        environment:
            environment == null ? null : {...Platform.environment, ...environment!},
      );
      _availableCache = r.exitCode == 0;
    } on ProcessException {
      _availableCache = false;
    }
    return _availableCache!;
  }

  @override
  Future<void> ensureAvailable() async {
    if (!await isGitAvailable) {
      throw const GitNotAvailableException();
    }
  }

  /// Normalizes [raw] to the conventional `promptlib(<scope>): …` form.
  ///
  /// Scopes: `library`, `subscriptions`, `.promptlib` (the only paths
  /// [ProcessGitService.managedPaths] stages). Messages already in that
  /// form pass through; legacy `promptlib: …` messages map to the
  /// `library` scope; anything else is wrapped as
  /// `promptlib(library): <raw>`.
  static String conventionalMessage(String raw) {
    final String msg = raw.trim();
    if (RegExp(r'^promptlib\((library|subscriptions|\.promptlib)\)\s*:')
        .hasMatch(msg)) {
      return msg;
    }
    final RegExpMatch? legacy =
        RegExp(r'^promptlib\s*:\s*(.*)$', dotAll: true).firstMatch(msg);
    if (legacy != null) {
      final String rest = legacy.group(1)!.trim();
      String scope = 'library';
      if (rest.contains('subscriptions/') ||
          rest.contains('subscriptions')) {
        scope = 'subscriptions';
      } else if (rest.contains('.promptlib')) {
        scope = '.promptlib';
      }
      return 'promptlib($scope): $rest';
    }
    return 'promptlib(library): $msg';
  }

  Future<ProcessResult> _run(List<String> args) async {
    try {
      return await Process.run(
        gitBinary,
        args,
        workingDirectory: workingDirectory,
        environment:
            environment == null ? null : {...Platform.environment, ...environment!},
      );
    } on ProcessException catch (e) {
      throw GitNotAvailableException(
        'promptlib: system `git` binary not found ($e). Install git to '
        'enable versioning and sync; library files still work local-only.',
      );
    }
  }

  /// Appends an auth hint when [output] looks like a credential/remote
  /// failure. The raw output is always preserved in [GitException.stderr].
  static String? _authHint(String output) {
    final String lower = output.toLowerCase();
    if (lower.contains('authentication failed') ||
        lower.contains('permission denied') ||
        lower.contains('could not read from remote') ||
        lower.contains('invalid username') ||
        lower.contains('logon failed') ||
        lower.contains('unable to access')) {
      return 'hint: auth is handled by system git + OS credential manager — '
          'nothing is stored in-app. Check the remote URL (`git remote -v`) '
          'and your credentials (SSH key / personal access token), '
          'then retry — nothing was changed locally. '
          'See https://docs.github.com/en/authentication and '
          'https://docs.github.com/en/get-started/getting-started-with-git/about-remote-repositories.';
    }
    return null;
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
    await ensureAvailable();
    final String message = conventionalMessage(
      _pendingMessages.length == 1
          ? _pendingMessages.single
          : '${_pendingMessages.first} (+${_pendingMessages.length - 1} more)',
    );
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
      // Missing user identity: retry ONCE with a per-invocation `-c`
      // fallback so no user/repo config is ever written (never `git
      // config`). The hot path above always tries the user's own config
      // first — no identity probe runs before it.
      if (isMissingIdentityError(out)) {
        final ProcessResult retry = await _run([
          '-c',
          'user.name=$fallbackAuthorName',
          '-c',
          'user.email=$fallbackAuthorEmail',
          'commit',
          '-m',
          message,
        ]);
        if (retry.exitCode != 0) {
          final String retryOut = '${retry.stdout}${retry.stderr}';
          if (retryOut.contains('nothing to commit') ||
              retryOut.contains('no changes added to commit')) {
            return;
          }
          throw GitException(
            'promptlib: git commit failed',
            exitCode: retry.exitCode,
            stderr: retryOut.trim(),
          );
        }
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
    await ensureAvailable();
    final ProcessResult r = await _run(['push']);
    if (r.exitCode != 0) {
      final String err = '${r.stderr}'.trim();
      final String? hint = _authHint('$err\n${r.stdout}');
      throw GitException(
        'promptlib: git push failed (check remote + credentials)'
        '${hint == null ? '' : '\n$hint'}',
        exitCode: r.exitCode,
        stderr: err,
      );
    }
  }

  @override
  Future<void> pull() async {
    await ensureAvailable();
    final ProcessResult r = await _run(['pull', '--ff-only']);
    if (r.exitCode != 0) {
      final String out = '${r.stdout}${r.stderr}'.trim();
      final String? hint = _authHint(out);
      throw GitException(
        'promptlib: git pull --ff-only failed (diverged or conflicting '
        'changes; resolve manually — nothing was auto-resolved)'
        '${hint == null ? '' : '\n$hint'}',
        exitCode: r.exitCode,
        stderr: out,
      );
    }
  }

  @override
  Future<List<String>> conflictedFiles() async {
    await ensureAvailable();
    final ProcessResult r =
        await _run(['diff', '--name-only', '--diff-filter=U']);
    if (r.exitCode != 0) {
      throw GitException(
        'promptlib: git diff --name-only --diff-filter=U failed',
        exitCode: r.exitCode,
        stderr: '${r.stderr}'.trim(),
      );
    }
    final Set<String> out = <String>{};
    for (final String line in '${r.stdout}'.split('\n')) {
      final String p = line.trim();
      if (p.isNotEmpty) out.add(p);
    }
    return out.toList()..sort();
  }

  @override
  Future<List<String>> statusShort() async {
    await ensureAvailable();
    final ProcessResult r = await _run(['status', '--porcelain']);
    if (r.exitCode != 0) {
      throw GitException(
        'promptlib: git status failed',
        exitCode: r.exitCode,
        stderr: '${r.stderr}'.trim(),
      );
    }
    return '${r.stdout}'
        .split('\n')
        .map((String l) => l.trimRight())
        .where((String l) => l.isNotEmpty)
        .toList();
  }

  /// Rejects empty, absolute, or repo-escaping paths before they reach git.
  /// Backslashes are normalized to `/` (Windows separators); git always
  /// wants forward slashes.
  static String _checkedPath(String path) {
    final String p = path.trim().replaceAll('\\', '/');
    if (p.isEmpty) {
      throw ArgumentError('promptlib: git operation needs a path');
    }
    if (p.startsWith('-') ||
        p.startsWith('/') ||
        p.split('/').contains('..')) {
      throw ArgumentError('promptlib: unsafe path "$path"');
    }
    return p;
  }

  Future<String?> _stageBlob(String path, int stage) async {
    final ProcessResult r = await _run(['show', ':$stage:$path']);
    if (r.exitCode != 0) return null;
    return '${r.stdout}';
  }

  @override
  Future<void> resolveConflict({
    required String path,
    required ConflictChoice choice,
    String? manualContent,
  }) async {
    final String p = _checkedPath(path);
    await ensureAvailable();
    if (choice == ConflictChoice.manual &&
        (manualContent == null || manualContent.isEmpty)) {
      throw ArgumentError(
          'promptlib: manual resolution needs non-empty manualContent');
    }
    final List<String> conflicted = await conflictedFiles();
    if (!conflicted.contains(p)) {
      throw GitException(
        'promptlib: no unresolved conflict at "$p" '
        '(conflicted: ${conflicted.isEmpty ? 'none' : conflicted.join(', ')})',
      );
    }

    if (choice == ConflictChoice.manual) {
      final String fullPath =
          '$workingDirectory${Platform.pathSeparator}$p';
      // Stage 2 = ours/mine, stage 3 = theirs. Either may be absent
      // (e.g. add/add or delete/modify); fall back to the worktree blob
      // with markers stripped rather than failing and stranding the user.
      String? mine = await _stageBlob(p, 2);
      String? theirs = await _stageBlob(p, 3);
      if (mine == null || theirs == null) {
        String worktree = '';
        try {
          worktree = await File(fullPath).readAsString();
        } catch (_) {
          worktree = '';
        }
        mine ??= worktree;
        theirs ??= worktree;
      }
      await preserveBothCopies(
        filePath: fullPath,
        mineContent: mine,
        theirsContent: theirs,
      );
      await File(fullPath).writeAsString(manualContent!);
      if (hasConflictMarkers(manualContent)) {
        throw GitException(
          'promptlib: manual content for "$p" still contains conflict '
          'markers (both copies preserved to sibling .bak files); '
          'edit the file and stage it with `git add` yourself',
        );
      }
    } else {
      final ProcessResult checkout = await _run([
        'checkout',
        choice == ConflictChoice.mine ? '--ours' : '--theirs',
        '--',
        p,
      ]);
      if (checkout.exitCode != 0) {
        throw GitException(
          'promptlib: git checkout ${choice == ConflictChoice.mine ? '--ours' : '--theirs'} -- $p failed',
          exitCode: checkout.exitCode,
          stderr: '${checkout.stderr}'.trim(),
        );
      }
    }
    final ProcessResult add = await _run(['add', '--', p]);
    if (add.exitCode != 0) {
      throw GitException(
        'promptlib: git add -- $p failed after resolving',
        exitCode: add.exitCode,
        stderr: '${add.stderr}'.trim(),
      );
    }
  }

  @override
  Future<List<CommitInfo>> log({String? path, int limit = 50}) async {
    await ensureAvailable();
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
    final String p = _checkedPath(path);
    await ensureAvailable();
    final ProcessResult r =
        await _run(['checkout', rev, '--', p]);
    if (r.exitCode != 0) {
      throw GitException(
        'promptlib: git checkout $rev -- $p failed',
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
