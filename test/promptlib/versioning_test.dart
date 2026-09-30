/// Repomap tests: version/supersedes evolution (in-place vs snapshot,
// latest-per-id) with legacy `library/` files untouched.
import 'dart:io';

import 'package:test/test.dart';
import 'package:ice_cream_rss_reader/promptlib/front_matter.dart' as fm;
import 'package:ice_cream_rss_reader/promptlib/prompt_doc.dart';
import 'package:ice_cream_rss_reader/promptlib/prompt_store.dart';
import 'package:ice_cream_rss_reader/promptlib/repo_mapping.dart';

Future<Directory> _tempRoot() =>
    Directory.systemTemp.createTemp('promptlib_version_test_');

Future<PromptStore> _store(Directory root) async {
  final PromptStore store = PromptStore();
  await store.init(libraryRoot: root.path);
  return store;
}

void main() {
  late Directory root;
  late PromptStore store;

  setUp(() async {
    root = await _tempRoot();
    store = await _store(root);
  });

  tearDown(() async {
    await store.dispose();
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  group('front matter version/supersedes', () {
    test('legacy file without version parses as version 1', () {
      final PromptDoc doc =
          fm.parse('---\nid: abc\ntitle: Old\n---\nbody');
      expect(doc.version, 1);
      expect(doc.supersedes, isNull);
    });

    test('version + supersedes round-trip exactly', () {
      const PromptDoc doc = PromptDoc(
        id: 'v1',
        title: 'T',
        body: 'b',
        version: 3,
        supersedes: 'prompts/coding/t.v2.md',
      );
      final PromptDoc back = fm.parse(fm.serialize(doc));
      expect(back.version, 3);
      expect(back.supersedes, 'prompts/coding/t.v2.md');
    });

    test('supersedes absent unless set', () {
      const PromptDoc doc = PromptDoc(id: 'x', title: 'T', body: 'b');
      expect(fm.serialize(doc).contains('supersedes'), isFalse);
    });

    test('unknown keys are ignored', () {
      final PromptDoc doc = fm.parse(
          '---\nid: a\ntitle: t\nfuture_key: something\n---\nbody');
      expect(doc.id, 'a');
      expect(doc.title, 't');
    });

    test('invalid version throws FormatException (store skips it)', () {
      expect(
        () => fm.parse('---\nid: a\ntitle: t\nversion: 0\n---\nbody'),
        throwsFormatException,
      );
      expect(
        () => fm.parse('---\nid: a\ntitle: t\nversion: nope\n---\nbody'),
        throwsFormatException,
      );
    });

    test('missing id still generates a UUID + needsReview', () {
      final PromptDoc doc =
          fm.parse('---\ntitle: No id\nversion: 2\n---\nbody');
      expect(doc.id, isNotEmpty);
      expect(doc.needsReview, isTrue);
      expect(doc.version, 2);
    });
  });

  group('create (new UUID, never title-derived)', () {
    test('two prompts with the same title get different ids', () async {
      final PromptDoc a = await store.createPrompt(title: 'Same Title');
      final PromptDoc b = await store.createPrompt(title: 'Same Title');
      expect(a.id, isNotEmpty);
      expect(b.id, isNotEmpty);
      expect(a.id, isNot(equals(b.id)));
      expect(a.version, 1);
    });

    test('createPrompt in a category lands in prompts/<category>/',
        () async {
      final PromptDoc doc =
          await store.createPrompt(title: 'Cat Note', category: 'coding');
      final String dir =
          '${root.path}${Platform.pathSeparator}prompts'
          '${Platform.pathSeparator}coding';
      expect(
        Directory(dir).listSync().whereType<File>().length,
        1,
      );
      expect((await store.getById(doc.id))?.title, 'Cat Note');
    });
  });

  group('in-place edit (same file, version + 1)', () {
    test('second save reuses the path and bumps to version 2', () async {
      final PromptDoc first = await store.save(
        const PromptDoc(id: 'edit-1', title: 'Doc', body: 'v1 body'),
      );
      expect(first.version, 1);
      final PromptDoc second = await store.save(
        first.copyWith(body: 'v2 body'),
      );
      expect(second.version, 2);
      final List<File> files = Directory('${root.path}/library')
          .listSync()
          .whereType<File>()
          .toList();
      expect(files, hasLength(1));
      expect((await store.getById('edit-1'))?.body, 'v2 body');
      expect((await store.getById('edit-1'))?.version, 2);
    });

    test('saveToCategory edits in place within prompts/<category>/',
        () async {
      final PromptDoc first = await store.saveToCategory(
        const PromptDoc(id: 'cat-1', title: 'Note', body: 'one'),
        'coding',
      );
      final PromptDoc second = await store.saveToCategory(
        first.copyWith(body: 'two'),
        'coding',
      );
      expect(second.version, 2);
      final Directory dir = Directory(
          '${root.path}/prompts/coding'.replaceAll('/', Platform.pathSeparator));
      expect(dir.listSync().whereType<File>().length, 1);
      expect((await store.getById('cat-1'))?.body, 'two');
    });
  });

  group('optimize snapshot (new .v<N>.md, supersedes link)', () {
    test('snapshot keeps the old file and links supersedes', () async {
      final PromptDoc base = await store.saveToCategory(
        const PromptDoc(id: 'opt-1', title: 'Guide', body: 'draft'),
        'coding',
      );
      expect(base.version, 1);
      final PromptDoc snap = await store.saveOptimizedSnapshot(
        base.copyWith(body: 'polished'),
      );
      expect(snap.id, 'opt-1');
      expect(snap.version, 2);
      expect(snap.supersedes, isNotNull);

      final Directory dir = Directory(
          '${root.path}/prompts/coding'.replaceAll('/', Platform.pathSeparator));
      final List<String> names = dir
          .listSync()
          .whereType<File>()
          .map((File f) => f.path.split(Platform.pathSeparator).last)
          .toList();
      expect(names, hasLength(2));
      expect(names.any((String n) => n.endsWith('.v2.md')), isTrue,
          reason: 'snapshot must be <slug>.v<N>.md, got $names');
      // Old file untouched: still version 1 on disk.
      final PromptDoc? latest = await store.getById('opt-1');
      expect(latest?.body, 'polished');
      expect(latest?.version, 2);
    });

    test('second snapshot chains to .v3.md', () async {
      final PromptDoc base = await store.saveToCategory(
        const PromptDoc(id: 'opt-2', title: 'Doc', body: 'v1'),
        'coding',
      );
      final PromptDoc s2 =
          await store.saveOptimizedSnapshot(base.copyWith(body: 'v2'));
      final PromptDoc s3 =
          await store.saveOptimizedSnapshot(s2.copyWith(body: 'v3'));
      expect(s3.version, 3);
      final Directory dir = Directory(
          '${root.path}/prompts/coding'.replaceAll('/', Platform.pathSeparator));
      final List<String> names = dir
          .listSync()
          .whereType<File>()
          .map((File f) => f.path.split(Platform.pathSeparator).last)
          .toList();
      expect(names.any((String n) => n.endsWith('.v3.md')), isTrue);
      expect((await store.getById('opt-2'))?.body, 'v3');
    });
  });

  group('listLatestPerId', () {
    test('highest version wins, then newest updated', () async {
      await store.saveToCategory(
        const PromptDoc(id: 'a', title: 'A', body: 'a'),
        'coding',
      );
      final PromptDoc b1 = await store.saveToCategory(
        const PromptDoc(id: 'b', title: 'B', body: 'b1'),
        'coding',
      );
      await store.saveOptimizedSnapshot(b1.copyWith(body: 'b2'));
      await store.saveToCategory(
        const PromptDoc(id: 'c', title: 'C', body: 'c'),
        'writing',
      );

      final List<PromptDoc> latest = await store.listLatestPerId();
      final Map<String, PromptDoc> byId = {
        for (final PromptDoc d in latest) d.id: d
      };
      expect(byId['b']!.version, 2);
      expect(byId['b']!.body, 'b2');
      expect(byId['a']!.version, 1);

      final List<PromptDoc> coding =
          await store.listLatestPerId(category: 'coding');
      expect(coding.map((PromptDoc d) => d.id).toSet(), {'a', 'b'});
    });
  });

  group('legacy library/ untouched', () {
    test('hand-written legacy file reads as v1 and lists fine', () async {
      await File('${root.path}/library/legacy.md').writeAsString(
          '---\nid: legacy-1\ntitle: Legacy\ntags: [old]\n---\nold body');
      final PromptDoc? doc = await store.getById('legacy-1');
      expect(doc, isNotNull);
      expect(doc!.version, 1);
      expect(doc.supersedes, isNull);
      expect(doc.body, 'old body');
      expect(
          (await store.listLocal()).map((PromptDoc d) => d.id),
          contains('legacy-1'));
    });

    test('editing a legacy file bumps in the same path', () async {
      await File('${root.path}/library/legacy.md').writeAsString(
          '---\nid: legacy-2\ntitle: Legacy\n---\nold body');
      final PromptDoc? doc = await store.getById('legacy-2');
      final PromptDoc saved = await store.save(doc!.copyWith(body: 'new'));
      expect(saved.version, 2);
      expect(
        File('${root.path}/library/legacy.md').existsSync(),
        isTrue,
      );
    });
  });

  group('malformed files skipped + reported', () {
    test('bad version file is skipped, good files still list', () async {
      await File('${root.path}/library/broken.md').writeAsString(
          '---\nid: broken\ntitle: t\nversion: nope\n---\nbody');
      await store.save(
        const PromptDoc(id: 'good', title: 'Good', body: 'b'),
      );
      final List<PromptDoc> all = await store.listLocal();
      expect(all.map((PromptDoc d) => d.id), contains('good'));
      expect(all.map((PromptDoc d) => d.id), isNot(contains('broken')));
      expect(
          store.skippedFiles.any((String p) => p.endsWith('broken.md')),
          isTrue);
    });
  });

  group('registry wiring', () {
    test('bound category resolves through the registry', () async {
      final RepoRegistry reg = RepoRegistry(root: root.path);
      await reg.addRepo(RepoRecord(repoId: 'main', localPath: root.path));
      await reg.bind(categorySlug: 'coding', repoId: 'main');
      store.repoRegistry = reg;
      expect(store.resolveCategoryDir('coding'),
          RepoRegistry.defaultCategoryDir(root.path, 'coding'));
      final PromptDoc doc = await store.saveToCategory(
        const PromptDoc(id: 'w-1', title: 'Wired', body: 'b'),
        'coding',
      );
      expect(doc.version, 1);
    });
  });
}
