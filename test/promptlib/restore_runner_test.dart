/// RestoreRunner tests: fresh clone + verify + skip-bad-file, diverged
/// pull refusal, and conflict resolution with no data loss.
///
/// All git scenarios run against temp bare remotes via the system `git`.
/// When no `git` binary is present the git-backed tests fall back to
/// asserting the local-only path (nothing cloned, clear notes, no throws);
/// the git-absent + unbound-repo tests always run (they need no git).
import 'dart:io';

import 'package:test/test.dart';
import 'package:ice_cream_rss_reader/promptlib/front_matter.dart' as fm;
import 'package:ice_cream_rss_reader/promptlib/git_service.dart';
import 'package:ice_cream_rss_reader/promptlib/prompt_doc.dart';
import 'package:ice_cream_rss_reader/promptlib/restore_runner.dart';

Future<ProcessResult> _git(
  List<String> args,
  String workdir, {
  bool expectOk = true,
}) async {
  final ProcessResult r =
      await Process.run('git', args, workingDirectory: workdir);
  if (expectOk && r.exitCode != 0) {
    fail('git ${args.join(' ')} in $workdir failed '
        '(exit ${r.exitCode}): ${r.stdout}${r.stderr}');
  }
  return r;
}

Future<bool> _haveGit() async {
  try {
    final ProcessResult r = await Process.run('git', const ['--version']);
    return r.exitCode == 0;
  } on ProcessException {
    return false;
  }
}

Future<void> _configUser(String workdir) async {
  await _git(['config', 'user.email', 'test@promptlib.dev'], workdir);
  await _git(['config', 'user.name', 'PromptLib Test'], workdir);
  await _git(['config', 'commit.gpgsign', 'false'], workdir);
}

String _doc(String id, String title, String body) => fm.serialize(
      PromptDoc(id: id, title: title, body: body),
    );

void main() {
  final List<Directory> dirs = <Directory>[];

  Future<Directory> mkTemp(String prefix) async {
    final Directory d = await Directory.systemTemp.createTemp(prefix);
    dirs.add(d);
    return d;
  }

  tearDown(() async {
    for (final Directory d in dirs) {
      if (await d.exists()) {
        await d.delete(recursive: true);
      }
    }
    dirs.clear();
  });

  /// Bare remote seeded with one good prompt; returns the bare dir.
  Future<Directory> seedBare({String body = 'hello'}) async {
    final Directory bare = await mkTemp('promptlib_rs_bare_');
    await _git(['init', '--bare', '-b', 'main'], bare.path);
    final Directory seed = await mkTemp('promptlib_rs_seed_');
    await _git(['clone', bare.path, seed.path], Directory.systemTemp.path);
    await _configUser(seed.path);
    await Directory('${seed.path}/library').create(recursive: true);
    await File('${seed.path}/library/good.md')
        .writeAsString(_doc('good', 'Good', body));
    await _git(['add', '--', 'library'], seed.path);
    await _git(['commit', '-m', 'promptlib(library): seed'], seed.path);
    await _git(['push', '-u', 'origin', 'main'], seed.path);
    return bare;
  }

  group('unbound repos (no git needed)', () {
    test('disabled category is skipped untouched', () async {
      final Directory root = await mkTemp('promptlib_rs_unbound_');
      final String target = '${root.path}/clone';
      final RestoreRunner runner = RestoreRunner(repos: <RepoInfo>[
        RepoInfo(repoId: 'disabled', remoteUrl: '', localPath: target),
        RepoInfo(repoId: 'blank', remoteUrl: '   ', localPath: '$target-2'),
      ]);
      final RestoreSummary restored = await runner.restoreAll();
      expect(restored.reposOk, 0);
      expect(restored.reposFailed, 0);
      expect(restored.results.every((RepoRestoreStatus r) => r.skipped),
          isTrue);
      expect(Directory(target).existsSync(), isFalse,
          reason: 'unbound repos must not touch the filesystem');

      final SyncSummary synced = await runner.syncAll();
      expect(synced.reposOk, 0);
      expect(synced.reposFailed, 0);
      expect(synced.results.every((RepoSyncStatus r) => r.skipped), isTrue);
    });

    test('RepoInfo rejects empty repoId/localPath', () {
      expect(() => RepoInfo(repoId: '', remoteUrl: '', localPath: '/x'),
          throwsA(isA<ArgumentError>()));
      expect(() => RepoInfo(repoId: 'a', remoteUrl: '', localPath: '  '),
          throwsA(isA<ArgumentError>()));
    });
  });

  group('git absent (no system git needed)', () {
    test('restoreAll + syncAll degrade to a reported local-only path',
        () async {
      final Directory root = await mkTemp('promptlib_rs_nogit_');
      final RestoreRunner runner = RestoreRunner(
        repos: <RepoInfo>[
          RepoInfo(
            repoId: 'r1',
            remoteUrl: '/nonexistent/remote.git',
            localPath: '${root.path}/clone',
          ),
        ],
        gitBinary: '__promptlib_definitely_missing_binary__',
      );
      expect(await runner.isGitAvailable, isFalse);

      final RestoreSummary restored = await runner.restoreAll();
      expect(restored.reposOk, 0);
      expect(restored.reposFailed, 1);
      final RepoRestoreStatus status = restored.results.single;
      expect(status.localOnly, isTrue);
      expect(status.note, contains('local-only'));

      final SyncSummary synced = await runner.syncAll();
      // Nothing checked out: actionable note, no throws, no pushes.
      expect(synced.reposFailed, 1);
      expect(synced.results.single.note, contains('restoreAll'));

      expect(
        runner.resolveRepoConflicts(
          repoId: 'r1',
          resolutions: const <ConflictResolution>[],
        ),
        throwsA(isA<GitNotAvailableException>()));
      expect(
        runner.resolveRepoConflicts(
          repoId: 'nope',
          resolutions: const <ConflictResolution>[],
        ),
        throwsA(isA<ArgumentError>()));
    });

    test('sync of an existing checkout without git is local-only, untouched',
        () async {
      final Directory root = await mkTemp('promptlib_rs_nogitlocal_');
      // Fake a checkout shape (no real git needed for this assertion).
      final Directory fake = Directory('${root.path}/fake');
      await Directory('${fake.path}/.git').create(recursive: true);
      await File('${fake.path}/.git/HEAD').writeAsString('ref: refs/heads/main\n');
      await Directory('${fake.path}/library').create(recursive: true);
      await File('${fake.path}/library/kept.md')
          .writeAsString(_doc('kept', 'Kept', 'mine'));
      final RestoreRunner runner = RestoreRunner(
        repos: <RepoInfo>[
          RepoInfo(
              repoId: 'fake',
              remoteUrl: '/nonexistent/remote.git',
              localPath: fake.path),
        ],
        gitBinary: '__promptlib_definitely_missing_binary__',
      );
      final SyncSummary synced = await runner.syncAll();
      expect(synced.results.single.localOnly, isTrue);
      expect(synced.results.single.pulled, isFalse);
      expect(await File('${fake.path}/library/kept.md').readAsString(),
          contains('mine'), reason: 'local-only sync must not touch files');
    });
  });

  group('fresh restore (temp bare remote)', () {
    test('clone + verify + skip-bad-file, idempotent re-run', () async {
      if (!await _haveGit()) {
        // Graceful fallback: assert the local-only path instead.
        final Directory root = await mkTemp('promptlib_rs_fallback_');
        final RestoreRunner runner = RestoreRunner(
          repos: <RepoInfo>[
            RepoInfo(
                repoId: 'r',
                remoteUrl: '/nonexistent/remote.git',
                localPath: '${root.path}/clone'),
          ],
          gitBinary: '__promptlib_definitely_missing_binary__',
        );
        final RestoreSummary s = await runner.restoreAll();
        expect(s.reposFailed, 1);
        expect(s.results.single.localOnly, isTrue);
        return;
      }
      final Directory bare = await seedBare();
      // Add a broken file + a prompts/-layout file to the seed.
      final Directory seed2 = await mkTemp('promptlib_rs_seed2_');
      await _git(
          ['clone', bare.path, seed2.path], Directory.systemTemp.path);
      await _configUser(seed2.path);
      await File('${seed2.path}/library/broken.md')
          .writeAsString('---\nthis is not: : valid\n---\nbody');
      await Directory('${seed2.path}/prompts').create(recursive: true);
      await File('${seed2.path}/prompts/extra.md')
          .writeAsString(_doc('extra', 'Extra', 'more'));
      await _git(['add', '--', 'library', 'prompts'], seed2.path);
      await _git(
          ['commit', '-m', 'promptlib(library): add broken + extra'],
          seed2.path);
      await _git(['push'], seed2.path);

      final Directory root = await mkTemp('promptlib_rs_fresh_');
      final RestoreRunner runner = RestoreRunner(repos: <RepoInfo>[
        RepoInfo(
            repoId: 'main', remoteUrl: bare.path, localPath: '${root.path}/c'),
      ]);
      final RestoreSummary first = await runner.restoreAll();
      expect(first.reposOk, 1);
      expect(first.reposFailed, 0);
      expect(first.promptsRestored, 2,
          reason: 'good.md + prompts/extra.md parse; broken.md skipped');
      expect(first.filesSkipped, 1);
      expect(first.results.single.skippedFiles.single.endsWith('broken.md'),
          isTrue);
      expect(
          await File('${root.path}/c/library/good.md').readAsString(),
          contains('hello'));
      // The PromptStore index covers library/ (+ subscriptions mirrors),
      // not the prompts/ registry alias — so indexed == 1 (good.md) while
      // promptsRestored == 2 (good.md + prompts/extra.md verified).
      expect(first.results.single.indexed, 1);

      // Second run hits the existing-checkout path: same counts, no dupes.
      final RestoreSummary second = await runner.restoreAll();
      expect(second.reposOk, 1);
      expect(second.promptsRestored, 2);
      expect(second.filesSkipped, 1);
      expect(second.results.single.note, contains('existing checkout'));
    });
  });

  group('incremental sync (temp bare remote)', () {
    test('diverged pull --ff-only refuses without touching files', () async {
      if (!await _haveGit()) {
        final RestoreRunner runner = RestoreRunner(
          repos: <RepoInfo>[
            RepoInfo(
                repoId: 'r',
                remoteUrl: 'x',
                localPath: '/nonexistent-clone-path'),
          ],
          gitBinary: '__promptlib_definitely_missing_binary__',
        );
        final SyncSummary s = await runner.syncAll();
        expect(s.reposFailed, 1);
        return;
      }
      final Directory bare = await seedBare();

      Future<Directory> clone(String prefix) async {
        final Directory c = await mkTemp(prefix);
        await _git(['clone', bare.path, c.path], Directory.systemTemp.path);
        await _configUser(c.path);
        return c;
      }

      final Directory a = await clone('promptlib_rs_divA_');
      final Directory b = await clone('promptlib_rs_divB_');
      final String bPath = b.path;

      // A moves ahead and pushes.
      await File('${a.path}/library/a.md')
          .writeAsString(_doc('a', 'A', 'from A'));
      await _git(['add', '--', 'library/a.md'], a.path);
      await _git(['commit', '-m', 'promptlib(library): A edit'], a.path);
      await _git(['push'], a.path);

      // B commits a *different* file locally: now diverged.
      await File('${b.path}/library/b.md')
          .writeAsString(_doc('b', 'B', 'from B'));
      await _git(['add', '--', 'library/b.md'], b.path);
      await _git(['commit', '-m', 'promptlib(library): B edit'], b.path);

      final RestoreRunner runner = RestoreRunner(repos: <RepoInfo>[
        RepoInfo(repoId: 'b', remoteUrl: bare.path, localPath: bPath),
      ]);
      final SyncSummary synced = await runner.syncAll();
      expect(synced.reposOk, 0);
      expect(synced.reposFailed, 1);
      final RepoSyncStatus status = synced.results.single;
      expect(status.pulled, isFalse);
      expect(status.note, contains('--ff-only'));
      // Nothing auto-resolved or overwritten: B's work intact, A's absent.
      expect(await File('$bPath/library/b.md').readAsString(), contains('from B'));
      expect(File('$bPath/library/a.md').existsSync(), isFalse);
      expect(status.conflicts, isEmpty);
    });

    test('same-file conflict surfaces, manual resolve keeps .bak copies',
        () async {
      if (!await _haveGit()) {
        final RestoreRunner runner = RestoreRunner(
          repos: <RepoInfo>[
            RepoInfo(repoId: 'r', remoteUrl: 'x', localPath: '/non/existent'),
          ],
          gitBinary: '__promptlib_definitely_missing_binary__',
        );
        expect(
          runner.resolveRepoConflicts(
            repoId: 'r',
            resolutions: const <ConflictResolution>[
              ConflictResolution(
                  path: 'library/note.md', choice: ConflictChoice.mine),
            ],
          ),
          throwsA(isA<GitNotAvailableException>()));
        return;
      }
      final Directory bare = await seedBare(body: 'base line\n');
      Future<Directory> clone(String prefix) async {
        final Directory c = await mkTemp(prefix);
        await _git(['clone', bare.path, c.path], Directory.systemTemp.path);
        await _configUser(c.path);
        return c;
      }

      final Directory a = await clone('promptlib_rs_cfA_');
      final Directory b = await clone('promptlib_rs_cfB_');
      final String noteA = _doc('good', 'Good', 'base line\nline from A\n');
      final String noteB = _doc('good', 'Good', 'base line\nline from B\n');
      await File('${a.path}/library/good.md').writeAsString(noteA);
      await _git(['add', '--', 'library/good.md'], a.path);
      await _git(['commit', '-m', 'promptlib(library): A edit'], a.path);
      await _git(['push'], a.path);

      await File('${b.path}/library/good.md').writeAsString(noteB);
      await _git(['add', '--', 'library/good.md'], b.path);
      await _git(['commit', '-m', 'promptlib(library): B edit'], b.path);

      final RestoreRunner runner = RestoreRunner(repos: <RepoInfo>[
        RepoInfo(repoId: 'b', remoteUrl: bare.path, localPath: b.path),
      ]);

      // fetch+merge leaves a real unmerged conflict (raw git setup step).
      await _git(['fetch', 'origin'], b.path);
      await _git(['merge', 'origin/main'], b.path, expectOk: false);

      final SyncSummary synced = await runner.syncAll();
      expect(synced.results.single.conflicts, ['library/good.md']);

      final String mergedBody = 'base line\nline from A\nline from B\n';
      final String mergedDoc = _doc('good', 'Good', mergedBody);
      final ResolveSummary resolved = await runner.resolveRepoConflicts(
        repoId: 'b',
        resolutions: <ConflictResolution>[
          ConflictResolution(
            path: 'library/good.md',
            choice: ConflictChoice.manual,
            manualContent: mergedDoc,
          ),
        ],
      );
      expect(resolved.failed, 0);
      expect(resolved.resolved, 1);
      final FileResolveResult file = resolved.results.single;
      expect(file.backups, hasLength(2));
      final String mineBak = await File(file.backups
              .firstWhere((String p) => p.contains('conflict-mine')))
          .readAsString();
      final String theirsBak = await File(file.backups
              .firstWhere((String p) => p.contains('conflict-theirs')))
          .readAsString();
      expect(mineBak, contains('line from B'));
      expect(theirsBak, contains('line from A'));
      expect(await File('${b.path}/library/good.md').readAsString(),
          mergedDoc);
      expect(
          await ProcessGitService(
                  workingDirectory: b.path,
                  debounce: const Duration(minutes: 1))
              .conflictedFiles(),
          isEmpty);

      // Commit + push the resolution; the peer fast-forwards to it.
      await _git(
          ['commit', '-m', 'promptlib(library): resolve manual'], b.path);
      final ProcessGitService svcB = ProcessGitService(
        workingDirectory: b.path,
        debounce: const Duration(minutes: 1),
      );
      try {
        await svcB.push();
        final ProcessGitService svcA = ProcessGitService(
          workingDirectory: a.path,
          debounce: const Duration(minutes: 1),
        );
        try {
          await svcA.pull();
        } finally {
          svcA.dispose();
        }
      } finally {
        svcB.dispose();
      }
      expect(await File('${a.path}/library/good.md').readAsString(),
          mergedDoc);
    });
  });
}
