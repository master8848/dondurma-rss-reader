/// WP2 tests: FeedEngine type-aware fetch/parse, routing, materialization.
///
/// Covers the interface contract: setFeedType/getType per feeds.yaml;
/// route(tags) -> folder via user rules with default fallback; prompt items
/// materialize to subscriptions/<feed>/ Markdown; malformed feeds are skipped
/// with a diagnostic and never throw; offline serves cached Markdown;
/// duplicate items are deduped by id/guid.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ice_cream_rss_reader/promptlib/feed_config.dart';
import 'package:ice_cream_rss_reader/promptlib/feed_engine.dart';
import 'package:ice_cream_rss_reader/promptlib/prompt_doc.dart';
import 'package:ice_cream_rss_reader/promptlib/prompt_store.dart';
import 'package:ice_cream_rss_reader/promptlib/router_rules.dart';

String _fixture(String name) =>
    File('test/fixtures/$name').readAsStringSync();

/// In-memory HTTP stub. Maps URL -> response body (200), status override,
/// or an exception to simulate offline.
class FakeTransport implements FeedTransport {
  final Map<String, String> bodies;
  final Map<String, int> statuses;
  final Set<String> offlineUrls;

  FakeTransport({
    this.bodies = const <String, String>{},
    this.statuses = const <String, int>{},
    this.offlineUrls = const <String>{},
  });

  @override
  Future<RawFeedResponse> get(
    String url, {
    String? etag,
    String? lastModified,
  }) async {
    if (offlineUrls.contains(url)) {
      throw const SocketException('no network');
    }
    final int status = statuses[url] ?? 200;
    if (status == 304) {
      return RawFeedResponse(statusCode: 304, body: '', etag: etag);
    }
    return RawFeedResponse(
      statusCode: status,
      body: bodies[url] ?? '',
      etag: 'etag-$url',
    );
  }
}

Future<PromptStore> _newStore(Directory root) async {
  final PromptStore store = PromptStore();
  await store.init(libraryRoot: root.path);
  return store;
}

FeedConfig _configWith(String url, FeedType type, String name) =>
    FeedConfig(<FeedConfigEntry>[
      FeedConfigEntry(url: url, name: name, type: type),
    ]);

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('promptlib_wp2_test_');
  });

  tearDown(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  group('setFeedType / getType', () {
    test('unknown feed defaults to other; set/get round-trips', () async {
      final PromptStore store = await _newStore(root);
      final FeedEngine engine = FeedEngine(store: store);
      addTearDown(store.dispose);
      expect(engine.getType('https://x.example/unknown.xml'),
          FeedType.other);
      engine.setFeedType(
        feedUrl: 'https://x.example/a.xml',
        type: FeedType.prompt,
        name: 'A Feed',
      );
      expect(
          engine.getType('https://x.example/a.xml'), FeedType.prompt);
      expect(engine.feedConfig.feeds, hasLength(1));
      // Preserves the name on type change when no name is given.
      engine.setFeedType(
        feedUrl: 'https://x.example/a.xml',
        type: FeedType.article,
      );
      expect(engine.getType('https://x.example/a.xml'), FeedType.article);
      expect(engine.feedConfig.entryForUrl('https://x.example/a.xml')?.name,
          'A Feed');
    });
  });

  group('routing rules', () {
    test('first matching tag wins; fallback to defaultFolder', () {
      final RouterRules rules = RouterRules(
        categoryToFolder: <String, String>{
          'coding': 'dev',
          'writing': 'notes',
        },
        defaultFolder: 'misc',
      );
      expect(rules.route(const ['writing', 'coding']), 'notes');
      expect(rules.route(const ['CODING ']), 'dev');
      expect(rules.route(const ['unknown']), 'misc');
      expect(rules.route(const []), 'misc');
    });

    test('null default keeps the feed folder', () {
      final RouterRules rules = RouterRules();
      expect(rules.route(const ['anything']), isNull);
      expect(rules.route(const []), isNull);
    });

    test('engine routes prompt items into rule folders', () async {
      final PromptStore store = await _newStore(root);
      addTearDown(store.dispose);
      const String url = 'https://example.com/prompts.xml';
      final FeedEngine engine = FeedEngine(
        store: store,
        config: _configWith(url, FeedType.prompt, 'Example Prompts'),
        transport: FakeTransport(
          bodies: <String, String>{url: _fixture('valid_prompt.xml')},
        ),
        rules: RouterRules(
          categoryToFolder: <String, String>{'coding': 'dev'},
          defaultFolder: 'misc',
        ),
      );
      final RefreshResult r =
          await engine.refreshFeed(feedUrl: url, name: 'Example Prompts');
      expect(r.materialized, 2);
      expect(r.duplicatesSkipped, 0);
      expect(r.issues, isEmpty);
      // coding -> dev/ ; writing (no rule) -> misc/ via defaultFolder.
      expect(
        File('${root.path}/subscriptions/dev/code-review-prompt.md')
            .existsSync(),
        isTrue,
      );
      expect(
        File('${root.path}/subscriptions/misc/standup-writer.md')
            .existsSync(),
        isTrue,
      );
    });

    test('missing categories fall back to the feed folder', () async {
      final PromptStore store = await _newStore(root);
      addTearDown(store.dispose);
      const String url = 'https://example.com/nocats.xml';
      final FeedEngine engine = FeedEngine(
        store: store,
        config: _configWith(url, FeedType.prompt, 'No Cats'),
        transport: FakeTransport(
          bodies: <String, String>{
            url: _fixture('missing_categories.xml')
          },
        ),
      );
      final RefreshResult r =
          await engine.refreshFeed(feedUrl: url, name: 'No Cats');
      expect(r.materialized, 2);
      expect(
        Directory('${root.path}/subscriptions/no-cats')
            .listSync()
            .whereType<File>()
            .length,
        2,
      );
    });
  });

  group('materialization by type', () {
    test('prompt feeds write Markdown; article/other stay read-only',
        () async {
      for (final FeedType type in FeedType.values) {
        final Directory sub =
            await Directory.systemTemp.createTemp('promptlib_wp2_type_');
        addTearDown(() => sub.delete(recursive: true));
        final PromptStore store = await _newStore(sub);
        addTearDown(store.dispose);
        const String url = 'https://example.com/f.xml';
        final FeedEngine engine = FeedEngine(
          store: store,
          config: _configWith(url, type, 'F'),
          transport: FakeTransport(
            bodies: <String, String>{url: _fixture('valid_prompt.xml')},
          ),
        );
        final RefreshResult r =
            await engine.refreshFeed(feedUrl: url, name: 'F');
        expect(r.items, hasLength(2));
        final bool hasMarkdown = Directory('${sub.path}/subscriptions')
            .existsSync()
            ? Directory('${sub.path}/subscriptions')
                .listSync(recursive: true)
                .whereType<File>()
                .isNotEmpty
            : false;
        if (type == FeedType.prompt) {
          expect(r.materialized, 2);
          expect(hasMarkdown, isTrue);
        } else {
          expect(r.materialized, 0);
          expect(hasMarkdown, isFalse,
              reason: '$type feeds must not write to disk');
        }
      }
    });

    test('materialized docs carry tags + source link and serve offline',
        () async {
      final PromptStore store = await _newStore(root);
      addTearDown(store.dispose);
      const String url = 'https://example.com/prompts.xml';
      final FeedEngine engine = FeedEngine(
        store: store,
        config: _configWith(url, FeedType.prompt, 'Example Prompts'),
        transport: FakeTransport(
          bodies: <String, String>{url: _fixture('valid_prompt.xml')},
        ),
      );
      await engine.refreshFeed(feedUrl: url, name: 'Example Prompts');
      final List<PromptDoc> cached =
          await engine.cachedForFeed(feedUrl: url);
      expect(cached, hasLength(2));
      expect(cached.map((PromptDoc d) => d.sourceFeed), everyElement(url));
      expect(
        (await engine.itemsFor(FeedType.prompt)).length,
        greaterThanOrEqualTo(2),
      );
    });
  });

  group('duplicates', () {
    test('same guid twice in one refresh is collapsed', () async {
      final PromptStore store = await _newStore(root);
      addTearDown(store.dispose);
      const String url = 'https://example.com/dups.xml';
      final FeedEngine engine = FeedEngine(
        store: store,
        config: _configWith(url, FeedType.prompt, 'Dups'),
        transport: FakeTransport(
          bodies: <String, String>{url: _fixture('duplicates.xml')},
        ),
      );
      final RefreshResult r =
          await engine.refreshFeed(feedUrl: url, name: 'Dups');
      expect(r.items, hasLength(3));
      expect(r.duplicatesSkipped, 1);
      expect(r.materialized, 2);
    });

    test('second refresh of the same feed rewrites, not duplicates',
        () async {
      final PromptStore store = await _newStore(root);
      addTearDown(store.dispose);
      const String url = 'https://example.com/prompts.xml';
      final FakeTransport transport = FakeTransport(
        bodies: <String, String>{url: _fixture('valid_prompt.xml')},
      );
      final FeedEngine engine = FeedEngine(
        store: store,
        config: _configWith(url, FeedType.prompt, 'Example Prompts'),
        transport: transport,
      );
      await engine.refreshFeed(feedUrl: url, name: 'Example Prompts');
      final RefreshResult again =
          await engine.refreshFeed(feedUrl: url, name: 'Example Prompts');
      expect(again.materialized, 2);
      final List<PromptDoc> cached =
          await engine.cachedForFeed(feedUrl: url);
      expect(cached, hasLength(2));
    });
  });

  group('failure contract: never crash', () {
    test('malformed feed is skipped with a diagnostic', () async {
      final PromptStore store = await _newStore(root);
      addTearDown(store.dispose);
      const String url = 'https://example.com/broken.xml';
      final FeedEngine engine = FeedEngine(
        store: store,
        config: _configWith(url, FeedType.prompt, 'Broken'),
        transport: FakeTransport(
          bodies: <String, String>{url: _fixture('malformed.xml')},
        ),
      );
      final RefreshResult r =
          await engine.refreshFeed(feedUrl: url, name: 'Broken');
      expect(r.servedFromCache, isTrue);
      expect(r.materialized, 0);
      expect(
        r.issues.map((FeedDiagnostic d) => d.kind),
        contains(FeedIssueKind.malformed),
      );
      expect(engine.diagnostics, isNotEmpty);
    });

    test('offline transport serves cache without throwing', () async {
      final PromptStore store = await _newStore(root);
      addTearDown(store.dispose);
      const String url = 'https://example.com/prompts.xml';
      final FakeTransport online = FakeTransport(
        bodies: <String, String>{url: _fixture('valid_prompt.xml')},
      );
      final FeedEngine warm = FeedEngine(
        store: store,
        config: _configWith(url, FeedType.prompt, 'Example Prompts'),
        transport: online,
      );
      await warm.refreshFeed(feedUrl: url, name: 'Example Prompts');
      expect(await engineCachedCount(engine: warm, url: url), 2);

      final FeedEngine offline = FeedEngine(
        store: store,
        config: _configWith(url, FeedType.prompt, 'Example Prompts'),
        transport: FakeTransport(
          offlineUrls: <String>{url},
        ),
      );
      final RefreshResult r =
          await offline.refreshFeed(feedUrl: url, name: 'Example Prompts');
      expect(r.servedFromCache, isTrue);
      expect(
        r.issues.map((FeedDiagnostic d) => d.kind),
        contains(FeedIssueKind.offline),
      );
      // Cached Markdown is still readable offline.
      expect(await engineCachedCount(engine: offline, url: url), 2);
    });

    test('HTTP error + 304 never throw', () async {
      final PromptStore store = await _newStore(root);
      addTearDown(store.dispose);
      const String bad = 'https://example.com/500.xml';
      const String same = 'https://example.com/same.xml';
      final FeedEngine engine = FeedEngine(
        store: store,
        config: FeedConfig(<FeedConfigEntry>[
          const FeedConfigEntry(
              url: bad, name: 'Bad', type: FeedType.prompt),
          const FeedConfigEntry(
              url: same, name: 'Same', type: FeedType.prompt),
        ]),
        transport: FakeTransport(
          bodies: <String, String>{same: _fixture('valid_prompt.xml')},
          statuses: <String, int>{bad: 500, same: 304},
        ),
      );
      final List<RefreshResult> all = await engine.refreshAll();
      expect(all, hasLength(2));
      expect(all[0].servedFromCache, isTrue);
      expect(all[0].issues.map((FeedDiagnostic d) => d.kind),
          contains(FeedIssueKind.httpError));
      expect(all[1].notModified, isTrue);
    });
  });

  group('huge feeds', () {
    test('per-feed cap keeps the 50 most recent', () async {
      final List<EngineFeedItem> parsed = FeedEngine.parseFeedBody(
        _fixture('huge.xml'),
        feedUrl: 'https://example.com/huge.xml',
      );
      expect(parsed, hasLength(60));
      final List<EngineFeedItem> capped = FeedEngine.capItems(parsed);
      expect(capped, hasLength(FeedEngine.maxItemsPerFeed));
    });

    test('refresh of a huge prompt feed materializes at most the cap',
        () async {
      final PromptStore store = await _newStore(root);
      addTearDown(store.dispose);
      const String url = 'https://example.com/huge.xml';
      final FeedEngine engine = FeedEngine(
        store: store,
        config: _configWith(url, FeedType.prompt, 'Huge'),
        transport: FakeTransport(
          bodies: <String, String>{url: _fixture('huge.xml')},
        ),
      );
      final RefreshResult r =
          await engine.refreshFeed(feedUrl: url, name: 'Huge');
      expect(r.materialized, FeedEngine.maxItemsPerFeed);
    });

    test('oversized bodies truncate with a diagnostic', () async {
      final PromptStore store = await _newStore(root);
      addTearDown(store.dispose);
      const String url = 'https://example.com/big.xml';
      final String body = 'x' * 1000;
      final String xml = '<?xml version="1.0"?>'
          '<rss version="2.0"><channel><title>B</title>'
          '<item><title>Big</title><guid>big-1</guid>'
          '<description>$body</description></item>'
          '</channel></rss>';
      final FeedEngine engine = FeedEngine(
        store: store,
        config: _configWith(url, FeedType.prompt, 'Big'),
        transport: FakeTransport(bodies: <String, String>{url: xml}),
        maxBodyChars: 100,
      );
      final RefreshResult r =
          await engine.refreshFeed(feedUrl: url, name: 'Big');
      expect(r.truncatedCount, 1);
      expect(r.issues.map((FeedDiagnostic d) => d.kind),
          contains(FeedIssueKind.truncated));
    });
  });

  group('folder cache rules', () {
    test('overflow is reported without deleting by default', () async {
      final Directory dir =
          Directory('${root.path}/subs-overflow')..createSync();
      for (int i = 0; i < 5; i++) {
        File('${dir.path}/p$i.md').writeAsStringSync('# $i');
      }
      final FolderCacheRules rules =
          FolderCacheRules(maxFilesPerFolder: 3);
      final ({int fileCount, int overflow, int removed}) res =
          await rules.pruneFolder(dir.path);
      expect(res.fileCount, 5);
      expect(res.overflow, 2);
      expect(res.removed, 0);
      expect(dir.listSync().length, 5);
    });

    test('evictOldest prunes the oldest files first', () async {
      final Directory dir =
          Directory('${root.path}/subs-evict')..createSync();
      for (int i = 0; i < 4; i++) {
        final File f = File('${dir.path}/p$i.md')
          ..writeAsStringSync('# $i');
        await f.setLastModified(
            DateTime.utc(2026, 1, 1 + i));
      }
      final FolderCacheRules rules = FolderCacheRules(
        maxFilesPerFolder: 2,
        evictOldest: true,
      );
      final ({int fileCount, int overflow, int removed}) res =
          await rules.pruneFolder(dir.path);
      expect(res.removed, 2);
      expect(res.fileCount, 2);
      expect(File('${dir.path}/p0.md').existsSync(), isFalse);
      expect(File('${dir.path}/p1.md').existsSync(), isFalse);
      expect(File('${dir.path}/p3.md').existsSync(), isTrue);
    });

    test('missing directory counts as empty, never throws', () async {
      final FolderCacheRules rules = FolderCacheRules();
      final res = await rules.pruneFolder(
          '${root.path}/does-not-exist-xyz');
      expect(res.fileCount, 0);
      expect(res.overflow, 0);
    });
  });

  group('pure-Dart core', () {
    test('no flutter imports in promptlib engine files', () {
      final RegExp importFlutter = RegExp(
        r'''^\s*import\s+['"]package:flutter''',
        multiLine: true,
      );
      for (final String name in <String>[
        'feed_engine.dart',
        'router_rules.dart',
      ]) {
        final String src =
            File('lib/promptlib/$name').readAsStringSync();
        expect(src.contains(importFlutter), isFalse,
            reason: '$name must stay pure-Dart');
      }
    });
  });
}

Future<int> engineCachedCount({
  required FeedEngine engine,
  required String url,
}) async =>
    (await engine.cachedForFeed(feedUrl: url)).length;
