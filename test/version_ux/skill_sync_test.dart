/// Saved-skill remote checks over SkillsCacheService: remote-HEAD lookup,
// dirty detection, and pin-record round-trips. Offline-safe by construction:
// the "remote" is a throwaway local git repo, so `ls-remote` never needs the
// network.
import 'dart:io';

import 'package:test/test.dart';
import 'package:ice_cream_rss_reader/promptlib/version_ux.dart';
import 'package:ice_cream_rss_reader/services/skills/skills_cache_service.dart';

/// Creates a git repo with one committed `skills/pdf/SKILL.md` and returns
/// its directory. Throws on git failure (git is required for this file).
Future<Directory> _seedRepo(Directory parent) async {
  final Directory repo =
      Directory('${parent.path}${Platform.pathSeparator}origin');
  await repo.create(recursive: true);
  Future<void> git(List<String> args) async {
    final ProcessResult r = await Process.run(
      'git',
      args,
      workingDirectory: repo.path,
      environment: {'GIT_TERMINAL_PROMPT': '0'},
    );
    if (r.exitCode != 0) {
      throw StateError('git ${args.join(' ')} failed: ${r.stderr}');
    }
  }

  await git(['init', '-b', 'main']);
  await git(['config', 'user.email', 'test@local']);
  await git(['config', 'user.name', 'test']);
  final Directory skillDir = Directory(
    '${repo.path}${Platform.pathSeparator}skills'
    '${Platform.pathSeparator}pdf',
  );
  await skillDir.create(recursive: true);
  await File('${skillDir.path}${Platform.pathSeparator}SKILL.md')
      .writeAsString('# PDF skill\n\nv1 body\n');
  await git(['add', '.']);
  await git(['commit', '-m', 'seed skill']);
  return repo;
}

Future<String> _headSha(Directory repo) async {
  final ProcessResult r = await Process.run(
    'git',
    const ['rev-parse', 'HEAD'],
    workingDirectory: repo.path,
  );
  return (r.stdout as String).trim();
}

void main() {
  late Directory tmp;
  late Directory origin;
  late SkillsCacheService cache;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('promptlib_skillsync_');
    origin = await _seedRepo(tmp);
    cache = SkillsCacheService(
      baseDir: Directory('${tmp.path}${Platform.pathSeparator}cache'),
    );
  });

  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {
      // Best-effort temp cleanup.
    }
  });

  group('remoteHeadSha', () {
    test('resolves the remote HEAD without cloning', () async {
      final String? sha =
          await cache.remoteHeadSha(origin.path, ref: 'main');
      expect(sha, await _headSha(origin));
    });

    test('unknown repo degrades to null, never throws', () async {
      expect(
        await cache.remoteHeadSha(
          '${tmp.path}${Platform.pathSeparator}does-not-exist',
          ref: 'main',
          timeout: const Duration(seconds: 10),
        ),
        isNull,
      );
    });
  });

  group('ensure + pin record', () {
    test('clone writes a pin whose SHA matches remote HEAD', () async {
      final Directory dir = await cache.ensure(
        origin.path,
        ref: 'main',
        sparsePaths: const ['skills/pdf'],
      );
      expect(await dir.exists(), isTrue);
      final SkillRepoMeta? meta =
          await cache.readMeta(origin.path, ref: 'main');
      expect(meta, isNotNull);
      expect(meta!.commitSha, await _headSha(origin));

      // Tri-state over SHAs: pinned == remote means in-sync.
      final String? remote =
          await cache.remoteHeadSha(origin.path, ref: 'main');
      expect(
        determineSyncState(
          localHash: meta.commitSha,
          baseHash: meta.commitSha,
          remoteHash: remote,
        ),
        ItemSyncState.inSync,
      );
    });

    test('new upstream commit reads as remote-ahead', () async {
      await cache.ensure(
        origin.path,
        ref: 'main',
        sparsePaths: const ['skills/pdf'],
      );
      final SkillRepoMeta? before =
          await cache.readMeta(origin.path, ref: 'main');
      // Upstream moves.
      await File(
        '${origin.path}${Platform.pathSeparator}skills'
        '${Platform.pathSeparator}pdf'
        '${Platform.pathSeparator}SKILL.md',
      ).writeAsString('# PDF skill\n\nv2 body\n');
      final ProcessResult commit = await Process.run(
        'git',
        const ['commit', '-am', 'v2'],
        workingDirectory: origin.path,
      );
      expect(commit.exitCode, 0);
      final String? remote =
          await cache.remoteHeadSha(origin.path, ref: 'main');
      expect(remote, isNot(await _headSha(Directory(tmp.path))));
      expect(
        determineSyncState(
          localHash: before!.commitSha,
          baseHash: before.commitSha,
          remoteHash: remote,
        ),
        ItemSyncState.remoteNewer,
      );
    });

    test('dirty checkout reads as edited-locally', () async {
      final Directory dir = await cache.ensure(
        origin.path,
        ref: 'main',
        sparsePaths: const ['skills/pdf'],
      );
      expect(
        await cache.isSkillDirty(origin.path, 'skills/pdf', ref: 'main'),
        isFalse,
      );
      await File(
        '${dir.path}${Platform.pathSeparator}skills'
        '${Platform.pathSeparator}pdf'
        '${Platform.pathSeparator}SKILL.md',
      ).writeAsString('# PDF skill\n\nlocal tweak\n', mode: FileMode.write);
      expect(
        await cache.isSkillDirty(origin.path, 'skills/pdf', ref: 'main'),
        isTrue,
      );
    });

    test('history + checkpoint read stay working', () async {
      await cache.ensure(
        origin.path,
        ref: 'main',
        sparsePaths: const ['skills/pdf'],
      );
      final List<SkillCheckpoint> history = await cache.history(
        origin.path,
        'skills/pdf',
        ref: 'main',
      );
      expect(history, isNotEmpty);
      final String? body = await cache.readFileAt(
        origin.path,
        'skills/pdf/SKILL.md',
        sha: history.first.sha,
        ref: 'main',
      );
      expect(body, contains('v1 body'));
    });
  });
}
