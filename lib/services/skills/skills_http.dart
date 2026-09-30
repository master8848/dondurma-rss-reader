import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Minimal injectable HTTP abstraction for the skills data layer.
///
/// NOTE (spec deviation): the spec asks for an injected `http.Client` from
/// `package:http`. That package cannot be resolved in environments without a
/// working `pub get` (this repo's `pubspec` requires the Flutter SDK for
/// `flutter_test`, so plain-`dart` environments cannot fetch dependencies).
/// To keep the entire skills data layer runnable/testable with plain `dart`,
/// only `dart:` libraries are used here. [SkillsHttpClient] has the same
/// injectable shape (`get` returning status + body) so swapping in
/// `package:http` later is a mechanical change. Tests inject
/// [FakeSkillsHttpClient].
abstract class SkillsHttpClient {
  Future<SkillsHttpResponse> get(Uri url, {Duration timeout});
}

/// Simple status + body response.
class SkillsHttpResponse {
  final int statusCode;
  final String body;

  const SkillsHttpResponse(this.statusCode, this.body);

  /// Decodes [body] as JSON. Throws [FormatException] on invalid JSON.
  dynamic json() => jsonDecode(body);
}

/// Default implementation backed by `dart:io` [HttpClient].
///
/// Best-effort reads: callers are expected to set ~10s timeouts and swallow
/// failures per source.
class IoSkillsHttpClient implements SkillsHttpClient {
  final HttpClient _inner;

  IoSkillsHttpClient({HttpClient? inner}) : _inner = inner ?? HttpClient();

  @override
  Future<SkillsHttpResponse> get(Uri url, {Duration timeout = const Duration(seconds: 10)}) async {
    final request = await _inner.getUrl(url).timeout(timeout);
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    request.headers.set(
      HttpHeaders.userAgentHeader,
      'dondurma-rss-reader/skills (+https://github.com/master8848/dondurma-rss-reader)',
    );
    final response = await request.close().timeout(timeout);
    final body = await response.transform(utf8.decoder).join().timeout(timeout);
    return SkillsHttpResponse(response.statusCode, body);
  }

  void close() => _inner.close(force: true);
}

/// In-memory fake for tests: maps exact URLs (or path prefixes) to canned
/// responses, or throws for unmapped URLs.
class FakeSkillsHttpClient implements SkillsHttpClient {
  final Map<String, SkillsHttpResponse> responses;
  final List<Uri> requested = [];

  FakeSkillsHttpClient(this.responses);

  @override
  Future<SkillsHttpResponse> get(Uri url, {Duration timeout = const Duration(seconds: 10)}) async {
    requested.add(url);
    final exact = responses[url.toString()];
    if (exact != null) return exact;
    throw HttpException('No canned response for $url');
  }
}
