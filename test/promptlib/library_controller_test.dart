/// WP4 tests: LibraryController filter/search/save/getById + setFeedType.
///
/// Pure-Dart surface only (no widgets): filter/search/save/getById over a
/// temp store, plus feeds.yaml persistence round-trip via FeedConfig.parse.
import 'dart:io';

import 'package:test/test.dart';
import 'package:ice_cream_rss_reader/promptlib/feed_config.dart';
import 'package:ice_cream_rss_reader/promptlib/feed_engine.dart';
import 'package:ice_cream_rss_reader/promptlib/prompt_doc.dart';
import 'package:ice_cream_rss_reader/promptlib/prompt_store.dart';
import 'package:ice_cream_rss_reader/promptlib/ui/library_controller.dart';

Future<Directory> _tempRoot() =>
    Directory.systemTemp.createTemp('promptlib_ui_test_');

void main() {
  late Directory root;
  late PromptStore store;
  late LibraryController controller;

  setUp(() async {
    root = await _tempRoot();
    store = PromptStore();
    controller = LibraryController(store: store, libraryRoot: root.path);
    await controller.init();
  });

  tearDown(() async {
    await store.dispose();
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  group('save / getById', () {
    test('save round-trips and getById returns null for unknown ids',
        () async {
      const PromptDoc doc = PromptDoc(
        id: 'lib-1',
        title: 'Code Review',
        tags: ['coding'],
        body: 'review checklist',
      );
      final PromptDoc saved = await controller.save(doc);
      expect(saved.id, 'lib-1');
      expect((await controller.getById('lib-1'))?.title, 'Code Review');
      expect(await controller.getById('missing'), isNull);
    });
  });

  group('filter / search', () {
    setUp(() async {
      await controller.save(const PromptDoc(
        id: 'q1',
        title: 'Flutter tips',
        tags: ['code', 'mobile'],
        body: 'widget tree',
      ));
      await controller.save(const PromptDoc(
        id: 'q2',
        title: 'Shopping list',
        tags: ['life'],
        body: 'oats milk',
      ));
    });

    test('query matches title/body/tags case-insensitively', () async {
      expect((await controller.list(query: 'FLUTTER')).map((d) => d.id),
          ['q1']);
      expect(
          (await controller.list(query: 'oats')).map((d) => d.id), ['q2']);
      expect(await controller.list(query: 'nope'), isEmpty);
    });

    test('tags use AND semantics', () async {
      expect((await controller.list(tags: {'code'})).map((d) => d.id),
          ['q1']);
      expect(
        (await controller.list(tags: {'code', 'mobile'})).map((d) => d.id),
        ['q1'],
      );
      expect(
        await controller.list(tags: {'code', 'life'}),
        isEmpty,
      );
    });

    test('type filter: library items count as prompt', () async {
      expect((await controller.list(type: FeedType.prompt)).length, 2);
      expect(await controller.list(type: FeedType.article), isEmpty);
    });
  });

  group('setFeedType persists feeds.yaml', () {
    test('writes registry and reloads through FeedConfig.parse', () async {
      await controller.setFeedType(
        feedUrl: 'https://example.com/prompts.xml',
        type: FeedType.prompt,
        name: 'Example Prompts',
      );
      final File yaml = File('${root.path}/${FeedConfig.relativePath}');
      expect(await yaml.exists(), isTrue);
      final FeedConfig reloaded =
          FeedConfig.parse(await yaml.readAsString());
      expect(reloaded.feeds, hasLength(1));
      expect(reloaded.feeds.single.url, 'https://example.com/prompts.xml');
      expect(reloaded.feeds.single.type, FeedType.prompt);

      // Type change updates the entry instead of appending.
      await controller.setFeedType(
        feedUrl: 'https://example.com/prompts.xml',
        type: FeedType.article,
      );
      expect(controller.feeds, hasLength(1));
      expect(controller.feeds.single.type, FeedType.article);
      expect(controller.feeds.single.name, 'Example Prompts',
          reason: 'name preserved when not given');
      final FeedConfig reloaded2 =
          FeedConfig.parse(await yaml.readAsString());
      expect(reloaded2.feeds.single.type, FeedType.article);
    });

    test('delegates to the engine registry when attached', () async {
      final PromptStore store2 = PromptStore();
      final LibraryController withEngine = LibraryController(
        store: store2,
        libraryRoot: root.path,
        engine: FeedEngine(store: store2),
      );
      await withEngine.init();
      await withEngine.setFeedType(
        feedUrl: 'https://example.com/a.xml',
        type: FeedType.prompt,
      );
      expect(withEngine.feedConfig.entryForUrl('https://example.com/a.xml')
          ?.type, FeedType.prompt);
      final FeedConfig reloaded = FeedConfig.parse(
        await File('${root.path}/${FeedConfig.relativePath}')
            .readAsString(),
      );
      expect(
        reloaded.entryForUrl('https://example.com/a.xml')?.type,
        FeedType.prompt,
      );
      await store2.dispose();
    });
  });
}
