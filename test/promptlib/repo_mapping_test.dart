/// Repomap tests: RepoBinding/RepoRecord registry, single<->multi migration.
import 'dart:io';

import 'package:test/test.dart';
import 'package:ice_cream_rss_reader/promptlib/repo_mapping.dart';

Future<Directory> _tempRoot() =>
    Directory.systemTemp.createTemp('promptlib_repomap_test_');

/// A registry with two repos rooted at [root]: `shared` and `team`.
RepoRegistry _twoRepos(String root) {
  final RepoRegistry reg = RepoRegistry(root: root);
  return reg;
}

Future<RepoRegistry> _seeded(String root) async {
  final RepoRegistry reg = RepoRegistry(root: root);
  await reg.addRepo(RepoRecord(
    repoId: 'shared',
    localPath: root, // the store root itself is the shared checkout
    remoteUrl: 'https://example.com/shared.git',
  ));
  await reg.addRepo(const RepoRecord(
    repoId: 'team',
    localPath: 'team-checkout', // relative to root
    remoteUrl: 'https://example.com/team.git',
  ));
  return reg;
}

Future<void> _write(String path, String content) async {
  await Directory(path.substring(0, path.lastIndexOf(Platform.pathSeparator)))
      .create(recursive: true);
  await File(path).writeAsString(content);
}

void main() {
  late Directory root;

  setUp(() async {
    root = await _tempRoot();
  });

  tearDown(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  group('bind / unbind', () {
    test('bind records repo, path, and sync default false', () async {
      final RepoRegistry reg = await _seeded(root.path);
      expect(reg.bindingFor('coding'), isNull);
      await reg.bind(categorySlug: 'coding', repoId: 'shared');
      final RepoBinding? b = reg.bindingFor('coding');
      expect(b, isNotNull);
      expect(b!.repoId, 'shared');
      expect(b.pathInRepo, 'prompts/coding');
      expect(b.syncEnabled, isFalse);
    });

    test('bind with explicit path + syncEnabled true', () async {
      final RepoRegistry reg = await _seeded(root.path);
      await reg.bind(
        categorySlug: 'Coding', // normalized to lowercase
        repoId: 'team',
        pathInRepo: 'custom/dir',
        syncEnabled: true,
      );
      final RepoBinding? b = reg.bindingFor('coding');
      expect(b!.repoId, 'team');
      expect(b.pathInRepo, 'custom/dir');
      expect(b.syncEnabled, isTrue);
    });

    test('unbind removes the binding but leaves files alone', () async {
      final RepoRegistry reg = await _seeded(root.path);
      await reg.bind(categorySlug: 'coding', repoId: 'shared');
      final String dir = reg.resolveCategoryDir('coding');
      await _write('$dir${Platform.pathSeparator}note.md', '# hi\n');
      await reg.unbind('coding');
      expect(reg.bindingFor('coding'), isNull);
      expect(File('$dir${Platform.pathSeparator}note.md').existsSync(),
          isTrue,
          reason: 'unbind must never delete user files');
    });

    test('bind to unknown repo throws StateError', () async {
      final RepoRegistry reg = await _seeded(root.path);
      expect(
        () => reg.bind(categorySlug: 'coding', repoId: 'nope'),
        throwsStateError,
      );
    });

    test('empty slug throws ArgumentError', () async {
      final RepoRegistry reg = await _seeded(root.path);
      expect(
        () => reg.bind(categorySlug: '  ', repoId: 'shared'),
        throwsArgumentError,
      );
      expect(() => reg.resolveCategoryDir('../escape'), throwsArgumentError);
    });

    test('unbind of unknown slug is a no-op', () async {
      final RepoRegistry reg = await _seeded(root.path);
      await reg.unbind('ghost'); // must not throw
      expect(reg.allBindings, isEmpty);
    });
  });

  group('single shared repo vs own repo per category', () {
    test('two categories can share one repo', () async {
      final RepoRegistry reg = await _seeded(root.path);
      await reg.bind(categorySlug: 'coding', repoId: 'shared');
      await reg.bind(categorySlug: 'writing', repoId: 'shared');
      expect(reg.bindingFor('coding')!.repoId, 'shared');
      expect(reg.bindingFor('writing')!.repoId, 'shared');
      expect(reg.resolveCategoryDir('coding'),
          '${root.path}/prompts/coding'.replaceAll('/', Platform.pathSeparator));
    });

    test('each category can own its repo', () async {
      final RepoRegistry reg = await _seeded(root.path);
      await reg.bind(categorySlug: 'coding', repoId: 'shared');
      await reg.bind(categorySlug: 'writing', repoId: 'team');
      expect(reg.bindingFor('coding')!.repoId, 'shared');
      expect(reg.bindingFor('writing')!.repoId, 'team');
      final String teamDir = reg.resolveCategoryDir('writing');
      expect(teamDir.contains('team-checkout'), isTrue);
    });

    test('allRepos lists every repo', () async {
      final RepoRegistry reg = await _seeded(root.path);
      expect(reg.allRepos.map((RepoRecord r) => r.repoId),
          containsAll(['shared', 'team']));
      expect(reg.repo('shared')!.remoteUrl, contains('shared.git'));
      expect(reg.repo('ghost'), isNull);
      expect(_twoRepos(root.path).allRepos, isEmpty);
    });

    test('dangling binding falls back to the default dir, never crashes',
        () async {
      final RepoRegistry reg = await _seeded(root.path);
      await reg.bind(categorySlug: 'coding', repoId: 'team');
      await reg.removeRepo('team');
      expect(
        reg.resolveCategoryDir('coding'),
        RepoRegistry.defaultCategoryDir(root.path, 'coding'),
      );
    });
  });

  group('migrateCategory (single <-> multi)', () {
    test('moves files and re-points the binding (shared -> own)',
        () async {
      final RepoRegistry reg = await _seeded(root.path);
      await reg.bind(categorySlug: 'coding', repoId: 'shared');
      final String src = reg.resolveCategoryDir('coding');
      await _write('$src${Platform.pathSeparator}a.md', '# a\n');
      await _write('$src${Platform.pathSeparator}b.md', '# b\n');

      final List<String> moved = await reg.migrateCategory(
        categorySlug: 'coding',
        targetRepoId: 'team',
      );
      expect(moved, hasLength(2));
      expect(reg.bindingFor('coding')!.repoId, 'team');
      final String dest = reg.resolveCategoryDir('coding');
      expect(File('$dest${Platform.pathSeparator}a.md').existsSync(),
          isTrue);
      expect(File('$dest${Platform.pathSeparator}b.md').existsSync(),
          isTrue);
      expect(Directory(src).listSync().whereType<File>(), isEmpty,
          reason: 'source files must move, not copy');
    });

    test('migrates back (own -> shared)', () async {
      final RepoRegistry reg = await _seeded(root.path);
      await reg.bind(categorySlug: 'coding', repoId: 'team');
      final String src = reg.resolveCategoryDir('coding');
      await _write('$src${Platform.pathSeparator}a.md', '# a\n');

      await reg.migrateCategory(
        categorySlug: 'coding',
        targetRepoId: 'shared',
      );
      expect(reg.bindingFor('coding')!.repoId, 'shared');
      final String dest = reg.resolveCategoryDir('coding');
      expect(File('$dest${Platform.pathSeparator}a.md').existsSync(),
          isTrue);
    });

    test('missing source dir still updates the binding', () async {
      final RepoRegistry reg = await _seeded(root.path);
      await reg.bind(categorySlug: 'coding', repoId: 'shared');
      final List<String> moved = await reg.migrateCategory(
        categorySlug: 'coding',
        targetRepoId: 'team',
      );
      expect(moved, isEmpty);
      expect(reg.bindingFor('coding')!.repoId, 'team');
    });

    test('unknown target repo throws StateError', () async {
      final RepoRegistry reg = await _seeded(root.path);
      await reg.bind(categorySlug: 'coding', repoId: 'shared');
      expect(
        () => reg.migrateCategory(
            categorySlug: 'coding', targetRepoId: 'ghost'),
        throwsStateError,
      );
      // Failed migration must not clobber the old binding.
      expect(reg.bindingFor('coding')!.repoId, 'shared');
    });

    test('only Markdown moves; other files stay', () async {
      final RepoRegistry reg = await _seeded(root.path);
      await reg.bind(categorySlug: 'coding', repoId: 'shared');
      final String src = reg.resolveCategoryDir('coding');
      await _write('$src${Platform.pathSeparator}a.md', '# a\n');
      await _write('$src${Platform.pathSeparator}notes.txt', 'plain\n');
      await reg.migrateCategory(
          categorySlug: 'coding', targetRepoId: 'team');
      final String dest = reg.resolveCategoryDir('coding');
      expect(File('$dest${Platform.pathSeparator}a.md').existsSync(),
          isTrue);
      expect(File('$src${Platform.pathSeparator}notes.txt').existsSync(),
          isTrue,
          reason: 'non-Markdown must never move');
    });
  });

  group('YAML mirrors', () {
    test('persist writes repos.yaml + bindings.yaml; load reads them back',
        () async {
      final RepoRegistry reg = await _seeded(root.path);
      await reg.bind(
          categorySlug: 'coding', repoId: 'shared', syncEnabled: true);
      expect(
          File(RepoRegistry.reposPath(root.path)).existsSync(), isTrue);
      expect(
          File(RepoRegistry.bindingsPath(root.path)).existsSync(), isTrue);

      final RepoRegistry back = await RepoRegistry.load(root.path);
      expect(back.allRepos, hasLength(2));
      expect(back.bindingFor('coding')!.repoId, 'shared');
      expect(back.bindingFor('coding')!.syncEnabled, isTrue);
    });

    test('load with no files yields an empty registry', () async {
      final RepoRegistry reg = await RepoRegistry.load(root.path);
      expect(reg.allRepos, isEmpty);
      expect(reg.allBindings, isEmpty);
    });

    test('toJson/fromJson round-trips (Hive-style)', () async {
      final RepoRegistry reg = await _seeded(root.path);
      await reg.bind(categorySlug: 'coding', repoId: 'team');
      final RepoRegistry back =
          RepoRegistry.fromJson(reg.toJson(), root: root.path);
      expect(back.allRepos, hasLength(2));
      expect(back.bindingFor('coding')!.repoId, 'team');
    });
  });

  group('category.yaml', () {
    test('ensureCategory upserts; readCategories returns the map',
        () async {
      final RepoRegistry reg = RepoRegistry(root: root.path);
      expect(await reg.readCategories(), isEmpty);
      await reg.ensureCategory('coding', displayName: 'Coding');
      await reg.ensureCategory('writing');
      final Map<String, String> cats = await reg.readCategories();
      expect(cats['coding'], 'Coding');
      expect(cats['writing'], 'writing');
      expect(
          File(RepoRegistry.categoryMetaPath(root.path)).existsSync(),
          isTrue);
    });
  });

  group('importLegacyLibrary / first-bind auto-import', () {
    Future<void> _writeLegacy(String name, String content) =>
        _write('$root${Platform.pathSeparator}library'
            '${Platform.pathSeparator}$name', content);

    test('first bind auto-imports legacy files into the category dir',
        () async {
      await _writeLegacy('a.md', '# a\n');
      await _writeLegacy('b.md', '# b\n');
      final RepoRegistry reg = await _seeded(root.path);
      await reg.bind(categorySlug: 'coding', repoId: 'shared');
      expect(reg.bindingFor('coding')!.repoId, 'shared');
      final String dest = reg.resolveCategoryDir('coding');
      expect(File('$dest${Platform.pathSeparator}a.md').readAsStringSync(),
          '# a\n');
      expect(File('$dest${Platform.pathSeparator}b.md').readAsStringSync(),
          '# b\n');
      expect(
          Directory('$root${Platform.pathSeparator}library')
              .listSync()
              .whereType<File>(),
          isEmpty,
          reason: 'auto-import must move, not copy');
    });

    test('second bind does NOT auto-move; explicit importLegacy does',
        () async {
      final RepoRegistry reg = await _seeded(root.path);
      await reg.bind(categorySlug: 'coding', repoId: 'shared');
      await _writeLegacy('later.md', '# later\n');
      await reg.bind(categorySlug: 'writing', repoId: 'shared');
      expect(File('$root${Platform.pathSeparator}library'
          '${Platform.pathSeparator}later.md').existsSync(), isTrue,
          reason: 'second bind must not sweep library/');
      await reg.bind(
          categorySlug: 'writing', repoId: 'shared', importLegacy: true);
      final String dest = reg.resolveCategoryDir('writing');
      expect(File('$dest${Platform.pathSeparator}later.md').readAsStringSync(),
          '# later\n');
    });

    test('name clash gains a numeric suffix, never overwrites', () async {
      final RepoRegistry reg = await _seeded(root.path);
      await reg.bind(categorySlug: 'coding', repoId: 'shared');
      final String dest = reg.resolveCategoryDir('coding');
      await _write('$dest${Platform.pathSeparator}note.md', '# original\n');
      await _writeLegacy('note.md', '# legacy\n');
      final List<String> moved = await reg.importLegacyLibrary(
          categorySlug: 'coding');
      expect(moved, hasLength(1));
      expect(moved.single.endsWith('note-2.md'), isTrue);
      expect(File('$dest${Platform.pathSeparator}note.md').readAsStringSync(),
          '# original\n');
      expect(File(moved.single).readAsStringSync(), '# legacy\n');
    });

    test('empty source is a no-op returning []', () async {
      final RepoRegistry reg = await _seeded(root.path);
      expect(await reg.importLegacyLibrary(categorySlug: 'coding'),
          isEmpty);
    });

    test('empty slug throws ArgumentError', () async {
      final RepoRegistry reg = await _seeded(root.path);
      expect(() => reg.importLegacyLibrary(categorySlug: '  '),
          throwsArgumentError);
    });

    test('memory-only registry bind does not crash (import skipped)',
        () async {
      final RepoRegistry reg = RepoRegistry();
      await reg.addRepo(
          const RepoRecord(repoId: 'local', localPath: '/tmp/nowhere'));
      await reg.bind(categorySlug: 'coding', repoId: 'local');
      expect(reg.bindingFor('coding')!.repoId, 'local');
    });
  });
}
