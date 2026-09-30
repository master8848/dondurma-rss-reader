/// WP5 tests: real two-clone conflicts resolve with no data loss.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ice_cream_rss_reader/promptlib/conflict_resolve.dart';
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

class _Clones {
  final Directory bare;
  final Directory a;
  final Directory b;
  final String baseHead; // HEAD both clones agreed on before diverging

  const _Clones({
    required this.bare,
    required this.a,
    required this.b,
    required this.baseHead,
  });
}

void main() {
  final List<Directory> dirs = <Directory>[];
  final List<ProcessGitService> services = <ProcessGitService>[];

  Future<Directory> mkTemp(String prefix) async {
    final Directory d =
        await Directory.systemTemp.createTemp(prefix);
    dirs.add(d);
    return d;
  }

  ProcessGitService svc(String workdir) {
    final ProcessGitService s = ProcessGitService(
      workingDirectory: workdir,
      debounce: const Duration(minutes: 1),
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

  Future<void> _configUser(String workdir) async {
    await _git(['config', 'user.email', 'test@promptlib.dev'], workdir);
    await _git(['config', 'user.name', 'PromptLib Test'], workdir);
    await _git(['config', 'commit.gpgsign', 'false'], workdir);
  }

  /// Bare remote + two clones that both start from the same pushed base.
  Future<_Clones> _twoClones() async {
    final Directory bare = await mkTemp('promptlib_cf_bare_');
    await _git(['init', '--bare', '-b', 'main'], bare.path);

    final Directory seed = await mkTemp('promptlib_cf_seed_');
    await _git(
        ['clone', bare.path, seed.path], Directory.systemTemp.path);
    await _configUser(seed.path);
    await Directory('${seed.path}/library').create(recursive: true);
    await File('${seed.path}/library/note.md')
        .writeAsString('base line\n');
    await _git(['add', '--', 'library'], seed.path);
    await _git(['commit', '-m', 'promptlib(library): base'], seed.path);
    await _git(['push', '-u', 'origin', 'main'], seed.path);
    final String base =
        '${(await _git(['rev-parse', 'HEAD'], seed.path)).stdout}'.trim();

    Future<Directory> clone(String prefix) async {
      final Directory c = await mkTemp(prefix);
      await _git(['clone', bare.path, c.path], Directory.systemTemp.path);
      await _configUser(c.path);
      return c;
    }

    return _Clones(
      bare: bare,
      a: await clone('promptlib_cf_A_'),
      b: await clone('promptlib_cf_B_'),
      baseHead: base,
    );
  }

  /// Diverges both clones on `library/note.md` and leaves clone B with a
  /// real unmerged conflict after fetch+merge. Returns [aHead, bHead].
  Future<List<String>> _diverge(_Clones c) async {
    // Both clones start from the pushed base.
    for (final Directory d in <Directory>[c.a, c.b]) {
      expect(
        '${(await _git(['rev-parse', 'HEAD'], d.path)).stdout}'.trim(),
        c.baseHead,
      );
    }
    await File('${c.a.path}/library/note.md')
        .writeAsString('base line\nline from A\n');
    await _git(['add', '--', 'library/note.md'], c.a.path);
    await _git(['commit', '-m', 'promptlib(library): A edit'], c.a.path);
    await _git(['push'], c.a.path);
    final String aHead =
        '${(await _git(['rev-parse', 'HEAD'], c.a.path)).stdout}'.trim();

    await File('${c.b.path}/library/note.md')
        .writeAsString('base line\nline from B\n');
    await _git(['add', '--', 'library/note.md'], c.b.path);
    await _git(['commit', '-m', 'promptlib(library): B edit'], c.b.path);
    final String bHead =
        '${(await _git(['rev-parse', 'HEAD'], c.b.path)).stdout}'.trim();

    // B's push is rejected (non-fast-forward), --ff-only pull refuses.
    final ProcessGitService svcB = svc(c.b.path);
    await svcB.push().then<void>(
      (_) => fail('diverged push should fail'),
      onError: (Object e) => expect(e, isA<GitException>()),
    );
    await svcB.pull().then<void>(
      (_) => fail('diverged pull --ff-only should fail'),
      onError: (Object e) => expect(e, isA<GitException>()),
    );

    // Manual fetch + merge produces the real conflict.
    await _git(['fetch', 'origin'], c.b.path);
    final ProcessResult merge = await _git(
        ['merge', 'origin/main'], c.b.path,
        expectOk: false);
    expect(merge.exitCode, isNot(0),
        reason: 'fetch+merge should conflict: ${merge.stdout}${merge.stderr}');
    expect(await svcB.conflictedFiles(), ['library/note.md']);
    return <String>[aHead, bHead];
  }

  Future<String> _blob(String workdir, String rev, String path) async =>
      '${(await _git(['show', '$rev:$path'], workdir)).stdout}';

  group('pure helpers', () {
    test('hasConflictMarkers detects leftover markers', () {
      expect(hasConflictMarkers('clean\ntext\n'), isFalse);
      expect(
        hasConflictMarkers('a\n<<<<<<< HEAD\nb\n=======\nc\n>>>>>>> x\n'),
        isTrue,
      );
    });

    test('preserveBothCopies never overwrites existing files', () async {
      final Directory tmp = await mkTemp('promptlib_cf_pure_');
      final String target = '${tmp.path}/note.md';
      await File(target).writeAsString('worktree');
      final List<String> first = await preserveBothCopies(
        filePath: target,
        mineContent: 'mine',
        theirsContent: 'theirs',
      );
      expect(await File(first[0]).readAsString(), 'mine');
      expect(await File(first[1]).readAsString(), 'theirs');
      // Second call with the same target must not clobber the first.
      final List<String> second = await preserveBothCopies(
        filePath: target,
        mineContent: 'mine2',
        theirsContent: 'theirs2',
      );
      expect(second[0], isNot(first[0]));
      expect(await File(first[0]).readAsString(), 'mine');
      expect(await File(second[0]).readAsString(), 'mine2');
    });
  });

  group('two-clone conflicts', () {
    test('keep-mine wins with no data loss (loser stays in history)',
        () async {
      final _Clones c = await _twoClones();
      final List<String> heads = await _diverge(c);
      final String aHead = heads[0];

      final ProcessGitService svcB = svc(c.b.path);
      await svcB.resolveConflict(
        path: 'library/note.md',
        choice: ConflictChoice.mine,
      );
      expect(await File('${c.b.path}/library/note.md').readAsString(),
          'base line\nline from B\n');
      expect(await svcB.conflictedFiles(), isEmpty);

      await _git(
          ['commit', '-m', 'promptlib(library): resolve keep-mine'],
          c.b.path);
      await svcB.push();

      // A's side is not lost: still reachable in history.
      expect(await _blob(c.b.path, aHead, 'library/note.md'),
          contains('line from A'));
      // A fast-forwards to the resolution.
      await svc(c.a.path).pull();
      expect(await File('${c.a.path}/library/note.md').readAsString(),
          'base line\nline from B\n');
    });

    test('keep-theirs wins with no data loss', () async {
      final _Clones c = await _twoClones();
      final List<String> heads = await _diverge(c);
      final String bHead = heads[1];

      final ProcessGitService svcB = svc(c.b.path);
      await svcB.resolveConflict(
        path: 'library/note.md',
        choice: ConflictChoice.theirs,
      );
      expect(await File('${c.b.path}/library/note.md').readAsString(),
          'base line\nline from A\n');
      expect(await svcB.conflictedFiles(), isEmpty);

      await _git(
          ['commit', '-m', 'promptlib(library): resolve keep-theirs'],
          c.b.path);
      await svcB.push();

      // B's side is not lost: still reachable in history.
      expect(await _blob(c.b.path, bHead, 'library/note.md'),
          contains('line from B'));
    });

    test('manual merge preserves both copies to .bak files', () async {
      final _Clones c = await _twoClones();
      await _diverge(c);

      final ProcessGitService svcB = svc(c.b.path);
      const String merged = 'base line\nline from A\nline from B\n';
      await svcB.resolveConflict(
        path: 'library/note.md',
        choice: ConflictChoice.manual,
        manualContent: merged,
      );
      expect(await File('${c.b.path}/library/note.md').readAsString(),
          merged);
      final String mineBak =
          '${c.b.path}/library/note.md.conflict-mine.bak';
      final String theirsBak =
          '${c.b.path}/library/note.md.conflict-theirs.bak';
      expect(await File(mineBak).readAsString(), contains('line from B'));
      expect(await File(theirsBak).readAsString(), contains('line from A'));
      expect(await svcB.conflictedFiles(), isEmpty);

      await _git(
          ['commit', '-m', 'promptlib(library): resolve manual'],
          c.b.path);
      await svcB.push();

      // Remote peer receives the merged content.
      await svc(c.a.path).pull();
      expect(await File('${c.a.path}/library/note.md').readAsString(),
          merged);
    });

    test('manual content with markers is rejected, copies kept', () async {
      final _Clones c = await _twoClones();
      await _diverge(c);
      final ProcessGitService svcB = svc(c.b.path);
      await svcB.resolveConflict(
        path: 'library/note.md',
        choice: ConflictChoice.manual,
        manualContent: 'a\n<<<<<<< HEAD\nb\n=======\nc\n>>>>>>> x\n',
      ).then<void>(
        (_) => fail('marker-filled manual content should be rejected'),
        onError: (Object e) => expect(e, isA<GitException>()),
      );
      // Both copies were still preserved before the rejection.
      expect(
        File('${c.b.path}/library/note.md.conflict-mine.bak').existsSync(),
        isTrue,
      );
      expect(
        File('${c.b.path}/library/note.md.conflict-theirs.bak').existsSync(),
        isTrue,
      );
    });
  });

  group('resolution guards', () {
    test('non-conflicted path throws GitException', () async {
      final _Clones c = await _twoClones();
      final ProcessGitService svcB = svc(c.b.path);
      expect(await svcB.conflictedFiles(), isEmpty);
      expect(
        () => svcB.resolveConflict(
          path: 'library/note.md',
          choice: ConflictChoice.mine,
        ),
        throwsA(isA<GitException>()),
      );
    });

    test('manual without content throws ArgumentError', () async {
      final _Clones c = await _twoClones();
      await _diverge(c);
      final ProcessGitService svcB = svc(c.b.path);
      expect(
        () => svcB.resolveConflict(
          path: 'library/note.md',
          choice: ConflictChoice.manual,
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => svcB.resolveConflict(
          path: 'library/note.md',
          choice: ConflictChoice.manual,
          manualContent: '',
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('unsafe paths are rejected', () async {
      final _Clones c = await _twoClones();
      final ProcessGitService svcB = svc(c.b.path);
      for (final String bad in <String>[
        '',
        '../evil.md',
        '/abs/path.md',
        '--weird',
        'a/../../evil.md'
      ]) {
        expect(
          () => svcB.resolveConflict(
              path: bad, choice: ConflictChoice.mine),
          throwsA(isA<ArgumentError>()),
          reason: 'path "$bad" must be rejected',
        );
      }
    });
  });
}
