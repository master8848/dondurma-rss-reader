import '../../models/skill.dart';

/// Pure-Dart helpers shared by the skills data layer and unit tests.
///
/// Kept Flutter-free so `test/skills/*` and the `dart run` smoke script can
/// exercise them without the Flutter SDK.
class SkillListUtils {
  const SkillListUtils._();

  /// MRU insert with cap (same pattern as `SettingsProvider.addSearchQuery`).
  ///
  /// Trims whitespace, ignores empty strings, moves existing duplicates to
  /// the front, and caps the list at [cap] entries (most-recent-first).
  /// Returns a NEW list; the input is never mutated.
  static List<String> mruInsert(List<String> history, String query, [int cap = 10]) {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return List<String>.from(history);
    final next = List<String>.from(history)..remove(trimmed);
    next.insert(0, trimmed);
    if (next.length > cap) return next.sublist(0, cap);
    return next;
  }

  /// Merges per-catalog result lists, deduping by [Skill.id] (first catalog
  /// wins) and capping the total at [limit].
  ///
  /// Catalog priority order follows the argument order: pass ClawHub results
  /// first so they win on id collisions.
  static List<Skill> mergeDedupe(List<List<Skill>> sources, [int limit = 50]) {
    final seen = <String>{};
    final merged = <Skill>[];
    for (final source in sources) {
      for (final skill in source) {
        if (skill.id.isEmpty || !seen.add(skill.id)) continue;
        merged.add(skill);
        if (merged.length >= limit) return merged;
      }
    }
    return merged;
  }

  /// Derives the 8-hex cache-key suffix from `host/owner/repo/ref`.
  ///
  /// Uses FNV-1a 32-bit over the UTF-8 bytes (dependency-free stand-in for a
  /// truncated SHA; documented in `skills_cache_service.dart`). The same
  /// function backs the on-disk layout so tests pin the derivation.
  static String hash8(String input) {
    var hash = 0x811c9dc5;
    for (var i = 0; i < input.length; i++) {
      hash ^= input.codeUnitAt(i);
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  /// Full mskill-style cache key: `<ref>--<hash8(host/owner/repo/ref)>`.
  static String repoCacheKey({
    required String host,
    required String owner,
    required String repo,
    required String ref,
  }) {
    final safeRef = ref.isEmpty ? 'HEAD' : ref;
    return '$safeRef--${hash8('$host/$owner/$repo/$safeRef')}';
  }
}

/// Parses the YAML frontmatter of a `SKILL.md` document.
///
/// Returns a map with lowercase string keys (`name`, `description`,
/// `version`, …). Only simple `key: value` scalar lines are parsed —
/// quoted or unquoted, `#` comments and `---` delimiters are skipped. This is
/// deliberately a tiny subset of YAML: SKILL.md frontmatter is flat
/// (`name`/`description`/`version`), and a full YAML dependency would break
/// the plain-`dart` (no `pub get`) test story.
///
/// Returns an empty map when the document has no frontmatter block.
Map<String, String> parseSkillFrontmatter(String markdown) {
  final lines = markdown.split('\n');
  if (lines.isEmpty || lines.first.trim() != '---') return const {};

  var end = -1;
  for (var i = 1; i < lines.length; i++) {
    if (lines[i].trim() == '---') {
      end = i;
      break;
    }
  }
  if (end <= 1) return const {};

  final out = <String, String>{};
  for (var i = 1; i < end; i++) {
    var line = lines[i];
    final comment = line.indexOf('#');
    // Strip trailing `#` comments outside quotes (best-effort).
    if (comment >= 0 && !_isInsideQuotes(line, comment)) {
      line = line.substring(0, comment);
    }
    final colon = line.indexOf(':');
    if (colon <= 0) continue;
    final key = line.substring(0, colon).trim().toLowerCase();
    var value = line.substring(colon + 1).trim();
    if (key.isEmpty || value.isEmpty) continue;
    if (value.length >= 2 &&
        ((value.startsWith('"') && value.endsWith('"')) ||
            (value.startsWith("'") && value.endsWith("'")))) {
      value = value.substring(1, value.length - 1);
    }
    out[key] = value;
  }
  return out;
}

bool _isInsideQuotes(String line, int index) {
  var inSingle = false;
  var inDouble = false;
  for (var i = 0; i < index; i++) {
    final c = line[i];
    if (c == "'" && !inDouble) inSingle = !inSingle;
    if (c == '"' && !inSingle) inDouble = !inDouble;
  }
  return inSingle || inDouble;
}
