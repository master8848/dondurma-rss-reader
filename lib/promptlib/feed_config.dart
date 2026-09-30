/// Feed registry loader for `.promptlib/feeds.yaml` (WP1).
///
/// Pure-Dart, dependency-free. The registry (feed URL + per-feed type) is
/// the part of feed configuration that syncs through the repo (checked in),
/// while the fetched-item cache stays local-only and git-ignored — enforced
/// by repository layout/consumers, documented here as the contract.
///
/// NOTE (dependency): a future workstream should add `yaml: ^3.1.2` to
/// `pubspec.yaml` and delegate to `package:yaml`. WP1 must not edit
/// `pubspec.yaml`, so a minimal line parser covering exactly the schema
/// below stands in; anything outside it throws [FormatException].
///
/// Expected file shape:
///
/// ```yaml
/// feeds:
///   - url: https://example.com/prompts.xml
///     name: Example Prompts
///     type: prompt
///   - url: https://example.com/blog.xml
///     name: Example Blog
///     type: article
/// ```

import 'dart:io';

/// Per-feed content type (ARCHITECTURE.md section 1 / 3).
///
/// `prompt` feeds materialize into `subscriptions/<feed>/` as prompt
/// Markdown; `article`/`other` feeds stay read-only feed items.
enum FeedType { prompt, article, other }

/// Parses a `type:` string. Throws [FormatException] on unknown values so
/// typos fail loudly instead of silently changing feed behaviour.
FeedType feedTypeFromString(String raw) {
  switch (raw.trim().toLowerCase()) {
    case 'prompt':
      return FeedType.prompt;
    case 'article':
      return FeedType.article;
    case 'other':
      return FeedType.other;
    default:
      throw FormatException(
          'promptlib: unknown feed type "$raw" '
          '(expected prompt|article|other)');
  }
}

/// Serializes a [FeedType] to its `feeds.yaml` string form.
String feedTypeToString(FeedType type) {
  switch (type) {
    case FeedType.prompt:
      return 'prompt';
    case FeedType.article:
      return 'article';
    case FeedType.other:
      return 'other';
  }
}

/// One feed entry: `{url, name, type}`.
class FeedConfigEntry {
  final String url;
  final String name;
  final FeedType type;

  const FeedConfigEntry({
    required this.url,
    required this.name,
    this.type = FeedType.other,
  });

  @override
  String toString() =>
      'FeedConfigEntry(url: $url, name: $name, type: $type)';
}

/// Parsed `.promptlib/feeds.yaml` registry.
class FeedConfig {
  /// Relative path of the registry file inside the library root.
  /// This file is checked in (syncs via repo); the fetched-item cache is
  /// local-only and git-ignored.
  static const String relativePath = '.promptlib/feeds.yaml';

  final List<FeedConfigEntry> feeds;

  const FeedConfig([this.feeds = const []]);

  /// Looks up an entry by feed URL. Returns `null` when unknown.
  FeedConfigEntry? entryForUrl(String url) {
    for (final FeedConfigEntry e in feeds) {
      if (e.url == url) return e;
    }
    return null;
  }

  /// Parses `feeds.yaml` text. Empty/blank text yields an empty config;
  /// structurally invalid text throws [FormatException].
  static FeedConfig parse(String yamlText) {
    if (yamlText.trim().isEmpty) return const FeedConfig();
    final List<String> lines = yamlText.split(RegExp(r'\r?\n'));
    int i = 0;

    // Skip blanks/comments to the `feeds:` header.
    String? nextMeaningful() {
      while (i < lines.length) {
        final String t = lines[i].trim();
        if (t.isEmpty || t.startsWith('#')) {
          i++;
          continue;
        }
        return lines[i];
      }
      return null;
    }

    final String? header = nextMeaningful();
    if (header == null) return const FeedConfig();
    final RegExp headerRe = RegExp(r'^feeds\s*:(.*)$');
    final RegExpMatch? headerMatch = headerRe.firstMatch(header.trim());
    if (headerMatch == null) {
      throw const FormatException(
          'promptlib: feeds.yaml must have a top-level `feeds:` key');
    }
    i++;
    if (headerMatch.group(1)!.trim() == '[]') return const FeedConfig();
    if (headerMatch.group(1)!.trim().isNotEmpty) {
      throw const FormatException(
          'promptlib: feeds.yaml `feeds:` must be followed by a `- ` list');
    }

    final List<FeedConfigEntry> entries = <FeedConfigEntry>[];
    final RegExp itemRe = RegExp(r'^(\s*)-\s*(.*)$');
    final RegExp kvRe = RegExp(r'^([A-Za-z_][A-Za-z0-9_]*)\s*:(.*)$');

    String? line;
    while ((line = nextMeaningful()) != null) {
      final RegExpMatch? itemMatch = itemRe.firstMatch(line!);
      if (itemMatch == null) {
        throw FormatException(
            'promptlib: feeds.yaml expected a `- ` list item, got: "$line"');
      }
      final int itemIndent = itemMatch.group(1)!.length;
      final Map<String, String> fields = <String, String>{};

      void putField(String raw, int lineNo) {
        final RegExpMatch? kv = kvRe.firstMatch(raw.trim());
        if (kv == null) {
          throw FormatException(
              'promptlib: feeds.yaml malformed field on line $lineNo: '
              '"$raw" (expected `key: value`)');
        }
        fields[kv.group(1)!] = _unquote(kv.group(2)!.trim());
      }

      final String firstRest = itemMatch.group(2)!;
      final int firstLineNo = i + 1;
      i++;
      if (firstRest.trim().isNotEmpty) {
        final RegExpMatch? kv = kvRe.firstMatch(firstRest.trim());
        if (kv == null) {
          throw FormatException(
              'promptlib: feeds.yaml malformed field on line $firstLineNo: '
              '"$firstRest"');
        }
        fields[kv.group(1)!] = _unquote(kv.group(2)!.trim());
      }
      // Continuation `key: value` lines must be indented past the `-`.
      while (i < lines.length) {
        final String cont = lines[i];
        final String t = cont.trim();
        if (t.isEmpty || t.startsWith('#')) {
          i++;
          continue;
        }
        final int indent = cont.length - cont.trimLeft().length;
        if (indent <= itemIndent) break;
        if (t.startsWith('- ')) break;
        putField(cont, i + 1);
        i++;
      }

      final String url = (fields['url'] ?? '').trim();
      if (url.isEmpty) {
        throw const FormatException(
            'promptlib: feeds.yaml entry is missing required `url`');
      }
      final String typeRaw = (fields['type'] ?? 'other').trim();
      entries.add(FeedConfigEntry(
        url: _unquote(url),
        name: _unquote((fields['name'] ?? url).trim()),
        type: feedTypeFromString(typeRaw.isEmpty ? 'other' : typeRaw),
      ));
    }
    return FeedConfig(entries);
  }

  /// Loads `<libraryRoot>/.promptlib/feeds.yaml`.
  ///
  /// A missing file yields an empty config (fresh checkout); an unreadable
  /// or malformed file throws ([IOException]/[FormatException]).
  static Future<FeedConfig> load(String libraryRoot) async {
    final File file = File(
      '$libraryRoot/${FeedConfig.relativePath}',
    );
    if (!await file.exists()) return const FeedConfig();
    return FeedConfig.parse(await file.readAsString());
  }
}

String _unquote(String value) {
  String v = value.trim();
  if (v.length >= 2) {
    final String first = v[0];
    final String last = v[v.length - 1];
    if ((first == '"' && last == '"') ||
        (first == "'" && last == "'")) {
      v = v.substring(1, v.length - 1);
    }
  }
  return v;
}
