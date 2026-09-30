/// WP1 tests: PromptStore over folders (library/ + subscriptions/).
import 'dart:io';

import 'package:test/test.dart';
import 'package:ice_cream_rss_reader/promptlib/front_matter.dart'
    as fm;
import 'package:ice_cream_rss_reader/promptlib/prompt_doc.dart';
import 'package:ice_cream_rss_reader/promptlib/prompt_store.dart';

Future<Directory> _tempRoot() =>
    Directory.systemTemp.createTemp('promptlib_store_test_');

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

  group('empty folder', () {
    test('lists empty and getById returns null', () async {
      expect(await store.listLocal(), isEmpty);
      expect(await store.getById('nope'), isNull);
      expect(store.duplicateIds, isEmpty);
      expect(store.skippedFiles, isEmpty);
    });
  });

  group('save / get round-trip', () {
    test('save writes library/<slug>.md and getById reads it back',
        () async {
      const PromptDoc doc = PromptDoc(
        id: 'id-1',
        title: 'My First Prompt',
        tags: ['a'],
        body: 'hello',
      );
      final PromptDoc saved = await store.save(doc);
      expect(saved.id, 'id-1');
      expect(saved.updated, isNotNull);
      expect(
        File('${root.path}/library/my-first-prompt.md').existsSync(),
        isTrue,
      );
      final PromptDoc? back = await store.getById('id-1');
      expect(back?.title, 'My First Prompt');
      expect(back?.body, 'hello');
    });

    test('rename keeps the same file path (history-stable)', () async {
      await store.save(
        const PromptDoc(id: 'id-r', title: 'Old Title', body: 'b'),
      );
      await store.save(
        const PromptDoc(id: 'id-r', title: 'New Title', body: 'b2'),
      );
      expect(
        File('${root.path}/library/old-title.md').existsSync(),
        isTrue,
        reason: 'rename must reuse the existing path',
      );
      expect((await store.getById('id-r'))?.title, 'New Title');
    });

    test('query and tags filters', () async {
      await store.save(const PromptDoc(
          id: 'q1', title: 'Flutter tips', tags: ['code'], body: 'x'));
      await store.save(const PromptDoc(
          id: 'q2', title: 'Shopping list', tags: ['life'], body: 'y'));
      expect((await store.listLocal(query: 'flutter')).length, 1);
      expect(
          (await store.listLocal(tags: {'code'})).first.id, 'q1');
      expect(await store.listLocal(tags: {'missing'}), isEmpty);
    });
  });

  group('weird filenames are safe', () {
    test('unicode/space filenames scan without crashing', () async {
      final File weird = File(
        '${root.path}/library/ünïcode spaced ✨ name.md',
      );
      await weird.writeAsString(fm.serialize(const PromptDoc(
        id: 'weird-1',
        title: 'Weird name',
        body: 'b',
      )));
      final List<PromptDoc> all = await store.listLocal();
      expect(all.map((PromptDoc d) => d.id), contains('weird-1'));
      expect(store.skippedFiles, isEmpty);
    });

    test('hostile titles slugify to safe filenames', () async {
      await store.save(const PromptDoc(
        id: 'evil',
        title: '../../etc/passwd \x00',
        body: 'b',
      ));
      final List<FileSystemEntity> files =
          Directory('${root.path}/library').listSync();
      expect(files, hasLength(1));
      final String name = files.single.path.split('/').last;
      expect(name.contains('/'), isFalse);
      expect(name.startsWith('.'), isFalse);
      expect(await store.getById('evil'), isNotNull);
    });
  });

  group('malformed files never crash scans', () {
    test('garbage .md is skipped and reported', () async {
      await File('${root.path}/library/broken.md')
          .writeAsString('---\nthis is not: : valid\n---\nbody');
      await File('${root.path}/library/good.md').writeAsString(
          fm.serialize(
              const PromptDoc(id: 'good', title: 'Good', body: 'b')));
      final List<PromptDoc> all = await store.listLocal();
      expect(all.map((PromptDoc d) => d.id), ['good']);
      expect(store.skippedFiles.length, 1);
      expect(store.skippedFiles.single.endsWith('broken.md'), isTrue);
    });
  });

  group('duplicate ids', () {
    test('ambiguous on-disk duplicate rejects save', () async {
      await store.save(
        const PromptDoc(id: 'dup', title: 'First', body: 'b'),
      );
      // Simulate a user copying the file: same id, different filename.
      // The store can no longer tell which file owns the id, so the
      // next save of that id is rejected instead of guessing.
      await File('${root.path}/library/copy.md').writeAsString(
          fm.serialize(
              const PromptDoc(id: 'dup', title: 'Copy', body: 'c')));
      expect(
        () => store.save(
          const PromptDoc(id: 'dup', title: 'Third', body: 't'),
        ),
        throwsA(isA<DuplicateIdException>()),
      );
    });

    test('hand-copied duplicate files are namespaced, library wins',
        () async {
      await store.save(
        const PromptDoc(id: 'dup2', title: 'Library One', body: 'lib'),
      );
      // Simulate a user copying the file: same id, different filename.
      await File('${root.path}/library/copy.md').writeAsString(
          fm.serialize(const PromptDoc(
              id: 'dup2', title: 'Library Copy', body: 'copy')));
      final PromptDoc? got = await store.getById('dup2');
      expect(got, isNotNull);
      expect(store.duplicateIds['dup2'], isNotEmpty);
    });
  });

  group('subscriptions + fork-on-edit', () {
    test('materialize never touches library; fork links source_feed',
        () async {
      final PromptDoc sub = await store.materializeSubscribedItem(
        feedSlug: 'example-feed',
        id: 'sub-1',
        title: 'Subscribed Prompt',
        body: 'fetched body',
        tags: const ['feed'],
      );
      expect(sub.sourceFeed, 'example-feed');
      expect(
        File('${root.path}/library/subscribed-prompt.md').existsSync(),
        isFalse,
        reason: 'materialize must never write into library/',
      );
      // Read resolves to the subscription copy before forking.
      expect((await store.getById('sub-1'))?.body, 'fetched body');

      final PromptDoc forked = await store.forkToLibrary('sub-1');
      expect(forked.sourceFeed, 'example-feed');
      expect(
        File('${root.path}/library/subscribed-prompt.md').existsSync(),
        isTrue,
      );
      // Subscription mirror untouched by the fork.
      expect(
        File('${root.path}/subscriptions/example-feed/subscribed-prompt.md')
            .existsSync(),
        isTrue,
      );
      // Library copy wins on read.
      await store.save(forked.copyWith(body: 'edited locally'));
      expect((await store.getById('sub-1'))?.body, 'edited locally');
    });

    test('fork is idempotent when already in library', () async {
      await store.materializeSubscribedItem(
        feedSlug: 'f',
        id: 'sub-2',
        title: 'Twice',
        body: 'b',
      );
      final PromptDoc first = await store.forkToLibrary('sub-2');
      final PromptDoc second = await store.forkToLibrary('sub-2');
      expect(second.id, first.id);
      expect(
        Directory('${root.path}/library')
            .listSync()
            .whereType<File>()
            .length,
        1,
      );
    });
  });
}
