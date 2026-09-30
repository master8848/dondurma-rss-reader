/// Offline-location marking for saved articles (promptlib, pure-Dart).
///
/// An offline item keeps its identity as article-or-prompt; offline is a
/// location state, not a type: the doc's file lives under
/// `<root>/subscriptions/` (written by
/// `PromptStore.materializeSubscribedItem`, folder routed by the feed engine).
/// Rows show a minimal inline marker for such files (see [showOfflineMarker])
/// and edits save back to the same path so git sync picks them up.
///
/// Pure-Dart (no Flutter) so it stays unit-testable with plain `dart test`,
/// like everything else under `lib/promptlib/`.
library;

import 'prompt_store.dart';

/// True when [path] is a file under `<root>/subscriptions/`.
///
/// Case-insensitive prefix match on canonicalized separators, mirroring how
/// the store lays out subscription mirrors. `null`, blank, or out-of-root
/// paths return `false` — never throws for bad data.
bool isOfflineFilePath(String? path, String root) {
  if (path == null || path.trim().isEmpty) return false;
  if (root.trim().isEmpty) return false;
  String norm(String s) => s.replaceAll('\\', '/').toLowerCase();
  String strip(String s) {
    while (s.endsWith('/') && s.length > 1) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  final String dir =
      '${strip(norm(root))}/${PromptStore.subscriptionsDirName}/';
  return norm(path).startsWith(dir);
}

/// Badge visibility rule for the offline marker: a VERY SMALL inline icon
/// (e.g. tiny 12-14px `Icons.offline_pin` in the row's existing
/// trailing/meta area) ONLY when the item is offline; NOTHING at all when
/// not offline — no badge, no chip, no banner.
bool showOfflineMarker({required bool isOffline}) => isOffline;
