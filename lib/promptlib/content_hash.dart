/// Content hashing for sync comparison (leaf module, no cycles).
///
/// Pure-Dart, no Flutter. Imported by both `prompt_store.dart` (mirror-write
/// hook) and `version_ux.dart` (tri-state determination) so the two agree on
/// what "same content" means without an import cycle.
library;

import 'dart:convert';

import 'prompt_doc.dart';

/// FNV-1a 64-bit hex over UTF-8 bytes (dependency-free stable content hash;
/// same construction as `FeedEngine` fallback ids).
String contentHash(String text) {
  int hash = 0xcbf29ce484222325;
  for (final int byte in utf8.encode(text)) {
    hash ^= byte;
    hash = (hash * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
  }
  return hash.toRadixString(16).padLeft(16, '0');
}

/// Canonical content hash of a prompt doc for sync comparison.
///
/// Covers `id` + `title` + `tags` + `body` only: `version`, `created`, and
/// `updated` are deliberately excluded so a bare re-save or a refresh that
/// re-stamps timestamps without changing words still compares equal (the old
/// mirror code rewrote files with `updated: now` on every refresh — mtime
/// churn that must never read as "newer").
String syncHash(PromptDoc doc) => contentHash(
      '${doc.id}\n${doc.title}\n${doc.tags.join('\x1f')}\n${doc.body}',
    );
