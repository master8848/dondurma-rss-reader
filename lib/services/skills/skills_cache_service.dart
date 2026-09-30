import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'skill_list_utils.dart';

/// A single folder-level checkpoint in a skill's git history.
class SkillCheckpoint {
  final String sha;
  final String message;
  final DateTime? date;

  const SkillCheckpoint({
    required this.sha,
    required this.message,
    this.date,
  });

  Map<String, dynamic> toJson() => {
    'sha': sha,
    'message': message,
    'date': date?.toIso8601String(),
  };
}

/// Pin record written to `<repoDir>/.mskill-meta.json` after every clone or
/// update — mirrors the `.mskill-meta.json`
/// `{host,owner,repo,ref,cloneUrl,commitSha,shallow,lastFetch}` shape from the
/// `mskill` reference design.
class SkillRepoMeta {
  final String host;
  final String owner;
  final String repo;
  final String ref;
  final String cloneUrl;
  final String commitSha;
  final bool shallow;
  final String lastFetch;

  const SkillRepoMeta({
    required this.host,
    required this.owner,
    required this.repo,
    required this.ref,
    required this.cloneUrl,
    required this.commitSha,
    required this.shallow,
    required this.lastFetch,
  });

  factory SkillRepoMeta.fromJson(Map<String, dynamic> json) {
    return SkillRepoMeta(
      host: json['host'] as String? ?? '',
      owner: json['owner'] as String? ?? '',
      repo: json['repo'] as String? ?? '',
      ref: json['ref'] as String? ?? '',
      cloneUrl: json['cloneUrl'] as String? ?? '',
      commitSha: json['commitSha'] as String? ?? '',
      shallow: json['shallow'] as bool? ?? true,
      lastFetch: json['lastFetch'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
    'host': host,
    'owner': owner,
    'repo': repo,
    'ref': ref,
    'cloneUrl': cloneUrl,
    'commitSha': commitSha,
    'shallow': shallow,
    'lastFetch': lastFetch,
  };
}

/// Parsed `host/owner/repo` coordinates of a git remote URL.
class SkillRepoCoords {
  final String host;
  final String owner;
  final String repo;

  const SkillRepoCoords({
    required this.host,
    required this.owner,
    required this.repo,
  });

  /// Parses HTTPS (`https://github.com/o/r[.git]`), SSH
  /// (`git@github.com:o/r[.git]`), and bare `host/o/r` forms.
  /// Returns null when the URL has no recognizable owner/repo.
  static SkillRepoCoords? parse(String url) {
    var u = url.trim();
    if (u.isEmpty) return null;
    if (u.endsWith('.git')) u = u.substring(0, u.length - 4);
    if (u.endsWith('/')) u = u.substring(0, u.length - 1);

    final ssh = RegExp(r'^[\w.+-]+@([^:]+):(.+)$').firstMatch(u);
    if (ssh != null) {
      final parts = ssh.group(2)!.split('/');
      if (parts.length < 2) return null;
      return SkillRepoCoords(
        host: ssh.group(1)!,
        owner: parts[parts.length - 2],
        repo: parts.last,
      );
    }
    final noScheme = u.contains('://')
        ? u.split('://').sublist(1).join('://')
        : u;
    final parts = noScheme.split('/').where((p) => p.isNotEmpty).toList();
    if (parts.length < 3) return null;
    return SkillRepoCoords(
      host: parts[parts.length - 3],
      owner: parts[parts.length - 2],
      repo: parts.last,
    );
  }
}

/// Git-backed folder cache for skill repos, mirroring the `mskill` design:
///
/// - cache root: `<baseDir>/repos/<host>/<owner>/<repo>/<ref>--<hash8>/`
///   where the suffix is `SkillListUtils.repoCacheKey` (FNV-1a 32-bit hex of
///   `host/owner/repo/ref`; a dependency-free stand-in for a truncated SHA).
/// - cache miss: `git clone --filter=blob:none --sparse --depth 1
///   --single-branch --branch REF` (blobless shallow sparse checkout) plus
///   a `.mskill-meta.json` pin record.
/// - second skill from the same repo: `sparse-checkout set --cone` in place
///   (paths are ADDED, never replaced).
/// - update: `git fetch --depth 1 origin REF` + `git reset --hard
///   FETCH_HEAD`, then refresh the pin record.
/// - history: folder-level checkpoints via `git log --format=... [-- <path>]`.
/// - checkpoint view: read-only file content via `git show <sha>:<path>`
///   (never moves the working tree).
///
/// No credentials are ever stored; every git invocation runs with
/// `GIT_TERMINAL_PROMPT=0` so a missing credential helper fails fast instead
/// of hanging on a password prompt.
///
/// Pure `dart:io` — no Flutter imports.
class SkillsCacheService {
  /// Base cache dir, e.g. `<app-support>/skills_cache`. Pass the
  /// app-support `skills_cache` folder from the provider.
  final Directory baseDir;

  SkillsCacheService({required this.baseDir});

  /// `…/repos` root holding one dir per cached repo+ref.
  Directory get reposDir =>
      Directory('${baseDir.path}${Platform.pathSeparator}repos');

  /// Derives the on-disk repo dir for [repoUrl] at [ref].
  /// Returns null when the URL cannot be parsed.
  Directory? repoDirFor(String repoUrl, {String ref = 'HEAD'}) {
    final coords = SkillRepoCoords.parse(repoUrl);
    if (coords == null) return null;
    final key = SkillListUtils.repoCacheKey(
      host: coords.host,
      owner: coords.owner,
      repo: coords.repo,
      ref: ref.isEmpty ? 'HEAD' : ref,
    );
    return Directory(
      [
        reposDir.path,
        coords.host,
        coords.owner,
        coords.repo,
        key,
      ].join(Platform.pathSeparator),
    );
  }

  /// Ensures a local checkout of [repoUrl] at [ref] exists and contains
  /// [sparsePaths] (skill subfolders). Returns the repo dir.
  ///
  /// - miss → blobless shallow sparse clone (+ meta record)
  /// - hit → `sparse-checkout add` for any missing paths, then fetch+reset
  ///   when [update] is true (default false: offline-friendly).
  Future<Directory> ensure(
    String repoUrl, {
    String ref = 'HEAD',
    List<String> sparsePaths = const [],
    bool update = false,
  }) async {
    final coords = SkillRepoCoords.parse(repoUrl);
    if (coords == null) {
      throw ArgumentError('Cannot parse repo URL: $repoUrl');
    }
    final dir = repoDirFor(repoUrl, ref: ref)!;
    final gitDir = Directory(
      '${dir.path}${Platform.pathSeparator}.git',
    );
    final effectiveRef = ref.isEmpty ? 'HEAD' : ref;

    if (!await gitDir.exists()) {
      await dir.parent.create(recursive: true);
      final cloneArgs = <String>[
        'clone',
        '--filter=blob:none',
        '--sparse',
        '--depth',
        '1',
        '--single-branch',
      ];
      if (effectiveRef != 'HEAD') {
        cloneArgs.addAll(['--branch', effectiveRef]);
      }
      cloneArgs.addAll([repoUrl, dir.path]);
      await _git(cloneArgs);
      if (sparsePaths.isNotEmpty) {
        await _git(
          ['sparse-checkout', 'set', '--cone', ...sparsePaths],
          workingDirectory: dir.path,
        );
      }
    } else {
      if (sparsePaths.isNotEmpty) {
        // `sparse-checkout add` keeps already-checked-out paths.
        final result = await _git(
          ['sparse-checkout', 'add', ...sparsePaths],
          workingDirectory: dir.path,
        );
        if (result.exitCode != 0) {
          // Older git without `add`: fall back to re-setting the union.
          final current = await _sparsePaths(dir.path);
          await _git(
            [
              'sparse-checkout',
              'set',
              '--cone',
              ...{...current, ...sparsePaths},
            ],
            workingDirectory: dir.path,
          );
        }
      }
      if (update) {
        await _git(
          ['fetch', '--depth', '1', 'origin', effectiveRef],
          workingDirectory: dir.path,
        );
        await _git(
          ['reset', '--hard', 'FETCH_HEAD'],
          workingDirectory: dir.path,
        );
      }
    }

    await _writeMeta(dir, coords, repoUrl, effectiveRef);
    return dir;
  }

  /// Folder-level checkpoint history for [skillPath] (relative to the repo
  /// root, e.g. `skills/pdf`) inside the cached repo for [repoUrl].
  /// Empty [skillPath] (or `.`) returns repo-level history.
  Future<List<SkillCheckpoint>> history(
    String repoUrl,
    String skillPath, {
    String ref = 'HEAD',
    int limit = 50,
  }) async {
    final dir = repoDirFor(repoUrl, ref: ref);
    if (dir == null || !await dir.exists()) return const [];
    final pathArg = skillPath.trim().isEmpty || skillPath.trim() == '.'
        ? <String>[]
        : <String>['--', skillPath];
    final result = await _git(
      [
        'log',
        '--format=%H%x1f%s%x1f%cI',
        '--max-count=$limit',
        ...pathArg,
      ],
      workingDirectory: dir.path,
    );
    if (result.exitCode != 0) return const [];
    final out = <SkillCheckpoint>[];
    for (final line in (result.stdout as String).split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      final parts = trimmed.split('\u001f');
      if (parts.isEmpty || parts.first.isEmpty) continue;
      out.add(
        SkillCheckpoint(
          sha: parts[0],
          message: parts.length > 1 ? parts[1] : '',
          date: parts.length > 2 ? DateTime.tryParse(parts[2]) : null,
        ),
      );
    }
    return out;
  }

  /// Reads the content of [relativePath] (repo-root-relative) at checkpoint
  /// [sha] via `git show <sha>:<path>`. Read-only: the working tree is never
  /// moved. Returns null when the file did not exist at that checkpoint.
  Future<String?> readFileAt(
    String repoUrl,
    String relativePath, {
    required String sha,
    String ref = 'HEAD',
  }) async {
    final dir = repoDirFor(repoUrl, ref: ref);
    if (dir == null || !await dir.exists()) return null;
    final result = await _git(
      ['show', '$sha:$relativePath'],
      workingDirectory: dir.path,
    );
    if (result.exitCode != 0) return null;
    return result.stdout as String;
  }

  /// Reads the `.mskill-meta.json` pin record, or null when absent/invalid.
  Future<SkillRepoMeta?> readMeta(String repoUrl, {String ref = 'HEAD'}) async {
    final dir = repoDirFor(repoUrl, ref: ref);
    if (dir == null) return null;
    final file = File(
      '${dir.path}${Platform.pathSeparator}.mskill-meta.json',
    );
    if (!await file.exists()) return null;
    try {
      final json =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      return SkillRepoMeta.fromJson(json);
    } catch (_) {
      return null;
    }
  }

  // -------------------------------------------------------------------------
  // Internals
  // -------------------------------------------------------------------------

  Future<ProcessResult> _git(
    List<String> args, {
    String? workingDirectory,
  }) {
    return Process.run(
      'git',
      args,
      workingDirectory: workingDirectory,
      environment: {'GIT_TERMINAL_PROMPT': '0'},
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
  }

  Future<Set<String>> _sparsePaths(String repoPath) async {
    final result = await _git(
      ['sparse-checkout', 'list'],
      workingDirectory: repoPath,
    );
    if (result.exitCode != 0) return const {};
    return (result.stdout as String)
        .split('\n')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toSet();
  }

  Future<void> _writeMeta(
    Directory dir,
    SkillRepoCoords coords,
    String cloneUrl,
    String ref,
  ) async {
    String sha = '';
    try {
      final result = await _git(
        ['rev-parse', 'HEAD'],
        workingDirectory: dir.path,
      );
      if (result.exitCode == 0) sha = (result.stdout as String).trim();
    } catch (_) {
      // Best-effort: meta still written without the SHA.
    }
    final meta = SkillRepoMeta(
      host: coords.host,
      owner: coords.owner,
      repo: coords.repo,
      ref: ref,
      cloneUrl: cloneUrl,
      commitSha: sha,
      shallow: true,
      lastFetch: DateTime.now().toUtc().toIso8601String(),
    );
    try {
      await File(
        '${dir.path}${Platform.pathSeparator}.mskill-meta.json',
      ).writeAsString(jsonEncode(meta.toJson()));
    } catch (_) {
      // Cache must keep working even if the meta write fails.
    }
  }
}
