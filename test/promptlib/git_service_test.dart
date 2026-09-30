/// WP5 tests: GitService push/manage flow over temp repos via system git.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ice_cream_rss_reader/promptlib/git_service.dart';

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

Future<Directory> _tempDir(String prefix) =>
    Directory.systemTemp.createTemp(prefix);

Future<void> _initRepo(Directory dir) async {
  await _git(['init', '-b', 'main'], dir.path);
  await _git(['config', 'user.email', 'test@promptlib.dev'], dir.path);
  await _git(['config', 'user.name', 'PromptLib Test'], dir.path);
  await _git(['config', 'commit.gpgsign', 'false'], dir.path);
}

Future<String> _head(String workdir) async =>
    '${(await _git(['rev-parse', 'HEAD'], workdir)).stdout}'.trim();

void main() {
  final List<Directory> dirs = <Directory>[];
  final List<ProcessGitService> services = <ProcessGitService>[];

  Future<Directory> mkTemp(String prefix) async {
    final Directory d = await _tempDir(prefix);
    dirs.add(d);
    return d;
  }

  ProcessGitService svc(String workdir, {Duration? debounce}) {
    final ProcessGitService s = ProcessGitService(
      workingDirectory: workdir,
      debounce: debounce ?? const Duration(minutes: 1),
    );
    services.add(s);
    return s;
  }

  tearDown(() async {
    for (final ProcessGitService s in services) {
      s.dispose();
    }
    services.clear();
    for (final Directory d in dirs) {
      if (await d.exists()) {
        await d.delete(recursive: true);
      }
    }
    dirs.clear();
  });

  group('availability', () {
    test('real git is available', () async {
      final Directory repo = await mkTemp('promptlib_git_avail_');
      await _initRepo(repo);
      expect(await svc(repo.path).isGitAvailable, isTrue);
    });

    test('missing binary degrades with a clear error', () async {
      final Directory repo = await mkTemp('promptlib_git_missing_');
      final ProcessGitService missing = ProcessGitService(
        workingDirectory: repo.path,
        gitBinary: '__promptlib_definitely_missing_binary__',
      );
      services.add(missing);
      expect(await missing.isGitAvailable, isFalse);
      expect(
        missing.ensureAvailable,
        throwsA(isA<GitNotAvailableException>()),
      );
      expect(
        missing.push,
        throwsA(
          isA<GitNotAvailableException>().having(
            (GitNotAvailableException e) => e.toString(),
            'message',
            contains('Install git'),
          ),
        ),
      );
      expect(missing.pull, throwsA(isA<GitNotAvailableException>()));
      expect(
        missing.conflictedFiles,
        throwsA(isA<GitNotAvailableException>()),
      );
    });
  });

  group('conventional messages', () {
    test('scoped messages pass through', () {
      expect(
        ProcessGitService.conventionalMessage(
            'promptlib(library): save note'),
        'promptlib(library): save note',
      );
      expect(
        ProcessGitService.conventionalMessage(
            'promptlib(subscriptions): mirror feed'),
        'promptlib(subscriptions): mirror feed',
      );
      expect(
        ProcessGitService.conventionalMessage(
            'promptlib(.promptlib): registry update'),
        'promptlib(.promptlib): registry update',
      );
    });

    test('legacy + bare messages gain the library scope', () {
      expect(
        ProcessGitService.conventionalMessage('promptlib: save note'),
        'promptlib(library): save note',
      );
      expect(
        ProcessGitService.conventionalMessage('save note'),
        'promptlib(library): save note',
      );
    });
  });

  group('autoCommit', () {
    test('commits library writes with a conventional message', () async {
      final Directory repo = await mkTemp('promptlib_git_commit_');
      await _initRepo(repo);
      await Directory('${repo.path}/library').create();
      final ProcessGitService s = svc(repo.path);
      await File('${repo.path}/library/note.md').writeAsString('hello');
      await s.autoCommit('promptlib: save note.md');
      await s.flush();
      final List<CommitInfo> entries = await s.log();
      expect(entries, hasLength(1));
      expect(entries.single.message, 'promptlib(library): save note.md');
      // Committed: nothing left to commit under library/.
      expect(await s.statusShort(), isEmpty);
    });

    test('rapid autoCommits coalesce into one commit', () async {
      final Directory repo = await mkTemp('promptlib_git_debounce_');
      await _initRepo(repo);
      await Directory('${repo.path}/library').create();
      final ProcessGitService s = svc(repo.path);
      await File('${repo.path}/library/a.md').writeAsString('a');
      await s.autoCommit('promptlib: save a.md');
      await File('${repo.path}/library/b.md').writeAsString('b');
      await s.autoCommit('promptlib: save b.md');
      await s.flush();
      final List<CommitInfo> entries = await s.log();
      expect(entries, hasLength(1));
      expect(entries.single.message, contains('save a.md'));
      expect(entries.single.message, contains('+1 more'));
    });

    test('never sweeps unrelated repo files', () async {
      final Directory repo = await mkTemp('promptlib_git_scope_');
      await _initRepo(repo);
      await Directory('${repo.path}/library').create();
      final ProcessGitService s = svc(repo.path);
      await File('${repo.path}/library/note.md').writeAsString('hi');
      await File('${repo.path}/unrelated.txt').writeAsString('mine');
      await s.autoCommit('promptlib: save note.md');
      await s.flush();
      final List<String> status = await s.statusShort();
      expect(
        status.any((String l) => l.contains('unrelated.txt')),
        isTrue,
        reason: 'unrelated files must stay untracked/uncommitted',
      );
    });

    test('flush with nothing pending is a no-op', () async {
      final Directory repo = await mkTemp('promptlib_git_noop_');
      await _initRepo(repo);
      final ProcessGitService s = svc(repo.path);
      await s.flush(); // must not throw
      expect(await s.conflictedFiles(), isEmpty);
    });
  });

  group('push / pull happy path (temp remote)', () {
    test('push publishes, pull fast-forwards', () async {
      final Directory bare = await mkTemp('promptlib_git_bare_');
      await _git(['init', '--bare', '-b', 'main'], bare.path);

      final Directory a = await mkTemp('promptlib_git_cloneA_');
      await _git(['clone', bare.path, a.path], Directory.systemTemp.path);
      await _git(['config', 'user.email', 'test@promptlib.dev'], a.path);
      await _git(['config', 'user.name', 'PromptLib Test'], a.path);
      final ProcessGitService svcA = svc(a.path);

      await Directory('${a.path}/library').create(recursive: true);
      await File('${a.path}/library/note.md').writeAsString('from A');
      await svcA.autoCommit('promptlib(library): add note');
      await svcA.flush();
      await svcA.push();

      // A second clone sees the pushed file after pulling.
      final Directory b = await mkTemp('promptlib_git_cloneB_');
      await _git(['clone', bare.path, b.path], Directory.systemTemp.path);
      await _git(['config', 'user.email', 'test@promptlib.dev'], b.path);
      await _git(['config', 'user.name', 'PromptLib Test'], b.path);
      final ProcessGitService svcB = svc(b.path);
      expect(await File('${b.path}/library/note.md').readAsString(), 'from A');

      // B commits + pushes; A pull fast-forwards to it.
      await File('${b.path}/library/note.md').writeAsString('from B');
      await svcB.autoCommit('promptlib(library): edit note');
      await svcB.flush();
      await svcB.push();
      await svcA.pull();
      expect(await File('${a.path}/library/note.md').readAsString(), 'from B');
    });

    test('push with a broken remote surfaces stderr plainly', () async {
      final Directory repo = await mkTemp('promptlib_git_badremote_');
      await _initRepo(repo);
      await Directory('${repo.path}/library').create();
      await File('${repo.path}/library/n.md').writeAsString('x');
      final ProcessGitService s = svc(repo.path);
      await s.autoCommit('promptlib: save n.md');
      await s.flush();
      await _git(
          ['remote', 'add', 'origin', '/nonexistent/promptlib-remote.git'],
          repo.path);
      final Object? err = await s.push.then<Object?>(
        (_) => null,
        onError: (Object e) => e,
      );
      expect(err, isA<GitException>());
      final GitException ge = err as GitException;
      expect(ge.stderr, isNotEmpty);
      expect(ge.toString(), contains('git push failed'));
    });

    test('diverged pull --ff-only fails without auto-resolving', () async {
      final Directory bare = await mkTemp('promptlib_git_divbare_');
      await _git(['init', '--bare', '-b', 'main'], bare.path);

      Future<Directory> freshClone(String prefix) async {
        final Directory c = await mkTemp(prefix);
        await _git(['clone', bare.path, c.path], Directory.systemTemp.path);
        await _git(['config', 'user.email', 't@promptlib.dev'], c.path);
        await _git(['config', 'user.name', 'T'], c.path);
        return c;
      }

      final Directory seed = await freshClone('promptlib_git_seed_');
      await Directory('${seed.path}/library').create(recursive: true);
      await File('${seed.path}/library/n.md').writeAsString('seed');
      final ProcessGitService seedSvc = svc(seed.path);
      await seedSvc.autoCommit('promptlib: seed');
      await seedSvc.flush();
      await seedSvc.push();

      final Directory a = await freshClone('promptlib_git_divA_');
      final Directory b = await freshClone('promptlib_git_divB_');
      final ProcessGitService svcA = svc(a.path);
      await File('${a.path}/library/a.md').writeAsString('a-side');
      await svcA.autoCommit('promptlib: a-side');
      await svcA.flush();
      await svcA.push();

      await File('${b.path}/library/b.md').writeAsString('b-side');
      final ProcessGitService svcB = svc(b.path);
      await svcB.autoCommit('promptlib: b-side');
      await svcB.flush();
      await svcB.push().then<void>(
        (_) => fail('push of diverged B should fail'),
        onError: (Object e) {
          expect(e, isA<GitException>());
        },
      );
      // --ff-only pull refuses the diverged state and resolves nothing.
      await svcB.pull().then<void>(
        (_) => fail('pull --ff-only of diverged B should fail'),
        onError: (Object e) {
          expect(e, isA<GitException>());
          expect(e.toString(), contains('--ff-only'));
        },
      );
      expect(await svcB.conflictedFiles(), isEmpty);
      expect(await _head(b.path), isNotEmpty);
    });
  });

  group('history + revert', () {
    test('log scopes to path; revertFile restores an older rev', () async {
      final Directory repo = await mkTemp('promptlib_git_hist_');
      await _initRepo(repo);
      await Directory('${repo.path}/library').create();
      final ProcessGitService s = svc(repo.path);
      await File('${repo.path}/library/note.md').writeAsString('v1');
      await s.autoCommit('promptlib: v1');
      await s.flush();
      final String rev1 = await _head(repo.path);
      await File('${repo.path}/library/note.md').writeAsString('v2');
      await s.autoCommit('promptlib: v2');
      await s.flush();

      final List<CommitInfo> all = await s.log();
      expect(all.map((CommitInfo c) => c.message),
          ['promptlib(library): v2', 'promptlib(library): v1']);
      final List<CommitInfo> scoped =
          await s.log(path: 'library/note.md', limit: 10);
      expect(scoped, hasLength(2));

      await s.revertFile(path: 'library/note.md', rev: rev1);
      expect(
          await File('${repo.path}/library/note.md').readAsString(), 'v1');
    });
  });
}
