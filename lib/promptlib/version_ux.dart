/// Local-vs-remote version comparison UX (tri-state sync).
///
/// Pure-Dart, no Flutter: like everything under `lib/promptlib/`, this file
/// stays unit-testable with plain `dart test`.
///
/// What this solves: until now the codebase had **no** "website newer vs our
/// local changes newer" signal anywhere:
///
/// * subscribed prompt mirrors (`PromptStore.materializeSubscribedItem`)
///   rewrote the mirror file on every refresh with `version` reset to 1 and
///   `updated` stamped to now — even when the fetched body was byte-identical
///   (mtime churn, no content-hash compare, per-item feed `pubDate` parsed
///   but never compared);
/// * a fork-on-edit library copy kept its `source_feed` link but recorded no
///   baseline of what the mirror looked like at fork time, so later upstream
///   refreshes silently moved the mirror while the UI kept showing the
///   library copy with no "update available" hint;
/// * `RestoreRunner.syncAll` only reports repo-level `fetch` + `pull
///   --ff-only` outcomes and conflict paths — never per-item newer/older;
/// * saved skills persist only the catalog [Skill] JSON in Hive (a free-form
///   `version` string, often empty; no local SHA, no remote HEAD, no content
///   hash). The `.mskill-meta.json` pin record (`commitSha`, `lastFetch`)
///   existed on disk but nothing ever read it for comparison, and nothing
///   ever fetched remote HEAD — `ensure(update: true)` jumps straight to a
///   destructive `fetch` + `reset --hard`.
///
/// This file provides the shared tri-state used by both surfaces
/// (subscribed prompts via [PromptSyncTracker], saved skills via
/// `SkillsProvider.checkSkillState`):
///
/// * [ItemSyncState.inSync] — "Up to date".
/// * [ItemSyncState.localNewer] — "Edited here" (local content moved on from
///   the last-seen remote state).
/// * [ItemSyncState.remoteNewer] — "Update available" (remote moved on from
///   the last-seen local state).
/// * [ItemSyncState.unknown] — "Not checked yet" (offline / never fetched /
///   nothing to compare; never blocks UI).
///
/// Comparison is by content hash ([syncHash]/[contentHash]) or commit SHA —
/// never by mtime — with a persisted baseline ([BaselineJournal]) recording
/// the last state both sides agreed on. Remote checks are best-effort and
/// cached ([PromptSyncTracker] TTL); failures degrade to [unknown].
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'content_hash.dart';
export 'content_hash.dart' show contentHash, syncHash;
import 'feed_config.dart';
import 'feed_engine.dart';
import 'front_matter.dart' as fm;
import 'prompt_doc.dart';
import 'prompt_store.dart';

/// Per-item local-vs-remote state. Labels are plain words on purpose — no
/// "HEAD", "diverged", or "fast-forward" jargon reaches the UI (see
/// [SyncStateLabels]).
enum ItemSyncState {
  /// Local and remote agree.
  inSync,

  /// Local content moved on from the last-seen remote state.
  localNewer,

  /// Remote moved on from the last-seen local state.
  remoteNewer,

  /// Nothing to compare (offline / never fetched / missing side).
  unknown,
}

/// Plain-language UI strings for [ItemSyncState] (no technical jargon).
extension SyncStateLabels on ItemSyncState {
  /// Short badge text, e.g. "Up to date".
  String get label => switch (this) {
        ItemSyncState.inSync => 'Up to date',
        ItemSyncState.localNewer => 'Edited here',
        ItemSyncState.remoteNewer => 'Update available',
        ItemSyncState.unknown => 'Not checked yet',
      };

  /// One-line explanation shown under the badge in detail views.
  String get detail => switch (this) {
        ItemSyncState.inSync => 'This copy matches the latest check.',
        ItemSyncState.localNewer =>
          'You changed this copy after it was last in step with the source.',
        ItemSyncState.remoteNewer =>
          'The source has something new since you last looked.',
        ItemSyncState.unknown =>
          'Could not compare right now — showing your saved copy.',
      };
}

/// Decides the tri-state from content hashes (or commit SHAs — any opaque
/// per-content token works) plus optional timestamps for tie-breaking.
///
/// * [localHash]: hash of the user's copy (`null` = no local copy / unread).
/// * [baseHash]: hash both sides agreed on at the last check/fork/ack
///   (`null` = never observed; first sight seeds it, see [PromptSyncTracker]).
/// * [remoteHash]: hash of the remote/cached-remote side (`null` = offline or
///   never fetched — degrades gracefully, never throws).
/// * [localUpdated]/[remoteUpdated]: tie-break only when **both** sides moved
///   on from [baseHash] (or there is no baseline and the hashes differ):
///   strictly-newer remote wins [ItemSyncState.remoteNewer], otherwise
///   [ItemSyncState.localNewer] (local work is never talked over on a tie).
ItemSyncState determineSyncState({
  String? localHash,
  String? baseHash,
  String? remoteHash,
  DateTime? localUpdated,
  DateTime? remoteUpdated,
}) {
  // No local copy to speak for: nothing to badge.
  if (localHash == null || localHash.isEmpty) return ItemSyncState.unknown;
  // Exact agreement is in-sync even without a baseline.
  if (localHash == remoteHash) return ItemSyncState.inSync;
  // Offline / never fetched: only an un-acked local edit is knowable.
  if (remoteHash == null || remoteHash.isEmpty) {
    if (baseHash != null && baseHash.isNotEmpty && localHash != baseHash) {
      return ItemSyncState.localNewer;
    }
    return ItemSyncState.unknown;
  }
  if (baseHash == null || baseHash.isEmpty) {
    // No baseline and the sides differ: newer timestamp wins, defaulting to
    // local (protect local work when dates are missing or tied).
    if (remoteUpdated != null &&
        (localUpdated == null || remoteUpdated.isAfter(localUpdated))) {
      return ItemSyncState.remoteNewer;
    }
    return ItemSyncState.localNewer;
  }
  final bool localMoved = localHash != baseHash;
  final bool remoteMoved = remoteHash != baseHash;
  if (localMoved && !remoteMoved) return ItemSyncState.localNewer;
  if (remoteMoved && !localMoved) return ItemSyncState.remoteNewer;
  if (!localMoved && !remoteMoved) return ItemSyncState.inSync;
  // Both moved: strictly-newer remote wins, else local.
  if (remoteUpdated != null &&
      (localUpdated == null || remoteUpdated.isAfter(localUpdated))) {
    return ItemSyncState.remoteNewer;
  }
  return ItemSyncState.localNewer;
}

/// File-backed `id -> {base, remote, checkedAt}` journal recording the last
/// state both sides agreed on. Best-effort persistence: a missing or corrupt
/// file starts empty, and save failures never throw.
class BaselineJournal {
  final String filePath;
  final Map<String, _Baseline> _entries = <String, _Baseline>{};

  BaselineJournal(this.filePath);

  /// Loads the journal at [filePath] (missing/corrupt → empty).
  static Future<BaselineJournal> load(String filePath) async {
    final BaselineJournal journal = BaselineJournal(filePath);
    try {
      final File file = File(filePath);
      if (await file.exists()) {
        final Map<String, dynamic> raw =
            jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        raw.forEach((String id, dynamic value) {
          if (value is Map) {
            final String base = value['base']?.toString() ?? '';
            if (base.isNotEmpty) {
              journal._entries[id] = _Baseline(
                baseHash: base,
                remoteHash: value['remote']?.toString() ?? '',
                checkedAt: DateTime.tryParse(
                        value['checkedAt']?.toString() ?? '') ??
                    DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
              );
            }
          }
        });
      }
    } catch (_) {
      // Start empty; a bad journal must never break version checks.
    }
    return journal;
  }

  String? baseFor(String id) => _entries[id]?.baseHash;
  String? remoteFor(String id) => _entries[id]?.remoteHash;
  DateTime? checkedAtFor(String id) => _entries[id]?.checkedAt;

  /// Records that both sides agreed on [baseHash] for [id] (with the latest
  /// seen [remoteHash] for diagnostics). Persists best-effort.
  Future<void> recordAgreed(
    String id, {
    required String baseHash,
    String remoteHash = '',
  }) async {
    _entries[id] = _Baseline(
      baseHash: baseHash,
      remoteHash: remoteHash.isEmpty ? baseHash : remoteHash,
      checkedAt: DateTime.now().toUtc(),
    );
    await save();
  }

  /// Notes a feed-side mirror write for [id] (called via the store's
  /// mirror-write hook, i.e. only for real fetches — never for local
  /// `saveInPlace` edits, which is exactly what lets the tracker tell "the
  /// source moved" apart from "you edited the offline copy").
  ///
  /// Updates the recorded remote hash without moving the baseline, so a
  /// forked-then-edited copy reads "Update available" after the next fetch
  /// instead of silently agreeing. When [id] was never seen, the write also
  /// seeds the baseline (first sight = agreed state).
  Future<void> noteRemote(String id, String remoteHash) async {
    final _Baseline? prev = _entries[id];
    _entries[id] = _Baseline(
      baseHash: prev?.baseHash ?? remoteHash,
      remoteHash: remoteHash,
      checkedAt: DateTime.now().toUtc(),
    );
    await save();
  }

  /// Best-effort persist; never throws.
  Future<void> save() async {
    try {
      final File file = File(filePath);
      await file.parent.create(recursive: true);
      final Map<String, dynamic> raw = <String, dynamic>{
        for (final MapEntry<String, _Baseline> e in _entries.entries)
          e.key: <String, dynamic>{
            'base': e.value.baseHash,
            'remote': e.value.remoteHash,
            'checkedAt': e.value.checkedAt.toIso8601String(),
          },
      };
      await file.writeAsString(jsonEncode(raw));
    } catch (_) {
      // Version checks must work even when the journal cannot persist.
    }
  }
}

class _Baseline {
  final String baseHash;
  final String remoteHash;
  final DateTime checkedAt;

  const _Baseline({
    required this.baseHash,
    required this.remoteHash,
    required this.checkedAt,
  });
}

/// One tri-state verdict for a subscribed prompt plus the docs behind it.
class PromptSyncSnapshot {
  final String id;
  final ItemSyncState state;

  /// The user's copy (`library/` wins, else `prompts/<category>/`).
  final PromptDoc? local;

  /// The subscription mirror (`subscriptions/<feed>/`), i.e. the last
  /// fetched remote state.
  final PromptDoc? remote;
  final String? localHash;
  final String? baseHash;
  final String? remoteHash;

  const PromptSyncSnapshot({
    required this.id,
    required this.state,
    this.local,
    this.remote,
    this.localHash,
    this.baseHash,
    this.remoteHash,
  });
}

/// Tri-state sync checks over a [PromptStore], backed by content hashes.
///
/// * remote side = the `subscriptions/<feed>/` mirror (last fetched state);
///   fresh fetches go through the optional [FeedEngine] best-effort.
/// * local side = the `library/` fork (else `prompts/<category>/` copy).
/// * baseline = [BaselineJournal], seeded on first sight (first check records
///   the mirror hash as the agreed state, so pre-existing forks show
///   "Edited here" rather than a bogus "Update available").
/// * verdicts are memoized for [checkTtl] (default 15 min) so list rows stay
///   cheap; pass `force: true` (or [refreshAndCheck]) after a fetch/update.
class PromptSyncTracker {
  final PromptStore store;
  final BaselineJournal journal;
  final FeedEngine? engine;

  /// How long a verdict is reused without recomparing. Remote *fetches* only
  /// happen via [refreshAndCheck]; plain [check] never touches the network.
  final Duration checkTtl;

  final Map<String, ({PromptSyncSnapshot snap, DateTime at})> _memo =
      <String, ({PromptSyncSnapshot snap, DateTime at})>{};

  PromptSyncTracker({
    required this.store,
    required this.journal,
    this.engine,
    this.checkTtl = const Duration(minutes: 15),
  }) {
    // Feed-side mirror writes move the recorded remote hash (and drop the
    // memoized verdict). Local `saveInPlace` edits deliberately bypass this
    // hook — that asymmetry is what separates "the source moved" from "you
    // edited the offline copy".
    store.onMirrorWrite = (String id, String hash) {
      _memo.remove(id);
      unawaited(journal.noteRemote(id, hash));
    };
  }

  /// Computes (or returns the memoized) tri-state for [id].
  Future<PromptSyncSnapshot> check(String id, {bool force = false}) async {
    final ({PromptSyncSnapshot snap, DateTime at})? cached = _memo[id];
    if (!force &&
        cached != null &&
        DateTime.now().toUtc().difference(cached.at) < checkTtl) {
      return cached.snap;
    }
    final PromptSyncSnapshot snap = await _compute(id);
    _memo[id] = (snap: snap, at: DateTime.now().toUtc());
    return snap;
  }

  /// Best-effort fresh fetch of the source feed, then a forced re-check.
  /// Never throws: offline/broken feeds keep serving the cached mirror and
  /// the verdict degrades to whatever the mirror supports.
  Future<PromptSyncSnapshot> refreshAndCheck(String id) async {
    final bool fetched = await _refreshSource(id);
    if (fetched) {
      _memo.remove(id);
    }
    return check(id, force: fetched);
  }

  /// Takes the remote side: overwrites the library copy with the mirror
  /// content (a normal version-bumping save, so history is preserved) and
  /// re-baselines to the remote hash. Returns the saved doc, or `null` when
  /// there is no mirror to take.
  Future<PromptDoc?> takeUpdate(String id) async {
    final PromptSyncSnapshot snap = await check(id, force: true);
    final PromptDoc? remote = snap.remote;
    if (remote == null) return null;
    final PromptDoc saved = await store.save(
      remote.copyWith(updated: () => DateTime.now().toUtc()),
    );
    await journal.recordAgreed(
      id,
      baseHash: syncHash(saved),
      remoteHash: syncHash(remote),
    );
    _memo.remove(id);
    return saved;
  }

  /// Keeps the local side: the local copy becomes the agreed state, so the
  /// badge clears until the source actually moves again (a later fetch
  /// writes a new remote hash, which flags "Update available" afresh).
  /// For copies with no local side this is a no-op.
  Future<void> keepMine(String id) async {
    final PromptSyncSnapshot snap = await check(id, force: true);
    final String? localHash = snap.localHash;
    // A bare mirror (no library/category copy) already agrees with itself;
    // only forked/categorized copies have local work worth acknowledging.
    if (localHash == null || snap.local == null) return;
    await journal.recordAgreed(id, baseHash: localHash);
    _memo.remove(id);
  }

  /// Bodies for the diff view: old = mirror (source), new = local copy.
  /// Returns `null` when either side is missing.
  Future<({String oldText, String newText})?> diffTexts(String id) async {
    final PromptSyncSnapshot snap = await check(id);
    final PromptDoc? local = snap.local;
    final PromptDoc? remote = snap.remote;
    if (local == null || remote == null) return null;
    return (
      oldText: '${remote.title}\n\n${remote.body}',
      newText: '${local.title}\n\n${local.body}',
    );
  }

  // ---- internals ----

  Future<PromptSyncSnapshot> _compute(String id) async {
    final List<PromptScopeDoc> scoped = await store.scopedDocsForId(id);
    PromptDoc? library;
    PromptDoc? categoryCopy;
    final List<PromptDoc> mirrors = <PromptDoc>[];
    for (final PromptScopeDoc s in scoped) {
      if (s.isSubscription) {
        mirrors.add(s.doc);
      } else if (s.isLibrary) {
        library ??= s.doc;
      } else {
        categoryCopy ??= s.doc;
      }
    }
    // Newest mirror by (version, updated) is the last fetched remote state.
    mirrors.sort((PromptDoc a, PromptDoc b) {
      final int v = a.version.compareTo(b.version);
      if (v != 0) return v;
      final DateTime au =
          a.updated ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
      final DateTime bu =
          b.updated ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
      return au.compareTo(bu);
    });
    final PromptDoc? remote = mirrors.isEmpty ? null : mirrors.last;
    final PromptDoc? local = library ?? categoryCopy;

    // Remote side = the last hash a *feed fetch* wrote (journal `remote`,
    // maintained by the store's mirror-write hook). It is NOT the live
    // mirror file: offline `saveInPlace` edits land in the mirror without
    // moving `remote`, which is what makes them read as "Edited here".
    // Fallback (never observed): the live mirror is all we know.
    final String? mirrorHash = remote == null ? null : syncHash(remote);
    final String? remoteHash = journal.remoteFor(id) ?? mirrorHash;
    String? baseHash = journal.baseFor(id);
    if (baseHash == null && mirrorHash != null) {
      // First sight: the mirror is the agreed state. A pre-existing edited
      // fork then reads as "Edited here" (local != base, remote == base).
      await journal.recordAgreed(id, baseHash: mirrorHash);
      baseHash = mirrorHash;
    }

    // No fork/category copy: the mirror file itself is the local state, so
    // an in-place offline edit (mirror != recorded remote == base) reads as
    // local-newer, while a fetched mirror (hook moved `remote` along) reads
    // as in-sync.
    final String? localHash =
        local == null ? mirrorHash : syncHash(local);
    final ItemSyncState state = determineSyncState(
      localHash: localHash,
      baseHash: baseHash,
      remoteHash: remoteHash,
      localUpdated: local?.updated,
      remoteUpdated: remote?.updated,
    );
    return PromptSyncSnapshot(
      id: id,
      state: state,
      local: local,
      remote: remote,
      localHash: localHash,
      baseHash: baseHash,
      remoteHash: remoteHash,
    );
  }

  /// Refreshes the feed backing [id]'s mirror (matched by `source_feed` URL
  /// or feed-slug). Best-effort: returns false when no engine or no matching
  /// feed is configured, or when the fetch itself fails. Never throws.
  Future<bool> _refreshSource(String id) async {
    final FeedEngine? eng = engine;
    if (eng == null) return false;
    try {
      final List<PromptScopeDoc> scoped = await store.scopedDocsForId(id);
      String? source;
      for (final PromptScopeDoc s in scoped) {
        if (s.isSubscription && s.doc.sourceFeed != null) {
          source = s.doc.sourceFeed;
          break;
        }
      }
      source ??= (await store.getById(id))?.sourceFeed;
      if (source == null || source.trim().isEmpty) return false;
      String? feedUrl;
      for (final FeedConfigEntry e in eng.feedConfig.feeds) {
        if (e.url == source ||
            e.url.trim() == source.trim() ||
            slugifyTitle(e.name) == slugifyTitle(source)) {
          feedUrl = e.url;
          break;
        }
      }
      if (feedUrl == null) return false;
      await eng.refreshFeed(feedUrl: feedUrl);
      // The mirror on disk is now the freshest known remote state regardless
      // of diagnostics (failures serve cache, which is what we compare to).
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Serializes [doc] with [fm.serialize] (used by tests to compare canonical
  /// file content, e.g. the identical-refresh skip in [PromptStore]).
  static String serializeForTest(PromptDoc doc) => fm.serialize(doc);
}
