/// `PromptDoc` — the core value object of the promptlib library (WP1).
///
/// Pure-Dart: this file, like everything under `lib/promptlib/`, must never
/// import `package:flutter/*` so the core can be unit-tested with plain
/// `dart test` once a Dart SDK is available.
///
/// ID conventions follow the existing Dondurma `FeedItem` approach
/// (`lib/models/feed_item.dart`, read-only reference): [id] is an opaque,
/// stable string that is **never derived from the title**, so renames never
/// break links, history, or sync. Equality and hashCode are by [id] only,
/// matching `FeedItem.==`.

import 'dart:math';

/// A single prompt: YAML front-matter metadata plus a Markdown [body].
///
/// Front-matter keys (see `front_matter.dart`): `id`, `title`, `tags`,
/// `source_feed`, `created`, `updated`.
class PromptDoc {
  /// Stable identifier. Never derived from [title].
  final String id;

  /// Display title. Renames do not change [id] or the file's git history
  /// (the store keeps the existing path on rename).
  final String title;

  /// Free-form tags, e.g. `['coding', 'review']`.
  final List<String> tags;

  /// Feed this prompt came from (subscription slug or URL), or `null` for
  /// prompts authored locally. Preserved across fork-on-edit so a library
  /// copy stays linked to its origin.
  final String? sourceFeed;

  final DateTime? created;
  final DateTime? updated;

  /// Markdown body (everything below the front matter).
  final String body;

  /// True when the doc was recovered (e.g. missing `id` on parse generated
  /// a fresh UUID). UI layers should surface these for review.
  final bool needsReview;

  const PromptDoc({
    required this.id,
    required this.title,
    this.tags = const [],
    this.sourceFeed,
    this.created,
    this.updated,
    this.body = '',
    this.needsReview = false,
  });

  PromptDoc copyWith({
    String? id,
    String? title,
    List<String>? tags,
    String? Function()? sourceFeed,
    DateTime? Function()? created,
    DateTime? Function()? updated,
    String? body,
    bool? needsReview,
  }) {
    return PromptDoc(
      id: id ?? this.id,
      title: title ?? this.title,
      tags: tags ?? List<String>.from(this.tags),
      sourceFeed: sourceFeed != null ? sourceFeed() : this.sourceFeed,
      created: created != null ? created() : this.created,
      updated: updated != null ? updated() : this.updated,
      body: body ?? this.body,
      needsReview: needsReview ?? this.needsReview,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is PromptDoc && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() =>
      'PromptDoc(id: $id, title: $title, tags: $tags, '
      'sourceFeed: $sourceFeed, needsReview: $needsReview)';
}

/// Generates an RFC 4122 version-4 UUID.
///
/// Implemented locally (no `uuid` package dependency) so WP1 stays
/// dependency-free; `pubspec.yaml` is intentionally untouched.
String generateUuidV4() {
  final Random random = Random.secure();
  final List<int> bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
  bytes[8] = (bytes[8] & 0x3f) | 0x80; // RFC 4122 variant
  String hex(int b) => b.toRadixString(16).padLeft(2, '0');
  final String h = bytes.map(hex).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-'
      '${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20, 32)}';
}

/// Converts a title into a safe `<slug>.md` filename stem.
///
/// Safe against weird filenames (unicode, spaces, path separators):
/// unicode letters/digits are preserved (the OS handles them), whitespace
/// runs become `-`, path separators / control characters / Windows-hostile
/// characters (`\ ? % * : | " < >`) are stripped, and leading dots/dashes
/// (hidden files, CLI-flag confusion) are removed. Never returns empty —
/// falls back to `'untitled'`.
String slugifyTitle(String title, {int maxLength = 80}) {
  String slug = title.trim().toLowerCase().replaceAll(RegExp(r'\s+'), '-');
  // ignore: no-magic-number (character-class ranges, not logic)
  slug = slug.replaceAll(RegExp(r'[\x00-\x1f\x7f/\\?%*:|"<>]'), '');
  slug = slug.replaceAll(RegExp(r'-{2,}'), '-');
  slug = slug.replaceAll(RegExp(r'^[.\-]+'), '');
  slug = slug.replaceAll(RegExp(r'[.\-]+$'), '');
  if (slug.length > maxLength) {
    slug = slug.substring(0, maxLength).replaceAll(RegExp(r'[.\-]+$'), '');
  }
  if (slug.isEmpty) return 'untitled';
  return slug;
}
