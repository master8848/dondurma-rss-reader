/// Front-matter parser/serializer for prompt Markdown files (WP1 + repomap).
///
/// Pure-Dart, dependency-free: this is a minimal YAML-subset parser covering
/// exactly the promptlib schema (`id`, `title`, `tags`, `source_feed`,
/// `created`, `updated`, `version`, `supersedes`). Supported value shapes:
/// bare scalars, single/double-quoted scalars, flow lists (`tags: [a, b]`),
/// and block lists (`tags:\n  - a\n  - b`).
///
/// NOTE (dependency): for full YAML (multiline strings, anchors, nested
/// maps) a future workstream should add `yaml: ^3.1.2` to `pubspec.yaml`
/// and delegate to `package:yaml`. WP1 must not edit `pubspec.yaml`, so the
/// subset parser stands in. Anything outside the subset throws
/// [FormatException] instead of mis-parsing.
///
/// Contract:
/// * [parse] never crashes on *any* string input — malformed front matter
///   throws [FormatException]; unexpected internal failures are wrapped in
///   [FormatException] too.
/// * A missing/blank `id` is not an error: a UUID is generated and the
///   resulting doc is flagged with `needsReview: true` (REVIEW).

import 'prompt_doc.dart';

/// Parses a full prompt Markdown document (`---` front matter + body).
///
/// Throws [FormatException] when the delimiters are missing/unclosed, a
/// front-matter line is not `key: value`, or a non-empty date does not
/// parse. Never throws anything else.
PromptDoc parse(String markdown) {
  try {
    return _parseInner(markdown);
  } on FormatException {
    rethrow;
  } catch (e) {
    throw FormatException('promptlib: unable to parse prompt markdown: $e');
  }
}

/// Serializes [doc] to `---` front matter + body.
///
/// The output round-trips exactly through [parse]: the body is written
/// verbatim (no forced trailing newline), so
/// `parse(serialize(doc)).body == doc.body` for every [doc].
String serialize(PromptDoc doc) {
  final StringBuffer buf = StringBuffer();
  buf.writeln('---');
  buf.writeln('id: ${_yamlScalar(doc.id)}');
  buf.writeln('title: ${_yamlScalar(doc.title)}');
  if (doc.tags.isEmpty) {
    buf.writeln('tags: []');
  } else {
    buf.writeln('tags: [${doc.tags.map(_yamlScalar).join(', ')}]');
  }
  if (doc.sourceFeed != null) {
    buf.writeln('source_feed: ${_yamlScalar(doc.sourceFeed!)}');
  }
  if (doc.created != null) {
    buf.writeln('created: ${doc.created!.toUtc().toIso8601String()}');
  }
  if (doc.updated != null) {
    buf.writeln('updated: ${doc.updated!.toUtc().toIso8601String()}');
  }
  // Version is always written so snapshots and edits round-trip exactly;
  // legacy files without it parse back as version 1.
  buf.writeln('version: ${doc.version}');
  // `supersedes` is absent unless this file is an optimize snapshot.
  if (doc.supersedes != null && doc.supersedes!.trim().isNotEmpty) {
    buf.writeln('supersedes: ${_yamlScalar(doc.supersedes!)}');
  }
  buf.writeln('---');
  buf.write(doc.body);
  return buf.toString();
}

PromptDoc _parseInner(String markdown) {
  final List<String> lines = markdown.split(RegExp(r'\r?\n'));
  if (lines.isEmpty || lines.first.trim() != '---') {
    throw const FormatException(
        'promptlib: missing opening front-matter delimiter (---)');
  }
  int closing = -1;
  for (int i = 1; i < lines.length; i++) {
    final String t = lines[i].trim();
    if (t == '---' || t == '...') {
      closing = i;
      break;
    }
  }
  if (closing == -1) {
    throw const FormatException(
        'promptlib: missing closing front-matter delimiter (---)');
  }
  final Map<String, Object> fm = _parseYamlSubset(
    lines.sublist(1, closing),
  );
  final String body = lines.sublist(closing + 1).join('\n');

  bool needsReview = false;
  String id = _asString(fm['id']).trim();
  if (id.isEmpty) {
    id = generateUuidV4();
    needsReview = true;
  }
  final String title = _asString(fm['title'], fallback: 'Untitled');
  final List<String> tags = _asStringList(fm['tags']);
  final String rawSource = _asString(fm['source_feed']).trim();
  final String? sourceFeed = rawSource.isEmpty ? null : rawSource;
  final DateTime? created = _asDate(fm['created'], 'created');
  final DateTime? updated = _asDate(fm['updated'], 'updated');
  // `version` defaults to 1 for legacy files; unknown keys are ignored
  // (they stay in `fm` but are never read — forward compatibility).
  final int version = _asVersion(fm['version']);
  final String rawSupersedes = _asString(fm['supersedes']).trim();
  final String? supersedes =
      rawSupersedes.isEmpty ? null : rawSupersedes;

  return PromptDoc(
    id: id,
    title: title.isEmpty ? 'Untitled' : title,
    tags: tags,
    sourceFeed: sourceFeed,
    created: created,
    updated: updated,
    body: body,
    needsReview: needsReview,
    version: version,
    supersedes: supersedes,
  );
}

/// Minimal block parser for the promptlib front-matter subset.
///
/// Unknown keys are ignored (forward compatibility). Duplicate keys take
/// the last value, matching YAML merge behaviour.
Map<String, Object> _parseYamlSubset(List<String> lines) {
  final Map<String, Object> out = <String, Object>{};
  final RegExp keyRe = RegExp(r'^([A-Za-z_][A-Za-z0-9_]*)\s*:(.*)$');
  int i = 0;
  while (i < lines.length) {
    final String raw = lines[i];
    final String trimmed = raw.trim();
    i++;
    if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
    final RegExpMatch? m = keyRe.firstMatch(raw);
    if (m == null) {
      throw FormatException(
          'promptlib: malformed front-matter line $i: "$raw" '
          '(expected `key: value`)');
    }
    final String key = m.group(1)!;
    final String value = m.group(2)!.trim();
    if (value.isEmpty) {
      // Possibly a block list (`key:` followed by `- item` lines).
      final List<String> items = <String>[];
      while (i < lines.length) {
        final String t = lines[i].trim();
        if (t.isEmpty || t.startsWith('#')) {
          i++;
          continue;
        }
        if (t.startsWith('- ')) {
          items.add(_unquote(t.substring(2).trim()));
          i++;
        } else if (t == '-') {
          items.add('');
          i++;
        } else {
          break;
        }
      }
      out[key] = items;
    } else if (value.startsWith('[')) {
      if (!value.endsWith(']')) {
        throw FormatException(
            'promptlib: malformed flow list on line $i: "$raw" '
            '(missing closing `]`)');
      }
      final String inner = value.substring(1, value.length - 1).trim();
      out[key] = inner.isEmpty
          ? <String>[]
          : inner.split(',').map((String e) => _unquote(e.trim())).toList();
    } else {
      out[key] = _unquote(value);
    }
  }
  return out;
}

String _unquote(String value) {
  if (value.length >= 2) {
    final String first = value[0];
    final String last = value[value.length - 1];
    if ((first == '"' && last == '"') ||
        (first == "'" && last == "'")) {
      final String inner = value.substring(1, value.length - 1);
      if (first == "'") return inner; // single-quoted: literal
      // Double-quoted: unescape \\ first via placeholder, then \" and \n.
      const String placeholder = '\u0000';
      return inner
          .replaceAll(r'\\', placeholder)
          .replaceAll(r'\"', '"')
          .replaceAll(r'\n', '\n')
          .replaceAll(placeholder, r'\');
    }
  }
  return value;
}

String _asString(Object? value, {String fallback = ''}) {
  if (value == null) return fallback;
  if (value is String) return value;
  if (value is List<String> && value.isNotEmpty) return value.first;
  return fallback;
}

List<String> _asStringList(Object? value) {
  if (value == null) return <String>[];
  if (value is List<String>) {
    return value.where((String e) => e.isNotEmpty).toList();
  }
  if (value is String) {
    final String t = value.trim();
    return t.isEmpty ? <String>[] : <String>[t];
  }
  return <String>[];
}

/// Parses the `version` front-matter value. Absent/blank defaults to 1
/// (legacy files predate versioning). Anything that is not a positive
/// integer throws [FormatException] so the store skips the file via
/// `skippedFiles` instead of silently resetting history.
int _asVersion(Object? value) {
  if (value == null) return 1;
  if (value is List<String>) {
    throw const FormatException(
        'promptlib: front-matter `version` must be a single integer, '
        'not a list');
  }
  final String raw = (value as String).trim();
  if (raw.isEmpty) return 1;
  final String unquoted = _unquote(raw);
  final int? parsed = int.tryParse(unquoted);
  if (parsed == null || parsed < 1) {
    throw FormatException(
        'promptlib: front-matter `version` must be a positive integer, '
        'got "$raw"');
  }
  return parsed;
}

DateTime? _asDate(Object? value, String field) {  if (value == null) return null;
  if (value is List<String>) {
    throw FormatException(
        'promptlib: front-matter `$field` must be a single date, '
        'not a list');
  }
  final String raw = (value as String).trim();
  if (raw.isEmpty) return null;
  final DateTime? parsed = DateTime.tryParse(raw);
  if (parsed == null) {
    throw FormatException(
        'promptlib: front-matter `$field` is not a valid date: "$raw" '
        '(expected ISO 8601)');
  }
  return parsed;
}

/// Renders a scalar for YAML output: bare when it is unambiguous,
/// double-quoted otherwise. Round-trips through [_unquote].
String _yamlScalar(String value) {
  if (value.isEmpty) return '""';
  final bool simple = RegExp(r'^[A-Za-z0-9_][A-Za-z0-9 _.\-/]*$')
          .hasMatch(value) &&
      !_looksLikeYamlKeyword(value);
  if (simple) return value;
  final String escaped =
      value.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
  return '"$escaped"';
}

bool _looksLikeYamlKeyword(String value) {
  final String lower = value.toLowerCase();
  if (lower == 'null' ||
      lower == 'true' ||
      lower == 'false' ||
      lower == 'yes' ||
      lower == 'no') {
    return true;
  }
  return double.tryParse(value) != null;
}
