/// Sync-back / restore runner over the repo registry (fresh-device restore
/// + incremental sync).
///
/// Pure-Dart, files only. [RestoreRunner.restoreAll] clones every bound repo
/// (fresh-device path), verifies each prompt file, and rebuilds the
/// [PromptStore] index; [RestoreRunner.syncAll] runs `fetch` + `pull
/// --ff-only` per repo and surfaces conflicts through the existing
/// [GitService.conflictedFiles] / [GitService.resolveConflict] APIs
/// ([conflict_resolve.dart] keeps both sides in sibling `.bak` files, so
/// resolution never silently overwrites data).
///
/// Registry binding: [RepoInfo] is a minimal local snapshot
/// (`{repoId, remoteUrl, localPath, defaultBranch}`).
/// Build it from the real RepoMapping via [RestoreRunner.fromRegistry]
/// (maps [RepoRegistry.allRepos], resolving relative localPaths against
/// the registry root); the field names stay stable so call sites that
/// already hand-build [RepoInfo] lists keep working.
///
/// Safety contract (mirrors `git_service.dart`):
/// * never force-pushes, hard-resets, rewrites history, or deletes user
///   files — non-empty non-checkout directories are left untouched;
/// * one bad file never fails a whole restore (collected into
///   `filesSkipped` / `skippedFiles`);
/// * repos with an empty [RepoInfo.remoteUrl] (disabled categories with no
///   binding) are skipped without touching the filesystem or banners;
/// * without a system `git` binary everything degrades to a reported
///   local-only path ([GitNotAvailableException] semantics) instead of
///   failing obscurely.

import 'dart:io';

import 'front_matter.dart' as fm;
import 'git_service.dart';
import 'prompt_store.dart';
import 'repo_mapping.dart';

/// Minimal registry entry: which remote backs which local checkout.
///
/// Mirrors [RepoRecord] field-for-field (see [RestoreRunner.fromRegistry]);
/// constructible directly for tests/callers without a registry.
/// An empty [remoteUrl] means "disabled / no binding": the runner
/// skips the repo entirely and never touches [localPath].
class RepoInfo {
  /// Stable id used in per-repo statuses (e.g. a category or feed slug).
  final String repoId;

  /// Clone/fetch URL. Empty = unbound; the repo is skipped untouched.
  final String remoteUrl;

  /// Local checkout directory (created by [RestoreRunner.restoreAll]).
  final String localPath;

  /// Branch expected after clone. Best-effort: when absent on the remote,
  /// the clone's default HEAD is kept and the status note says so.
  final String defaultBranch;

  RepoInfo({
    required this.repoId,
    required this.remoteUrl,
    required this.localPath,
    this.defaultBranch = 'main',
  }) {
    if (repoId.trim().isEmpty) {
      throw ArgumentError('promptlib: RepoInfo needs a non-empty repoId');
    }
    if (localPath.trim().isEmpty) {
      throw ArgumentError('promptlib: RepoInfo needs a non-empty localPath');
    }
  }

  /// True when the repo has a remote binding and participates in
  /// restore/sync. False = disabled category, left untouched.
  bool get hasBinding => remoteUrl.trim().isNotEmpty;

  @override
  String toString() => 'RepoInfo($repoId -> $localPath)';
}

/// Per-file conflict resolution request for
/// [RestoreRunner.resolveRepoConflicts].
class ConflictResolution {
  /// Repo-relative path (e.g. `library/note.md`).
  final String path;

  /// Which side wins. [ConflictChoice.manual] requires [manualContent] and
  /// preserves both stage blobs to sibling `.bak` files first.
  final ConflictChoice choice;

  /// Merged text for [ConflictChoice.manual]. Must be non-empty and free
  /// of conflict markers.
  final String? manualContent;

  const ConflictResolution({
    required this.path,
    required this.choice,
    this.manualContent,
  });
}

/// Outcome of resolving one conflicted file.
class FileResolveResult {
  final String path;
  final bool ok;

  /// Backup files written before a manual resolution (mine/theirs `.bak`
  /// siblings, possibly with numeric suffixes). Empty for mine/theirs or
  /// failed resolutions.
  final List<String> backups;
  final String note;

  const FileResolveResult({
    required this.path,
    required this.ok,
    this.backups = const [],
    this.note = '',
  });
}

/// Outcome of [RestoreRunner.resolveRepoConflicts] for one repo.
class ResolveSummary {
  final String repoId;
  final List<FileResolveResult> results;

  const ResolveSummary({required this.repoId, this.results = const []});

  int get resolved => results.where((FileResolveResult r) => r.ok).length;
  int get failed => results.where((FileResolveResult r) => !r.ok).length;
}

/// Per-repo outcome of [RestoreRunner.restoreAll].
class RepoRestoreStatus {
  final String repoId;

  /// True when the repo verified cleanly (or was legitimately skipped).
  final bool ok;

  /// True for disabled/unbound repos: nothing was touched.
  final bool skipped;

  /// True when git was unavailable and only local files were verified.
  final bool localOnly;

  /// Prompt files that parsed cleanly.
  final int promptsRestored;

  /// Files that failed to parse (collected, never fatal).
  final int filesSkipped;

  /// Paths that failed to parse.
  final List<String> skippedFiles;

  /// Docs visible through a rebuilt [PromptStore] index (-1 when the
  /// index rebuild itself failed; details in [note]).
  final int indexed;

  /// Human-readable detail (clone skipped, branch kept, index failure…).
  final String note;

  const RepoRestoreStatus({
    required this.repoId,
    required this.ok,
    this.skipped = false,
    this.localOnly = false,
    this.promptsRestored = 0,
    this.filesSkipped = 0,
    this.skippedFiles = const [],
    this.indexed = 0,
    this.note = '',
  });
}

/// Totals of [RestoreRunner.restoreAll] across the registry.
class RestoreSummary {
  final List<RepoRestoreStatus> results;

  const RestoreSummary({this.results = const []});

  int get reposOk =>
      results.where((RepoRestoreStatus r) => r.ok && !r.skipped).length;
  int get reposFailed =>
      results.where((RepoRestoreStatus r) => !r.ok && !r.skipped).length;
  int get reposSkipped =>
      results.where((RepoRestoreStatus r) => r.skipped).length;
  int get promptsRestored => results.fold<int>(
      0, (int n, RepoRestoreStatus r) => n + r.promptsRestored);
  int get filesSkipped => results.fold<int>(
      0, (int n, RepoRestoreStatus r) => n + r.filesSkipped);
}

/// Per-repo outcome of [RestoreRunner.syncAll].
class RepoSyncStatus {
  final String repoId;
  final bool ok;
  final bool skipped;
  final bool localOnly;

  /// True when `fetch` + `pull --ff-only` completed.
  final bool pulled;

  /// Unresolved merge conflicts (empty when clean). Resolve via
  /// [RestoreRunner.resolveRepoConflicts], then commit + push.
  final List<String> conflicts;
  final String note;

  const RepoSyncStatus({
    required this.repoId,
    required this.ok,
    this.skipped = false,
    this.localOnly = false,
    this.pulled = false,
    this.conflicts = const [],
    this.note = '',
  });
}

/// Totals of [RestoreRunner.syncAll] across the registry.
class SyncSummary {
  final List<RepoSyncStatus> results;

  const SyncSummary({this.results = const []});

  int get reposOk =>
      results.where((RepoSyncStatus r) => r.ok && !r.skipped).length;
  int get reposFailed =>
      results.where((RepoSyncStatus r) => !r.ok && !r.skipped).length;
  int get reposSkipped =>
      results.where((RepoSyncStatus r) => r.skipped).length;
  int get conflictedFiles => results.fold<int>(
      0, (int n, RepoSyncStatus r) => n + r.conflicts.length);
}

/// Creates a [GitService] rooted at a checkout directory.
typedef GitServiceFactory = GitService Function(String workingDirectory);

/// Fresh-device restore + incremental sync over a list of [RepoInfo].
///
/// Files only: no UI, no banners, no pushes from this runner (pushing stays
/// an explicit user step via [GitService.push]). Commit-only side effects:
/// `git clone`, `git fetch`, `git pull --ff-only`, per-file conflict
/// checkout through [GitService.resolveConflict], and `.bak` siblings for
/// manual merges. History is never rewritten and user files are never
/// deleted.
class RestoreRunner {
  /// Registry snapshot this runner operates over.
  final List<RepoInfo> repos;

  /// Git executable to shell out to for clone/fetch/branch plumbing.
  final String gitBinary;

  final GitServiceFactory _gitServices;

  /// Prompt-bearing directories verified inside each checkout, in order.
  /// `library/` is the real layout ([PromptStore]); `prompts/` is the
  /// registry-layout alias used by fresh-device restores.
  static const List<String> promptDirs = <String>['prompts', 'library'];

  RestoreRunner({
    required this.repos,
    this.gitBinary = 'git',
    GitServiceFactory? gitServices,
  }) : _gitServices = gitServices ??
            ((String dir) => ProcessGitService(
                  workingDirectory: dir,
                  gitBinary: gitBinary,
                ));

  /// Adapter from the real repo mapping: one [RepoInfo] per
  /// [RepoRegistry.allRepos], with relative `localPath`s resolved against
  /// `rootOverride ?? registry.root` (absolute paths kept as-is). No
  /// behavior change — the runner still operates over [repos].
  factory RestoreRunner.fromRegistry(
    RepoRegistry registry, {
    String? rootOverride,
    String gitBinary = 'git',
    GitServiceFactory? gitServices,
  }) {
    final String? root = rootOverride ?? registry.root;
    final List<RepoInfo> infos = registry.allRepos
        .map((RepoRecord r) => RepoInfo(
              repoId: r.repoId,
              remoteUrl: r.remoteUrl,
              localPath: _resolveLocalPath(r.localPath, root),
              defaultBranch: r.defaultBranch,
            ))
        .toList();
    return RestoreRunner(
      repos: infos,
      gitBinary: gitBinary,
      gitServices: gitServices,
    );
  }

  /// Resolves a [RepoRecord.localPath] to an absolute checkout dir, mirroring
  /// [RepoRegistry.joinRepoPath] for the no-`pathInRepo` case.
  static String _resolveLocalPath(String localPath, String? root) {
    final String p = localPath.trim();
    if (p.startsWith('/') ||
        p.startsWith('\\') ||
        RegExp(r'^[A-Za-z]:[\\/]').hasMatch(p)) {
      return p;
    }
    if (root == null || root.trim().isEmpty) return p;
    final String r = root.endsWith(Platform.pathSeparator)
        ? root.substring(0, root.length - 1)
        : root;
    return '$r${Platform.pathSeparator}$p';
  }

  bool? _availableCache;

  /// True when a system `git` binary responds to `--version`.
  Future<bool> get isGitAvailable async {
    if (_availableCache != null) return _availableCache!;
    try {
      final ProcessResult r =
          await Process.run(gitBinary, const ['--version']);
      _availableCache = r.exitCode == 0;
    } on ProcessException {
      _availableCache = false;
    }
    return _availableCache!;
  }

  /// Fresh-device path: clone every bound repo, verify its prompt files,
  /// and rebuild the [PromptStore] index. Never throws for per-repo or
  /// per-file failures — everything is collected into the summary.
  Future<RestoreSummary> restoreAll() async {
    final List<RepoRestoreStatus> out = <RepoRestoreStatus>[];
    for (final RepoInfo repo in repos) {
      try {
        out.add(await restoreRepo(repo));
      } catch (e) {
        // Defensive: one repo must never sink the whole restore.
        out.add(RepoRestoreStatus(
          repoId: repo.repoId,
          ok: false,
          note: 'promptlib: unexpected restore failure: $e',
        ));
      }
    }
    return RestoreSummary(results: out);
  }

  /// Incremental path: `fetch` + `pull --ff-only` per bound repo.
  /// Diverged remotes fail plainly (nothing auto-resolved); conflicts are
  /// listed for [resolveRepoConflicts]. Never throws per repo.
  Future<SyncSummary> syncAll() async {
    final List<RepoSyncStatus> out = <RepoSyncStatus>[];
    for (final RepoInfo repo in repos) {
      try {
        out.add(await syncRepo(repo));
      } catch (e) {
        out.add(RepoSyncStatus(
          repoId: repo.repoId,
          ok: false,
          note: 'promptlib: unexpected sync failure: $e',
        ));
      }
    }
    return SyncSummary(results: out);
  }

  /// Restores a single repo: clone when needed, verify prompt files,
  /// rebuild the index. See [restoreAll] for the safety contract.
  Future<RepoRestoreStatus> restoreRepo(RepoInfo repo) async {
    if (!repo.hasBinding) {
      return RepoRestoreStatus(
        repoId: repo.repoId,
        ok: true,
        skipped: true,
        note: 'promptlib: no remote binding; disabled category left untouched',
      );
    }

    final bool haveGit = await isGitAvailable;
    final Directory dir = Directory(repo.localPath);
    final List<String> notes = <String>[];

    if (!await dir.exists()) {
      if (!haveGit) {
        return RepoRestoreStatus(
          repoId: repo.repoId,
          ok: false,
          localOnly: true,
          note: 'promptlib: system `git` not found (local-only mode) and '
              '${repo.localPath} does not exist — nothing to verify. '
              'Install git to enable restore; library files still work '
              'local-only.',
        );
      }
      try {
        await Directory(_parentOf(repo.localPath)).create(recursive: true);
        await _runGit(
          _parentOf(repo.localPath),
          <String>['clone', '--', repo.remoteUrl.trim(), repo.localPath],
        );
        notes.add('cloned ${repo.remoteUrl.trim()}');
      } on GitNotAvailableException catch (e) {
        return RepoRestoreStatus(
          repoId: repo.repoId,
          ok: false,
          localOnly: true,
          note: e.toString(),
        );
      } on GitException catch (e) {
        return RepoRestoreStatus(
          repoId: repo.repoId,
          ok: false,
          note: 'promptlib: clone of ${repo.repoId} failed — '
              '${_brief(e.stderr.isEmpty ? e.message : e.stderr)}',
        );
      }
      final String branchNote = await _ensureBranch(repo);
      if (branchNote.isNotEmpty) notes.add(branchNote);
    } else if (await _isCheckout(dir)) {
      notes.add('existing checkout; clone skipped');
    } else {
      // Non-empty (or empty) directory without git metadata: never clobber
      // user files — verify whatever prompt files are already there.
      notes.add('not a git checkout; left untouched, verifying files '
          'in place${haveGit ? '' : ' (local-only: git unavailable)'})');
      if (await _isEmptyDir(dir) && haveGit) {
        try {
          await _runGit(
            _parentOf(repo.localPath),
            <String>['clone', '--', repo.remoteUrl.trim(), repo.localPath],
          );
          notes.add('empty directory; cloned ${repo.remoteUrl.trim()}');
          final String branchNote = await _ensureBranch(repo);
          if (branchNote.isNotEmpty) notes.add(branchNote);
        } on GitException catch (e) {
          notes.add('clone into empty directory failed — '
              '${_brief(e.stderr.isEmpty ? e.message : e.stderr)}');
        }
      }
    }

    // Verify every prompt file; one bad file never fails the restore.
    int restored = 0;
    final List<String> skipped = <String>[];
    if (await dir.exists()) {
      for (final String promptDir in promptDirs) {
        final Directory sub = Directory(
          '${repo.localPath}${Platform.pathSeparator}$promptDir',
        );
        if (!await sub.exists()) continue;
        await for (final FileSystemEntity e
            in sub.list(recursive: true, followLinks: false)) {
          if (e is! File) continue;
          if (!e.path.toLowerCase().endsWith('.md')) continue;
          // Backup siblings from manual conflict resolution are not
          // prompts — never count or "verify" them as restored content.
          if (e.path.contains('.conflict-mine.bak') ||
              e.path.contains('.conflict-theirs.bak')) {
            continue;
          }
          try {
            fm.parse(await e.readAsString());
            restored++;
          } catch (_) {
            skipped.add(e.path); // malformed/unreadable: skip, never crash
          }
        }
      }
    }

    // Rebuild the PromptStore index (duplicateIds/skippedFiles) over the
    // checkout. Best-effort: index trouble is reported, not fatal.
    int indexed = -1;
    try {
      final PromptStore store = PromptStore();
      await store.init(libraryRoot: repo.localPath);
      indexed = (await store.listLocal()).length;
      await store.dispose();
    } catch (e) {
      notes.add('index rebuild failed (files still verified): $e');
    }

    return RepoRestoreStatus(
      repoId: repo.repoId,
      ok: true,
      localOnly: !haveGit,
      promptsRestored: restored,
      filesSkipped: skipped.length,
      skippedFiles: skipped,
      indexed: indexed,
      note: notes.join('; '),
    );
  }

  /// Syncs a single repo: `fetch` + `pull --ff-only`. Diverged or
  /// conflicting states fail plainly with conflicts listed — nothing is
  /// auto-resolved or overwritten.
  Future<RepoSyncStatus> syncRepo(RepoInfo repo) async {
    if (!repo.hasBinding) {
      return RepoSyncStatus(
        repoId: repo.repoId,
        ok: true,
        skipped: true,
        note: 'promptlib: no remote binding; disabled category left untouched',
      );
    }
    final Directory dir = Directory(repo.localPath);
    if (!await dir.exists() || !await _isCheckout(dir)) {
      return RepoSyncStatus(
        repoId: repo.repoId,
        ok: false,
        note: 'promptlib: ${repo.localPath} is not a checkout; '
            'run restoreAll first (nothing was changed)',
      );
    }
    if (!await isGitAvailable) {
      return RepoSyncStatus(
        repoId: repo.repoId,
        ok: true,
        localOnly: true,
        note: 'promptlib: system `git` not found — checkout left untouched '
            '(local-only mode); install git to enable sync',
      );
    }
    try {
      await _runGit(repo.localPath, const <String>['fetch', 'origin']);
    } on GitException catch (e) {
      return RepoSyncStatus(
        repoId: repo.repoId,
        ok: false,
        note: 'promptlib: fetch of ${repo.repoId} failed — '
            '${_brief(e.stderr.isEmpty ? e.message : e.stderr)}',
      );
    }
    final GitService svc = _gitServices(repo.localPath);
    try {
      await svc.pull();
    } on GitNotAvailableException catch (e) {
      return RepoSyncStatus(
        repoId: repo.repoId,
        ok: true,
        localOnly: true,
        note: e.toString(),
      );
    } on GitException catch (e) {
      // --ff-only refuses diverged states without touching the worktree.
      // Surface any pre-existing unmerged paths (e.g. from a manual
      // fetch+merge) so the caller can resolve them file by file.
      List<String> conflicted = <String>[];
      try {
        conflicted = await svc.conflictedFiles();
      } catch (_) {
        conflicted = <String>[];
      }
      return RepoSyncStatus(
        repoId: repo.repoId,
        ok: false,
        conflicts: conflicted,
        note: 'promptlib: pull --ff-only of ${repo.repoId} refused '
            '(diverged or conflicting changes; resolve manually — nothing '
            'was auto-resolved) — ${_brief(e.stderr.isEmpty ? e.message : e.stderr)}',
      );
    }
    List<String> leftover = <String>[];
    try {
      leftover = await svc.conflictedFiles();
    } catch (_) {
      leftover = <String>[];
    }
    return RepoSyncStatus(
      repoId: repo.repoId,
      ok: leftover.isEmpty,
      pulled: true,
      conflicts: leftover,
      note: leftover.isEmpty
          ? 'fast-forwarded cleanly'
          : 'promptlib: pull completed with ${leftover.length} unmerged '
              'path(s); resolve via resolveRepoConflicts',
    );
  }

  /// Resolves conflicted files in one repo, one file at a time.
  ///
  /// Each entry goes through [GitService.resolveConflict]:
  /// * [ConflictChoice.mine] / [ConflictChoice.theirs] keeps one side
  ///   (the loser stays reachable in history — no data loss);
  /// * [ConflictChoice.manual] writes [ConflictResolution.manualContent]
  ///   only after both stage blobs are preserved to sibling
  ///   `*.conflict-mine.bak` / `*.conflict-theirs.bak` files (numeric
  ///   suffix when taken).
  ///
  /// Resolutions are left staged; committing + pushing stays the caller's
  /// explicit step (e.g. `git commit -m 'promptlib(library): resolve …'`
  /// then [GitService.push]). Per-file failures are collected, never
  /// thrown. Throws [ArgumentError] for an unknown [repoId] and
  /// [GitNotAvailableException] when git is missing.
  Future<ResolveSummary> resolveRepoConflicts({
    required String repoId,
    required List<ConflictResolution> resolutions,
  }) async {
    final RepoInfo repo = repos.firstWhere(
      (RepoInfo r) => r.repoId == repoId,
      orElse: () =>
          throw ArgumentError('promptlib: unknown repoId "$repoId"'),
    );
    if (!await isGitAvailable) {
      throw const GitNotAvailableException();
    }
    final GitService svc = _gitServices(repo.localPath);
    final List<FileResolveResult> out = <FileResolveResult>[];
    for (final ConflictResolution res in resolutions) {
      final Set<String> before = res.choice == ConflictChoice.manual
          ? await _bakSiblings(repo.localPath, res.path)
          : <String>{};
      try {
        await svc.resolveConflict(
          path: res.path,
          choice: res.choice,
          manualContent: res.manualContent,
        );
        List<String> backups = <String>[];
        if (res.choice == ConflictChoice.manual) {
          final Set<String> after =
              await _bakSiblings(repo.localPath, res.path);
          backups = after.difference(before).toList()..sort();
        }
        out.add(FileResolveResult(
          path: res.path,
          ok: true,
          backups: backups,
          note: res.choice == ConflictChoice.manual
              ? 'manual merge staged; both sides preserved to ${backups.length} .bak file(s)'
              : 'kept ${res.choice.name}; loser stays reachable in history',
        ));
      } on GitException catch (e) {
        out.add(FileResolveResult(
          path: res.path,
          ok: false,
          note: _brief(e.stderr.isEmpty ? e.message : e.stderr),
        ));
      } on ArgumentError catch (e) {
        out.add(FileResolveResult(
          path: res.path,
          ok: false,
          note: e.toString(),
        ));
      }
    }
    return ResolveSummary(repoId: repoId, results: out);
  }

  // ---- internals ----

  Future<ProcessResult> _runGit(
      String workdir, List<String> args) async {
    ProcessResult r;
    try {
      r = await Process.run(gitBinary, args, workingDirectory: workdir);
    } on ProcessException catch (e) {
      throw GitNotAvailableException(
        'promptlib: system `git` binary not found ($e). Install git to '
        'enable versioning and sync; library files still work local-only.',
      );
    }
    if (r.exitCode != 0) {
      throw GitException(
        'promptlib: git ${args.join(' ')} failed',
        exitCode: r.exitCode,
        stderr: '${r.stdout}${r.stderr}'.trim(),
      );
    }
    return r;
  }

  Future<bool> _isCheckout(Directory dir) async =>
      await File('${dir.path}${Platform.pathSeparator}.git${Platform.pathSeparator}HEAD')
          .exists() ||
      await File(
              '${dir.path}${Platform.pathSeparator}.git')
          .exists();

  Future<bool> _isEmptyDir(Directory dir) async {
    try {
      await for (final _ in dir.list(followLinks: false)) {
        return false;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  String _parentOf(String path) {
    final String parent = File(path).parent.path;
    return parent.isEmpty ? Directory.systemTemp.path : parent;
  }

  /// Best-effort checkout of [RepoInfo.defaultBranch] after a clone.
  /// Returns a note fragment, or '' when already on the branch / nothing
  /// needed. Never throws.
  Future<String> _ensureBranch(RepoInfo repo) async {
    final String want = repo.defaultBranch.trim();
    if (want.isEmpty) return '';
    try {
      final ProcessResult current = await _runGit(
        repo.localPath,
        const <String>['branch', '--show-current'],
      );
      if ('${current.stdout}'.trim() == want) return '';
      final ProcessResult listed = await _runGit(
        repo.localPath,
        <String>['branch', '--list', want],
      );
      if ('${listed.stdout}'.trim().isEmpty) {
        return 'remote has no branch "$want"; kept clone default';
      }
      await _runGit(repo.localPath, <String>['checkout', want]);
      return 'checked out $want';
    } catch (e) {
      return 'branch checkout skipped: ${_brief('$e')}';
    }
  }

  /// Sibling `.bak` files already present for [repoRelativePath].
  Future<Set<String>> _bakSiblings(
      String checkout, String repoRelativePath) async {
    final String rel = repoRelativePath.trim().replaceAll('\\', '/');
    final String full =
        '$checkout${Platform.pathSeparator}$rel';
    final File f = File(full);
    final Directory parent = f.parent;
    final String base = f.uri.pathSegments.last;
    final Set<String> out = <String>{};
    try {
      await for (final FileSystemEntity e
          in parent.list(followLinks: false)) {
        if (e is! File) continue;
        final String name = e.uri.pathSegments.last;
        if (name == '$base.conflict-mine.bak' ||
            name == '$base.conflict-theirs.bak' ||
            name.startsWith('$base.conflict-mine.bak-') ||
            name.startsWith('$base.conflict-theirs.bak-')) {
          out.add(e.path);
        }
      }
    } catch (_) {
      // Best-effort inventory; resolution itself reports real failures.
    }
    return out;
  }

  /// First line(s) of git output for status notes (capped, no newlines).
  static String _brief(String s) {
    // ignore: no-magic-number (display cap, not logic)
    const int cap = 300;
    final String oneLine = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (oneLine.length <= cap) return oneLine;
    return '${oneLine.substring(0, cap)}…';
  }
}
