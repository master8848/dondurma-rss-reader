/// Offline-marking tests: subscriptions-scope detection, edit-in-place
/// (same path, no fork/duplicate), and the marker visibility rule.
///
/// Pure-Dart (`package:test`, no Flutter). Store I/O goes to a temp dir.
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:ice_cream_rss_reader/promptlib/feed_config.dart';
import 'package:ice_cream_rss_reader/promptlib/feed_engine.dart';
import 'package:ice_cream_rss_reader/promptlib/offline_marking.dart';
import 'package:ice_cream_rss_reader/promptlib/prompt_doc.dart';
import 'package:ice_cream_rss_reader/promptlib/prompt_store.dart';
import 'package:ice_cream_rss_reader/promptlib/ui/library_controller.dart';

String _join(List<String> parts) => parts.join(Platform.pathSeparator);

Future<Directory> _tempRoot() =>
    Directory.systemTemp.createTemp('promptlib_offline_test_');

Future<int> _mdCount(Directory dir) async {
  if (!await dir.exists()) return 0;
  int n = 0;
  await for (final e in dir.list(recursive: true, followLinks: false)) {
    if (e is File && e.path.toLowerCase().endsWith('.md')) n++;
  }
  return n;
}

void main() {
  group('isOfflineFilePath (pure location rule)', () {
    test('subscriptions mirror paths are offline', () {
      const root = '/tmp/pl-root';
      expect(
        isOfflineFilePath(
          _join([root, 'subscriptions', 'my-feed', 'item.md']),
          root,
        ),
        isTrue,
      );
      // Nested folders still count (recursive scan finds them).
      expect(
        isOfflineFilePath(
          _join([root, 'subscriptions', 'a', 'b', 'item.md']),
          root,
        ),
        isTrue,
      );
    });

    test('library / prompts / outside paths are not offline', () {
      const root = '/tmp/pl-root';
      expect(
        isOfflineFilePath(_join([root, 'library', 'note.md']), root),
        isFalse,
      );
      expect(
        isOfflineFilePath(
          _join([root, 'prompts', 'coding', 'note.md']),
          root,
        ),
        isFalse,
      );
      expect(
        isOfflineFilePath(
          _join([root, 'subscriptions2', 'x.md']),
          root,
        ),
        isFalse,
        reason: 'sibling dir must not prefix-match',
      );
      expect(
        isOfflineFilePath(_join(['/other', 'subscriptions', 'x.md']), root),
        isFalse,
      );
    });

    test('null / blank / blank-root never throws and is not offline', () {
      expect(isOfflineFilePath(null, '/tmp/r'), isFalse);
      expect(isOfflineFilePath('   ', '/tmp/r'), isFalse);
      expect(
        isOfflineFilePath('/tmp/r/subscriptions/x.md', '  '),
        isFalse,
      );
    });
  });

  group('showOfflineMarker (visibility rule)', () {
    test('tiny inline icon ONLY when offline, nothing otherwise', () {
      expect(showOfflineMarker(isOffline: true), isTrue);
      expect(showOfflineMarker(isOffline: false), isFalse);
    });
  });

  group('PromptStore.isOffline (scope membership)', () {
    late Directory root;
    late PromptStore store;

    setUp(() async {
      root = await _tempRoot();
      store = PromptStore();
      await store.init(libraryRoot: root.path);
    });

    tearDown(() async {
      await store.dispose();
      if (await root.exists()) await root.delete(recursive: true);
    });

    test('materialized item is offline; library item is not', () async {
      await store.materializeSubscribedItem(
        feedSlug: 'my-feed',
        id: 'art-1',
        title: 'Saved Article',
        body: 'offline body',
      );
      await store.save(const PromptDoc(id: 'lib-1', title: 'My Prompt'));

      expect(await store.isOffline('art-1'), isTrue);
      expect(await store.isOffline('lib-1'), isFalse);
      expect(await store.isOffline('unknown-id'), isFalse);
    });

    test('forked-to-library id resolves to library (not offline)', () async {
      await store.materializeSubscribedItem(
        feedSlug: 'my-feed',
        id: 'art-2',
        title: 'Fork Me',
      );
      expect(await store.isOffline('art-2'), isTrue);
      await store.forkToLibrary('art-2');
      // Reads favour library/ once forked → location state flips with it.
      expect(await store.isOffline('art-2'), isFalse);
    });

    test('prompts/<category>/ items are not offline', () async {
      await store.saveToCategory(
        const PromptDoc(id: 'cat-1', title: 'Categorized'),
        'coding',
      );
      expect(await store.isOffline('cat-1'), isFalse);
    });

    test('fileStateFor agrees with pathForId + isOffline', () async {
      await store.materializeSubscribedItem(
        feedSlug: 'My Folder',
        id: 'art-3',
        title: 'Slug Folder',
      );
      final String? path = await store.pathForId('art-3');
      final bool offline = await store.isOffline('art-3');
      final state = await store.fileStateFor('art-3');
      expect(state.path, path);
      expect(state.isOffline, offline);
      // Resolver check: slugified folder dir under subscriptions/.
      expect(
        path,
        startsWith(
          '${_join([root.path, 'subscriptions', 'my-folder'])}${Platform.pathSeparator}',
        ),
      );
      expect(offline, isTrue);
    });
  });

  group('saveInPlace (edit same path, no fork, no duplicate)', () {
    late Directory root;
    late PromptStore store;

    setUp(() async {
      root = await _tempRoot();
      store = PromptStore();
      await store.init(libraryRoot: root.path);
    });

    tearDown(() async {
      await store.dispose();
      if (await root.exists()) await root.delete(recursive: true);
    });

    test('offline edit rewrites the SAME mirror file', () async {
      await store.materializeSubscribedItem(
        feedSlug: 'my-feed',
        id: 'art-9',
        title: 'Original',
        body: 'v1 body',
      );
      final String? before = await store.pathForId('art-9');
      expect(before, isNotNull);
      final Directory feedDir = Directory(
        _join([root.path, 'subscriptions', 'my-feed']),
      );
      expect(await _mdCount(feedDir), 1);

      final PromptDoc? current = await store.getById('art-9');
      final PromptDoc saved = await store.saveInPlace(
        current!.copyWith(title: 'Edited', body: 'v2 body'),
      );

      expect(await store.pathForId('art-9'), before);
      expect(await _mdCount(feedDir), 1, reason: 'no duplicate file');
      expect(
        await _mdCount(Directory(_join([root.path, 'library']))),
        0,
        reason: 'no fork into library/',
      );
      expect(saved.version, 2);
      expect((await store.getById('art-9'))?.body, 'v2 body');
      expect(await store.isOffline('art-9'), isTrue);
      expect(store.duplicateIds, isEmpty);
    });

    test('unknown id falls back to a new library/ file', () async {
      final PromptDoc saved = await store.saveInPlace(
        const PromptDoc(id: 'fresh-1', title: 'Fresh'),
      );
      final String? path = await store.pathForId('fresh-1');
      expect(path, startsWith('${_join([root.path, 'library'])}${Platform.pathSeparator}'));
      expect(saved.version, 1);
      expect(await store.isOffline('fresh-1'), isFalse);
    });
  });

  group('LibraryController offline surface', () {
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
      if (await root.exists()) await root.delete(recursive: true);
    });

    test('isOffline / fileStateFor / saveInPlace delegate to the store',
        () async {
      await store.materializeSubscribedItem(
        feedSlug: 'ctrl-feed',
        id: 'c-1',
        title: 'Ctrl Article',
        body: 'body',
      );
      expect(await controller.isOffline('c-1'), isTrue);
      final state = await controller.fileStateFor('c-1');
      expect(state.path, await controller.pathForId('c-1'));
      expect(state.isOffline, isTrue);

      final String? before = state.path;
      final PromptDoc? current = await controller.getById('c-1');
      await controller.saveInPlace(current!.copyWith(body: 'edited'));
      expect(await controller.pathForId('c-1'), before);
      expect((await controller.getById('c-1'))?.body, 'edited');
      expect(await controller.isOffline('c-1'), isTrue);
    });
  });

  group('feed-engine routed folder materializes as offline', () {
    late Directory root;
    late PromptStore store;

    setUp(() async {
      root = await _tempRoot();
      store = PromptStore();
      await store.init(libraryRoot: root.path);
    });

    tearDown(() async {
      await store.dispose();
      if (await root.exists()) await root.delete(recursive: true);
    });

    test('prompt-type feed refresh lands under subscriptions/ (offline)',
        () async {
      const String rss =
          '<?xml version="1.0"?><rss version="2.0"><channel>'
          '<title>T</title>'
          '<item><guid>eng-1</guid><title>Engine Item</title>'
          '<link>https://x.test/1</link>'
          '<description>hello</description></item>'
          '</channel></rss>';
      final FeedEngine engine = FeedEngine(
        store: store,
        config: const FeedConfig([
          FeedConfigEntry(
            url: 'https://x.test/feed',
            name: 'X Feed',
            type: FeedType.prompt,
          ),
        ]),
        transport: _FakeTransport(rss),
      );
      final RefreshResult result = await engine.refreshFeed(
        feedUrl: 'https://x.test/feed',
        name: 'X Feed',
      );
      expect(result.materialized, 1);
      expect(await store.isOffline('eng-1'), isTrue);
      expect(
        await store.pathForId('eng-1'),
        startsWith(
          '${_join([root.path, 'subscriptions', 'x-feed'])}${Platform.pathSeparator}',
        ),
      );
    });
  });
}

class _FakeTransport implements FeedTransport {
  final String body;
  const _FakeTransport(this.body);

  @override
  Future<RawFeedResponse> get(
    String url, {
    String? etag,
    String? lastModified,
  }) async =>
      RawFeedResponse(statusCode: 200, body: body);
}
