/// WP2 feed engine: type-aware fetch/parse, routing, Markdown materializer.
///
/// Pure-Dart, dependency-free: like everything under `lib/promptlib/`, this
/// file must never import `package:flutter/*` so the core stays unit-testable
/// with plain `dart test`.
///
/// The engine wraps the `FeedService` patterns from
/// `lib/services/feed_service.dart` (read-only reference — that file imports
/// Flutter and `dart_rss`, so it cannot be reused directly here):
///
/// * conditional HTTP via `etag` / `last-modified` validators with `304 Not
///   Modified` short-circuit (no body to parse);
/// * RSS-first, Atom-fallback parsing;
/// * at most [FeedEngine.maxItemsPerFeed] (= 50, mirroring
///   `FeedService.maxItemsPerFeed`) most-recent items per refresh;
/// * stable fallback IDs derived from feed URL + title + date (never
///   `DateTime.now()`, which would break read-state tracking).
///
/// NOTE (dependency): the XML/HTTP work below is a minimal dependency-free
/// subset covering exactly the promptlib fixtures. A future workstream should
/// delegate transport to `package:http` and parsing to `package:dart_rss`
/// (both already app dependencies); `pubspec.yaml` is intentionally
/// untouched by WP2.
///
/// Type behaviour (`FeedType` from `feed_config.dart`, backed by the
/// `.promptlib/feeds.yaml` registry):
///
/// * `prompt` feeds materialize into `subscriptions/<feed>/` as Markdown via
///   [PromptStore.materializeSubscribedItem] (offline-usable).
/// * `article` / `other` feeds are parsed and returned read-only — nothing is
///   written to disk for them.
///
/// Failure contract: a malformed feed, an HTTP error, or a missing network
/// never throws out of [refreshFeed]/[refreshAll]. The failure is recorded as
/// a [FeedDiagnostic] and the caller is served the cached Markdown already on
/// disk (offline behaviour).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'feed_config.dart';
import 'prompt_doc.dart';
import 'prompt_store.dart';
import 'router_rules.dart';

/// One parsed feed item in engine-local (UI-free) form.
///
/// A thin WP3 adapter can bridge `FeedItem` (`lib/models/`, Flutter-bound)
/// to this struct; the engine itself never touches Flutter types.
class EngineFeedItem {
  /// Stable id: guid/link when present, else a hash of feed+title+date.
  final String id;
  final String title;

  /// Plain-text body converted from the item's HTML content.
  final String body;
  final List<String> tags;
  final String link;
  final String? imageUrl;
  final DateTime? pubDate;
  final String sourceUrl;

  const EngineFeedItem({
    required this.id,
    required this.title,
    required this.body,
    required this.tags,
    required this.link,
    required this.sourceUrl,
    this.imageUrl,
    this.pubDate,
  });

  @override
  String toString() => 'EngineFeedItem(id: $id, title: $title)';
}

/// What went wrong with one feed fetch/parse/materialize step.
enum FeedIssueKind {
  /// No network / transport threw: served cached Markdown instead.
  offline,

  /// Non-200, non-304 HTTP status: served cached Markdown instead.
  httpError,

  /// Body is not parseable RSS/Atom: skipped, served cache instead.
  malformed,

  /// Recognized feed envelope with zero usable items.
  empty,

  /// An item body exceeded [FeedEngine.maxBodyChars] and was truncated.
  truncated,

  /// The local store write failed (disk/permissions): item skipped.
  store,
}

/// One recorded feed failure. Never thrown — collected for diagnostics/tests.
class FeedDiagnostic {
  final String feedUrl;
  final FeedIssueKind kind;
  final String message;
  final DateTime at;

  FeedDiagnostic({
    required this.feedUrl,
    required this.kind,
    required this.message,
    DateTime? at,
  }) : at = at ?? DateTime.now().toUtc();

  @override
  String toString() => 'FeedDiagnostic($kind $feedUrl: $message)';
}

/// Outcome of one [FeedEngine.refreshFeed] call. Never an exception for
/// feed-level failures — those land in [issues] with cached content served.
class RefreshResult {
  final String feedUrl;
  final FeedType feedType;
  final List<EngineFeedItem> items;
  final int materialized;
  final int duplicatesSkipped;
  final int truncatedCount;
  final bool notModified;
  final bool servedFromCache;
  final List<FeedDiagnostic> issues;

  const RefreshResult({
    required this.feedUrl,
    required this.feedType,
    this.items = const <EngineFeedItem>[],
    this.materialized = 0,
    this.duplicatesSkipped = 0,
    this.truncatedCount = 0,
    this.notModified = false,
    this.servedFromCache = false,
    this.issues = const <FeedDiagnostic>[],
  });
}

/// Raw HTTP outcome handed from a [FeedTransport] to the engine.
class RawFeedResponse {
  final int statusCode;
  final String body;
  final String? etag;
  final String? lastModified;

  const RawFeedResponse({
    required this.statusCode,
    required this.body,
    this.etag,
    this.lastModified,
  });
}

/// Pluggable HTTP layer. The default ([IoFeedTransport]) uses `dart:io`;
/// tests inject a fake. Never Flutter-bound.
abstract class FeedTransport {
  Future<RawFeedResponse> get(
    String url, {
    String? etag,
    String? lastModified,
  });
}

/// Default transport over `dart:io` [HttpClient].
///
/// Mirrors the `FeedService` header patterns: browser-like User-Agent
/// (avoids Cloudflare 403 challenges), feed Accept header, conditional
/// `If-None-Match` / `If-Modified-Since` from stored validators, 10s timeout.
class IoFeedTransport implements FeedTransport {
  static const String userAgent =
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
      'AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/122.0.0.0 Safari/537.36';

  static const String acceptHeader =
      'application/rss+xml, application/rdf+xml, '
      'application/atom+xml, application/xml, '
      'text/xml, text/html;q=0.9';

  final Duration timeout;

  const IoFeedTransport({this.timeout = const Duration(seconds: 10)});

  @override
  Future<RawFeedResponse> get(
    String url, {
    String? etag,
    String? lastModified,
  }) async {
    final HttpClient client = HttpClient();
    try {
      final HttpClientRequest req =
          await client.getUrl(Uri.parse(url)).timeout(timeout);
      req.headers.set(HttpHeaders.userAgentHeader, userAgent);
      req.headers.set(HttpHeaders.acceptHeader, acceptHeader);
      if (etag != null) req.headers.set(HttpHeaders.ifNoneMatchHeader, etag);
      if (lastModified != null) {
        req.headers.set(HttpHeaders.ifModifiedSinceHeader, lastModified);
      }
      final HttpClientResponse resp = await req.close().timeout(timeout);
      final String body = await resp.transform(utf8.decoder).join().timeout(
            timeout,
          );
      return RawFeedResponse(
        statusCode: resp.statusCode,
        body: body,
        etag: resp.headers.value(HttpHeaders.etagHeader),
        lastModified: resp.headers.value(HttpHeaders.lastModifiedHeader),
      );
    } finally {
      client.close(force: true);
    }
  }
}

class _Validators {
  final String? etag;
  final String? lastModified;
  const _Validators(this.etag, this.lastModified);
}

/// Type-aware feed engine. See the library doc comment for the contract.
class FeedEngine {
  /// Max items kept per feed refresh, mirroring `FeedService.maxItemsPerFeed`.
  static const int maxItemsPerFeed = 50;

  final PromptStore _store;
  FeedConfig _config;
  final FeedTransport _transport;
  final RouterRules _rules;
  final FolderCacheRules _cacheRules;

  /// Bodies longer than this are truncated before materializing (with a
  /// [FeedIssueKind.truncated] diagnostic). Bounds single-file mirror size.
  final int maxBodyChars;

  final Map<String, _Validators> _validators = <String, _Validators>{};
  final List<FeedDiagnostic> _diagnostics = <FeedDiagnostic>[];

  FeedEngine({
    required PromptStore store,
    FeedConfig config = const FeedConfig(),
    FeedTransport? transport,
    RouterRules rules = const RouterRules(),
    FolderCacheRules cacheRules = const FolderCacheRules(),
    this.maxBodyChars = 50000,
  })  : _store = store,
        _config = config,
        _transport = transport ?? const IoFeedTransport(),
        _rules = rules,
        _cacheRules = cacheRules {
    // Propagate the initial registry so PromptStore.listLocal(type:)
    // resolves subscription folders (setFeedType keeps this in sync after).
    _store.feedConfig = _config;
  }

  /// Current registry (updated by [setFeedType]).
  FeedConfig get feedConfig => _config;

  /// Cumulative diagnostics log across refreshes. See [clearDiagnostics].
  List<FeedDiagnostic> get diagnostics =>
      List<FeedDiagnostic>.unmodifiable(_diagnostics);

  void clearDiagnostics() => _diagnostics.clear();

  /// Returns the registered type for [feedUrl], defaulting to
  /// [FeedType.other] for unknown feeds.
  FeedType getType(String feedUrl) =>
      _config.entryForUrl(feedUrl)?.type ?? FeedType.other;

  /// Sets the per-feed type in the registry (backed by `.promptlib/feeds.yaml`
  /// entries loaded via [FeedConfig]).
  ///
  /// Updates the existing entry (preserving its name unless [name] is given)
  /// or appends a new `{url, name, type}` entry. In-memory only: WP1's
  /// [FeedConfig] has no YAML writer, so callers that need persistence should
  /// serialize [feedConfig] themselves; a `FeedConfig.save` writer is future
  /// work (noted for the Publisher workstream, which owns file generation).
  void setFeedType({
    required String feedUrl,
    required FeedType type,
    String? name,
  }) {
    final List<FeedConfigEntry> entries =
        List<FeedConfigEntry>.from(_config.feeds);
    final int at = entries.indexWhere((FeedConfigEntry e) => e.url == feedUrl);
    if (at == -1) {
      entries.add(FeedConfigEntry(
        url: feedUrl,
        name: (name == null || name.trim().isEmpty) ? feedUrl : name,
        type: type,
      ));
    } else {
      final FeedConfigEntry prev = entries[at];
      final String nextName = (name == null || name.trim().isEmpty)
          ? prev.name
          : name;
      entries[at] = FeedConfigEntry(url: prev.url, name: nextName, type: type);
    }
    _config = FeedConfig(entries);
    _store.feedConfig = _config;
  }

  /// Lists cached local prompts of one [FeedType] (offline-capable:
  /// reads only the on-disk `library/` + `subscriptions/` mirror).
  Future<List<PromptDoc>> itemsFor(FeedType type) =>
      _store.listLocal(type: type);

  /// Returns cached Markdown docs whose `source_feed` is [feedUrl] or the
  /// slug of [feedSlug]. This is the offline serving path.
  Future<List<PromptDoc>> cachedForFeed({
    required String feedUrl,
    String? feedSlug,
  }) async {
    final Set<String> keys = <String>{feedUrl};
    if (feedSlug != null && feedSlug.trim().isNotEmpty) {
      keys.add(feedSlug);
      keys.add(slugifyTitle(feedSlug));
    }
    final List<PromptDoc> all = await _store.listLocal();
    return all
        .where((PromptDoc d) =>
            d.sourceFeed != null && keys.contains(d.sourceFeed))
        .toList();
  }

  /// Refreshes every feed in [feedConfig]. Per-feed failures are captured in
  /// each [RefreshResult.issues] (and [diagnostics]); this never throws for
  /// feed-level problems.
  Future<List<RefreshResult>> refreshAll() async {
    final List<RefreshResult> out = <RefreshResult>[];
    for (final FeedConfigEntry entry in _config.feeds) {
      out.add(await refreshFeed(feedUrl: entry.url, name: entry.name));
    }
    return out;
  }

  /// Fetches, parses, routes and (for `prompt` feeds) materializes one feed.
  ///
  /// Never throws for feed-level failures (transport/HTTP/parse/store): the
  /// failure is recorded and cached Markdown is served instead
  /// ([RefreshResult.servedFromCache]).
  Future<RefreshResult> refreshFeed({
    required String feedUrl,
    String? feedSlug,
    String? name,
  }) async {
    final FeedType type = getType(feedUrl);
    final String slug = (feedSlug == null || feedSlug.trim().isEmpty)
        ? slugifyTitle(
            (name == null || name.trim().isEmpty) ? feedUrl : name!,
          )
        : slugifyTitle(feedSlug);
    final List<FeedDiagnostic> issues = <FeedDiagnostic>[];

    void report(FeedIssueKind kind, String message) {
      final FeedDiagnostic d = FeedDiagnostic(
        feedUrl: feedUrl,
        kind: kind,
        message: message,
      );
      issues.add(d);
      _diagnostics.add(d);
    }

    // ---- fetch (conditional when validators are known) ----
    final _Validators? known = _validators[feedUrl];
    RawFeedResponse resp;
    try {
      resp = await _transport.get(
        feedUrl,
        etag: known?.etag,
        lastModified: known?.lastModified,
      );
    } catch (e) {
      // Offline (DNS/socket/timeout/...): serve cached Markdown.
      report(FeedIssueKind.offline, 'transport failed ($e); serving cache');
      return RefreshResult(
        feedUrl: feedUrl,
        feedType: type,
        servedFromCache: true,
        issues: issues,
      );
    }

    if (resp.statusCode == 304) {
      return RefreshResult(
        feedUrl: feedUrl,
        feedType: type,
        notModified: true,
        servedFromCache: true,
        issues: issues,
      );
    }
    if (resp.statusCode != 200) {
      report(
        FeedIssueKind.httpError,
        'HTTP ${resp.statusCode}; serving cache',
      );
      return RefreshResult(
        feedUrl: feedUrl,
        feedType: type,
        servedFromCache: true,
        issues: issues,
      );
    }
    _validators[feedUrl] = _Validators(resp.etag, resp.lastModified);

    // ---- parse (RSS first, Atom fallback) ----
    List<EngineFeedItem> parsed;
    try {
      parsed = parseFeedBody(resp.body, feedUrl: feedUrl);
    } on FormatException catch (e) {
      report(FeedIssueKind.malformed, 'skipped malformed feed ($e)');
      return RefreshResult(
        feedUrl: feedUrl,
        feedType: type,
        servedFromCache: true,
        issues: issues,
      );
    }
    if (parsed.isEmpty) {
      report(FeedIssueKind.empty, 'feed parsed with zero items');
    }
    parsed = capItems(parsed);

    // ---- article/other feeds stay read-only: parse, don't materialize ----
    if (type != FeedType.prompt) {
      return RefreshResult(
        feedUrl: feedUrl,
        feedType: type,
        items: parsed,
        issues: issues,
      );
    }

    // ---- prompt feeds: route + materialize as Markdown ----
    int materialized = 0;
    int duplicates = 0;
    int truncated = 0;
    final Set<String> seenIds = <String>{};
    final Set<String> touchedFolders = <String>{};
    for (final EngineFeedItem item in parsed) {
      if (!seenIds.add(item.id)) {
        duplicates++;
        continue; // same upstream id twice in one refresh: collapse
      }
      String body = item.body;
      if (body.length > maxBodyChars) {
        body = '${body.substring(0, maxBodyChars)}\n\n…(truncated)';
        truncated++;
      }
      final String? routed = _rules.route(item.tags);
      final String folder =
          (routed == null || routed.trim().isEmpty) ? slug : routed;
      try {
        await _store.materializeSubscribedItem(
          feedSlug: folder,
          id: item.id,
          title: item.title,
          body: body,
          tags: item.tags,
          sourceUrl: feedUrl,
          published: item.pubDate,
        );
        materialized++;
        touchedFolders.add(folder);
      } catch (e) {
        report(
          FeedIssueKind.store,
          'skipped item ${item.id} (store failed: $e)',
        );
      }
    }
    if (truncated > 0) {
      report(
        FeedIssueKind.truncated,
        '$truncated item(s) truncated to $maxBodyChars chars',
      );
    }
    for (final String folder in touchedFolders) {
      final String dirPath =
          '${_store.libraryRoot}${Platform.pathSeparator}'
          '${PromptStore.subscriptionsDirName}${Platform.pathSeparator}'
          '${slugifyTitle(folder)}';
      try {
        await _cacheRules.pruneFolder(dirPath);
      } catch (_) {
        // Cache pruning is best-effort; materialized content is already safe.
      }
    }
    return RefreshResult(
      feedUrl: feedUrl,
      feedType: type,
      items: parsed,
      materialized: materialized,
      duplicatesSkipped: duplicates,
      truncatedCount: truncated,
      issues: issues,
    );
  }

  /// Returns at most [maxItemsPerFeed] most-recent items, mirroring
  /// `FeedService.capItems`: untouched when under the cap, otherwise sorted
  /// by descending publication date (undated items sort last).
  static List<EngineFeedItem> capItems(List<EngineFeedItem> items) {
    if (items.length <= maxItemsPerFeed) return items;
    final List<EngineFeedItem> sorted = items.toList()
      ..sort((EngineFeedItem a, EngineFeedItem b) {
        if (a.pubDate == null && b.pubDate == null) return 0;
        if (a.pubDate == null) return 1;
        if (b.pubDate == null) return -1;
        return b.pubDate!.compareTo(a.pubDate!);
      });
    return sorted.take(maxItemsPerFeed).toList();
  }

  /// Parses a raw feed body into items: RSS first, Atom fallback.
  ///
  /// Throws [FormatException] when the body is not recognizable RSS/Atom
  /// (missing root envelope, truncated envelope, zero complete entries).
  /// Never throws anything else.
  static List<EngineFeedItem> parseFeedBody(
    String body, {
    required String feedUrl,
  }) {
    try {
      return _parseInner(body, feedUrl);
    } on FormatException {
      rethrow;
    } catch (e) {
      throw FormatException('promptlib: unable to parse feed: $e');
    }
  }

  static List<EngineFeedItem> _parseInner(String body, String feedUrl) {
    final String text = body.trim();
    if (text.isEmpty) {
      throw const FormatException('promptlib: empty feed body');
    }
    final bool looksRss = RegExp(r'<rss[\s>]', caseSensitive: false)
            .hasMatch(text) ||
        RegExp(r'<rdf:RDF[\s>]', caseSensitive: false).hasMatch(text) ||
        RegExp(r'<channel[\s>]', caseSensitive: false).hasMatch(text);
    final bool looksAtom =
        RegExp(r'<feed[\s>]', caseSensitive: false).hasMatch(text);

    if (!looksRss && !looksAtom) {
      throw const FormatException(
        'promptlib: not a recognized RSS/Atom feed (no rss/channel/feed root)',
      );
    }
    // Truncated download: the root envelope never closes.
    final bool rssClosed =
        RegExp(r'</rss\s*>', caseSensitive: false).hasMatch(text) ||
            RegExp(r'</rdf:RDF\s*>', caseSensitive: false).hasMatch(text) ||
            RegExp(r'</channel\s*>', caseSensitive: false).hasMatch(text);
    final bool atomClosed =
        RegExp(r'</feed\s*>', caseSensitive: false).hasMatch(text);
    if (looksRss && !looksAtom && !rssClosed) {
      throw const FormatException(
        'promptlib: truncated RSS feed (unclosed root envelope)',
      );
    }
    if (looksAtom && !looksRss && !atomClosed) {
      throw const FormatException(
        'promptlib: truncated Atom feed (unclosed root envelope)',
      );
    }

    // RSS first.
    final List<EngineFeedItem> rss = _parseRssItems(text, feedUrl);
    if (rss.isNotEmpty) return rss;
    // Atom fallback.
    final List<EngineFeedItem> atom = _parseAtomEntries(text, feedUrl);
    if (atom.isNotEmpty) return atom;
    throw const FormatException(
      'promptlib: recognized feed envelope with zero complete entries',
    );
  }

  static List<EngineFeedItem> _parseRssItems(String text, String feedUrl) {
    final List<EngineFeedItem> out = <EngineFeedItem>[];
    for (final RegExpMatch m in RegExp(
      r'<item[\s>](.*?)</item\s*>',
      caseSensitive: false,
      dotAll: true,
    ).allMatches(text)) {
      final String block = m.group(1)!;
      final String title =
          _fieldText(block, <String>['title']).trim().isEmpty
              ? 'Untitled'
              : _decodeEntities(_fieldText(block, <String>['title']).trim());
      final String guid = _fieldText(block, <String>['guid']).trim();
      String link = _fieldText(block, <String>['link']).trim();
      if (link.isEmpty) {
        link = _atomLinkHref(block) ?? '';
      }
      final String rawDate =
          _fieldText(block, <String>['pubDate', 'dc:date']).trim();
      final String content = _fieldText(
        block,
        <String>['content:encoded', 'description'],
      );
      final List<String> tags = _rssCategories(block);
      final String? image = _enclosureImage(block);
      final String id = _stableId(
        feedUrl: feedUrl,
        guid: guid,
        link: link,
        title: title == 'Untitled' ? '' : title,
        rawDate: rawDate,
      );
      out.add(EngineFeedItem(
        id: id,
        title: title,
        body: htmlToText(content),
        tags: tags,
        link: link,
        imageUrl: image,
        pubDate: parseFeedDate(rawDate),
        sourceUrl: feedUrl,
      ));
    }
    return out;
  }

  static List<EngineFeedItem> _parseAtomEntries(String text, String feedUrl) {
    final List<EngineFeedItem> out = <EngineFeedItem>[];
    for (final RegExpMatch m in RegExp(
      r'<entry[\s>](.*?)</entry\s*>',
      caseSensitive: false,
      dotAll: true,
    ).allMatches(text)) {
      final String block = m.group(1)!;
      final String rawTitle = _fieldText(block, <String>['title']).trim();
      final String title =
          rawTitle.isEmpty ? 'Untitled' : _decodeEntities(rawTitle);
      final String atomId = _fieldText(block, <String>['id']).trim();
      final String link = _atomLinkHref(block) ?? '';
      final String rawDate =
          _fieldText(block, <String>['updated', 'published']).trim();
      final String content = _fieldText(
        block,
        <String>['content', 'summary'],
      );
      final List<String> tags = _atomCategories(block);
      final String id = _stableId(
        feedUrl: feedUrl,
        guid: atomId,
        link: link,
        title: title == 'Untitled' ? '' : title,
        rawDate: rawDate,
      );
      out.add(EngineFeedItem(
        id: id,
        title: title,
        body: htmlToText(content),
        tags: tags,
        link: link,
        pubDate: parseFeedDate(rawDate),
        sourceUrl: feedUrl,
      ));
    }
    return out;
  }

  /// Stable id: guid, else link, else `fallback-<fnv>` over feed+title+date.
  ///
  /// Never time-based: the same upstream article keeps the same id across
  /// refreshes (mirrors `FeedService.fallbackId` via `ArticleIdentity`).
  static String _stableId({
    required String feedUrl,
    required String guid,
    required String link,
    required String title,
    required String rawDate,
  }) {
    if (guid.isNotEmpty) return guid;
    if (link.isNotEmpty) return link;
    return 'fallback-${_fnvHex('$feedUrl|$title|$rawDate')}';
  }

  /// FNV-1a 64-bit hex (dependency-free stable hash for fallback ids).
  static String _fnvHex(String input) {
    int hash = 0xcbf29ce484222325;
    for (final int byte in utf8.encode(input)) {
      hash ^= byte;
      hash = (hash * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
    }
    return hash.toRadixString(16).padLeft(16, '0');
  }

  static String _fieldText(String block, List<String> names) {
    for (final String name in names) {
      final RegExpMatch? m = RegExp(
        '<${RegExp.escape(name)}(?:\\s[^>]*)?>(.*?)</${RegExp.escape(name)}\\s*>',
        caseSensitive: false,
        dotAll: true,
      ).firstMatch(block);
      if (m != null) return _stripCdata(m.group(1)!);
    }
    return '';
  }

  static String _stripCdata(String raw) {
    String s = raw.trim();
    if (s.startsWith('<![CDATA[') && s.endsWith(']]>')) {
      s = s.substring(9, s.length - 3);
    }
    return s;
  }

  static List<String> _rssCategories(String block) {
    return RegExp(
      r'<category(?:\s[^>]*)?>(.*?)</category\s*>',
      caseSensitive: false,
      dotAll: true,
    )
        .allMatches(block)
        .map((RegExpMatch m) => _decodeEntities(_stripCdata(m.group(1)!).trim()))
        .where((String t) => t.isNotEmpty)
        .toList();
  }

  static List<String> _atomCategories(String block) {
    final List<String> terms = RegExp(
      r'''<category\s[^>]*term\s*=\s*["']([^"']+)["']''',
      caseSensitive: false,
    )
        .allMatches(block)
        .map((RegExpMatch m) => _decodeEntities(m.group(1)!.trim()))
        .where((String t) => t.isNotEmpty)
        .toList();
    if (terms.isNotEmpty) return terms;
    return _rssCategories(block);
  }

  static String? _atomLinkHref(String block) {
    final RegExpMatch? m = RegExp(
      r'''<link\s[^>]*href\s*=\s*["']([^"']+)["']''',
      caseSensitive: false,
    ).firstMatch(block);
    final String? href = m?.group(1)?.trim();
    return (href == null || href.isEmpty) ? null : href;
  }

  static String? _enclosureImage(String block) {
    for (final RegExpMatch m in RegExp(
      r'<enclosure\s[^>]*>',
      caseSensitive: false,
    ).allMatches(block)) {
      final String tag = m.group(0)!;
      final RegExpMatch? typeM = RegExp(
        '''type\\s*=\\s*["']([^"']+)["']''',
        caseSensitive: false,
      ).firstMatch(tag);
      if (typeM != null && !typeM.group(1)!.toLowerCase().startsWith('image')) {
        continue;
      }
      final RegExpMatch? urlM = RegExp(
        '''url\\s*=\\s*["']([^"']+)["']''',
        caseSensitive: false,
      ).firstMatch(tag);
      if (urlM != null && urlM.group(1)!.trim().isNotEmpty) {
        return urlM.group(1)!.trim();
      }
    }
    return null;
  }

  /// Converts item HTML to plain-text Markdown body: block breaks become
  /// newlines, tags are stripped, entities decoded, whitespace collapsed.
  static String htmlToText(String html) {
    if (html.trim().isEmpty) return '';
    String s = _stripCdata(html);
    s = s.replaceAll(
      RegExp(r'<\s*(br|/p|/li|/h[1-6]|/blockquote|/pre)\b[^>]*>',
          caseSensitive: false),
      '\n',
    );
    s = s.replaceAll(
      RegExp(r'<\s*(p|li|h[1-6]|blockquote|pre)\b[^>]*>',
          caseSensitive: false),
      '\n',
    );
    s = s.replaceAll(RegExp(r'<[^>]+>'), '');
    s = _decodeEntities(s);
    s = s.replaceAll(RegExp(r'[ \t\x0B\f\r]+'), ' ');
    s = s.replaceAll(RegExp(r'\n[ \t]*\n[ \t\n]*'), '\n\n');
    return s.trim();
  }

  static String _decodeEntities(String text) {
    if (!text.contains('&')) return text;
    String s = text
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&apos;', "'")
        .replaceAll('&#8216;', '\u2018')
        .replaceAll('&#8217;', '\u2019')
        .replaceAll('&#8220;', '\u201C')
        .replaceAll('&#8221;', '\u201D')
        .replaceAll('&#8211;', '\u2013')
        .replaceAll('&#8212;', '\u2014')
        .replaceAll('&nbsp;', ' ');
    s = s.replaceAllMapped(
      RegExp(r'&#(\d+);'),
      (Match m) {
        final int? code = int.tryParse(m.group(1)!);
        return code == null ? m.group(0)! : String.fromCharCode(code);
      },
    );
    s = s.replaceAllMapped(
      RegExp(r'&#x([0-9a-fA-F]+);'),
      (Match m) {
        final int? code = int.tryParse(m.group(1)!, radix: 16);
        return code == null ? m.group(0)! : String.fromCharCode(code);
      },
    );
    return s;
  }

  /// Parses feed dates: ISO 8601 first, then RFC 822/2822 with numeric or
  /// common-abbreviation timezones (mirrors `FeedService._parseRssDate`).
  static DateTime? parseFeedDate(String? dateStr) {
    if (dateStr == null || dateStr.trim().isEmpty) return null;
    final String trimmed = dateStr.trim();
    final DateTime? iso = DateTime.tryParse(trimmed);
    if (iso != null) return iso;

    String normalized = trimmed;
    const Map<String, String> tzNames = <String, String>{
      'GMT': '+0000',
      'UTC': '+0000',
      'UT': '+0000',
      'Z': '+0000',
      'EST': '-0500',
      'EDT': '-0400',
      'CST': '-0600',
      'CDT': '-0500',
      'MST': '-0700',
      'MDT': '-0600',
      'PST': '-0800',
      'PDT': '-0700',
    };
    tzNames.forEach((String abbr, String offset) {
      normalized = normalized.replaceAll(
        RegExp('\\s+$abbr\$', caseSensitive: false),
        ' $offset',
      );
    });
    int offsetMinutes = 0;
    final RegExpMatch? tz =
        RegExp(r'\s*([+-])(\d{2})(\d{2})\s*$').firstMatch(normalized);
    if (tz != null) {
      final int sign = tz.group(1) == '+' ? 1 : -1;
      offsetMinutes =
          sign * (int.parse(tz.group(2)!) * 60 + int.parse(tz.group(3)!));
      normalized = normalized.substring(0, tz.start).trim();
    }
    final RegExpMatch? d = RegExp(
      r'^(?:[A-Za-z]+,\s*)?(\d{1,2})\s+([A-Za-z]{3})\s+(\d{2,4})\s+'
      r'(\d{1,2}):(\d{2})(?::(\d{2}))?\s*$',
    ).firstMatch(normalized);
    if (d == null) return null;
    const Map<String, int> months = <String, int>{
      'jan': 1,
      'feb': 2,
      'mar': 3,
      'apr': 4,
      'may': 5,
      'jun': 6,
      'jul': 7,
      'aug': 8,
      'sep': 9,
      'oct': 10,
      'nov': 11,
      'dec': 12,
    };
    final int? month = months[d.group(2)!.toLowerCase()];
    if (month == null) return null;
    int year = int.parse(d.group(3)!);
    if (year < 100) year += 2000;
    try {
      final DateTime utc = DateTime.utc(
        year,
        month,
        int.parse(d.group(1)!),
        int.parse(d.group(4)!),
        int.parse(d.group(5)!),
        d.group(6) == null ? 0 : int.parse(d.group(6)!),
      );
      return utc.subtract(Duration(minutes: offsetMinutes));
    } catch (_) {
      return null;
    }
  }
}
