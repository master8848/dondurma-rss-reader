/// PromptSyncTracker over a real PromptStore in a temp dir: fork/edit,
// refresh/update/keep flows plus the mirror-write hook and journal.
import 'dart:io';

import 'package:test/test.dart';
import 'package:ice_cream_rss_reader/promptlib/prompt_doc.dart';
import 'package:ice_cream_rss_reader/promptlib/prompt_store.dart';
import 'package:ice_cream_rss_reader/promptlib/version_ux.dart';

Future<Directory> _tempRoot() =>
    Directory.systemTemp.createTemp('promptlib_versionux_test_');

String _journalPath(Directory root) =>
    '${root.path}${Platform.pathSeparator}.promptlib'
    '${Platform.pathSeparator}sync_baselines.json';

Future<PromptSyncTracker> _tracker(PromptStore store, Directory root) async {
  final BaselineJournal journal =
      await BaselineJournal.load(_journalPath(root));
  return PromptSyncTracker(store: store, journal: journal);
}

void main() {
  late Directory root;
  late PromptStore store;
  late PromptSyncTracker tracker;

  setUp(() async {
    root = await _tempRoot();
    store = PromptStore();
    await store.init(libraryRoot: root.path);
    tracker = await _tracker(store, root);
  });

  tearDown(() async {
    await store.dispose();
    try {
      await root.delete(recursive: true);
    } catch (_) {
      // Best-effort temp cleanup.
    }
  });

  group('PromptSyncTracker', () {
    test('fresh mirror reads in-sync and seeds the baseline', () async {
      await store.materializeSubscribedItem(
        feedSlug: 'feed',
        id: 'p1',
        title: 'Hello',
        body: 'fetched body',
      );
      final PromptSyncSnapshot snap = await tracker.check('p1');
      expect(snap.state, ItemSyncState.inSync);
      expect(snap.remote, isNotNull);
      expect(snap.local, isNull);
      expect(snap.baseHash, isNotNull);
    });

    test('fork + local edit reads edited-here', () async {
      await store.materializeSubscribedItem(
        feedSlug: 'feed',
        id: 'p1',
        title: 'Hello',
        body: 'fetched body',
      );
      expect((await tracker.check('p1')).state, ItemSyncState.inSync);
      await store.forkToLibrary('p1');
      final PromptDoc? forked = await store.getById('p1');
      await store.save(forked!.copyWith(body: 'my edits'));
      final PromptSyncSnapshot snap =
          await tracker.check('p1', force: true);
      expect(snap.state, ItemSyncState.localNewer);
      expect(snap.local, isNotNull);
      expect(snap.remote, isNotNull);
    });

    test('upstream refresh after a local edit reads update-available',
        () async {
      await store.materializeSubscribedItem(
        feedSlug: 'feed',
        id: 'p1',
        title: 'Hello',
        body: 'v1 body',
      );
      await store.forkToLibrary('p1');
      final PromptDoc? forked = await store.getById('p1');
      await store.save(forked!.copyWith(body: 'my edits'));
      expect(
        (await tracker.check('p1', force: true)).state,
        ItemSyncState.localNewer,
      );
      // Upstream moves: mirror rewrite is newer than the local edit.
      await store.materializeSubscribedItem(
        feedSlug: 'feed',
        id: 'p1',
        title: 'Hello',
        body: 'v2 body from the site',
      );
      final PromptSyncSnapshot snap =
          await tracker.check('p1', force: true);
      expect(snap.state, ItemSyncState.remoteNewer);
    });

    test('takeUpdate copies the source in and returns to in-sync', () async {
      await store.materializeSubscribedItem(
        feedSlug: 'feed',
        id: 'p1',
        title: 'Hello',
        body: 'v1',
      );
      await store.forkToLibrary('p1');
      final PromptDoc? forked = await store.getById('p1');
      await store.save(forked!.copyWith(body: 'my edits'));
      await store.materializeSubscribedItem(
        feedSlug: 'feed',
        id: 'p1',
        title: 'Hello',
        body: 'v2 from the site',
      );
      expect(
        (await tracker.check('p1', force: true)).state,
        ItemSyncState.remoteNewer,
      );
      final PromptDoc? saved = await tracker.takeUpdate('p1');
      expect(saved, isNotNull);
      expect((await store.getById('p1'))?.body, 'v2 from the site');
      expect(
        (await tracker.check('p1', force: true)).state,
        ItemSyncState.inSync,
      );
    });

    test('keepMine clears the badge until the source moves again', () async {
      await store.materializeSubscribedItem(
        feedSlug: 'feed',
        id: 'p1',
        title: 'Hello',
        body: 'v1',
      );
      await store.forkToLibrary('p1');
      final PromptDoc? forked = await store.getById('p1');
      await store.save(forked!.copyWith(body: 'my edits'));
      expect(
        (await tracker.check('p1', force: true)).state,
        ItemSyncState.localNewer,
      );
      await tracker.keepMine('p1');
      expect(
        (await tracker.check('p1', force: true)).state,
        ItemSyncState.inSync,
      );
      // A genuinely new upstream body flags again.
      await store.materializeSubscribedItem(
        feedSlug: 'feed',
        id: 'p1',
        title: 'Hello',
        body: 'v2 from the site',
      );
      expect(
        (await tracker.check('p1', force: true)).state,
        ItemSyncState.remoteNewer,
      );
    });

    test('offline in-place edit of a bare mirror reads edited-here',
        () async {
      await store.materializeSubscribedItem(
        feedSlug: 'feed',
        id: 'p1',
        title: 'Hello',
        body: 'v1',
      );
      expect((await tracker.check('p1')).state, ItemSyncState.inSync);
      final PromptDoc? mirror = await store.getById('p1');
      await store.saveInPlace(mirror!.copyWith(body: 'offline tweak'));
      final PromptSyncSnapshot snap =
          await tracker.check('p1', force: true);
      expect(snap.state, ItemSyncState.localNewer);
    });

    test('diffTexts puts the source first, mine second', () async {
      await store.materializeSubscribedItem(
        feedSlug: 'feed',
        id: 'p1',
        title: 'Hello',
        body: 'site body',
      );
      await store.forkToLibrary('p1');
      final PromptDoc? forked = await store.getById('p1');
      await store.save(forked!.copyWith(body: 'my body'));
      final ({String oldText, String newText})? diff =
          await tracker.diffTexts('p1');
      expect(diff, isNotNull);
      expect(diff!.oldText, contains('site body'));
      expect(diff.newText, contains('my body'));
    });

    test('unknown id degrades to unknown, never throws', () async {
      final PromptSyncSnapshot snap = await tracker.check('nope');
      expect(snap.state, ItemSyncState.unknown);
      expect(await tracker.takeUpdate('nope'), isNull);
      expect(await tracker.diffTexts('nope'), isNull);
      await tracker.keepMine('nope'); // no-op, no throw
    });

    test('memoized verdict reused until forced', () async {
      await store.materializeSubscribedItem(
        feedSlug: 'feed',
        id: 'p1',
        title: 'Hello',
        body: 'v1',
      );
      expect((await tracker.check('p1')).state, ItemSyncState.inSync);
      final PromptDoc? mirror = await store.getById('p1');
      await store.saveInPlace(mirror!.copyWith(body: 'offline tweak'));
      // Memoized: still the old verdict without force.
      expect((await tracker.check('p1')).state, ItemSyncState.inSync);
      expect(
        (await tracker.check('p1', force: true)).state,
        ItemSyncState.localNewer,
      );
    });
  });

  group('materialize identical-refresh skip', () {
    test('same words keep the file untouched (no mtime churn)', () async {
      final PromptDoc first = await store.materializeSubscribedItem(
        feedSlug: 'feed',
        id: 'p1',
        title: 'Hello',
        body: 'same body',
      );
      final PromptDoc second = await store.materializeSubscribedItem(
        feedSlug: 'feed',
        id: 'p1',
        title: 'Hello',
        body: 'same body',
      );
      expect(second.updated, first.updated);
      expect(second.body, 'same body');
    });

    test('changed words rewrite with a fresh timestamp', () async {
      await store.materializeSubscribedItem(
        feedSlug: 'feed',
        id: 'p1',
        title: 'Hello',
        body: 'v1',
      );
      final PromptDoc second = await store.materializeSubscribedItem(
        feedSlug: 'feed',
        id: 'p1',
        title: 'Hello',
        body: 'v2',
      );
      expect(second.body, 'v2');
      final String file = await File(
        '${root.path}${Platform.pathSeparator}subscriptions'
        '${Platform.pathSeparator}feed'
        '${Platform.pathSeparator}hello.md',
      ).readAsString();
      expect(file, contains('v2'));
    });

    test('mirror-write hook fires on change, not on identical skip',
        () async {
      final List<String> seen = <String>[];
      store.onMirrorWrite = (String id, String hash) {
        seen.add('$id:$hash');
      };
      await store.materializeSubscribedItem(
        feedSlug: 'feed',
        id: 'p1',
        title: 'Hello',
        body: 'v1',
      );
      expect(seen, hasLength(1));
      await store.materializeSubscribedItem(
        feedSlug: 'feed',
        id: 'p1',
        title: 'Hello',
        body: 'v1',
      );
      expect(seen, hasLength(1));
      await store.materializeSubscribedItem(
        feedSlug: 'feed',
        id: 'p1',
        title: 'Hello',
        body: 'v2',
      );
      expect(seen, hasLength(2));
    });
  });

  group('BaselineJournal', () {
    test('round-trips through its file', () async {
      final String path = _journalPath(root);
      final BaselineJournal a = await BaselineJournal.load(path);
      expect(a.baseFor('p1'), isNull);
      await a.recordAgreed('p1', baseHash: 'b1', remoteHash: 'r1');
      await a.noteRemote('p1', 'r2');
      final BaselineJournal b = await BaselineJournal.load(path);
      expect(b.baseFor('p1'), 'b1');
      expect(b.remoteFor('p1'), 'r2');
    });

    test('missing or corrupt file starts empty', () async {
      final BaselineJournal missing = await BaselineJournal.load(
        '${root.path}${Platform.pathSeparator}nope.json',
      );
      expect(missing.baseFor('p1'), isNull);
      final String bad =
          '${root.path}${Platform.pathSeparator}bad.json';
      await File(bad).writeAsString('not json{{{');
      final BaselineJournal corrupt = await BaselineJournal.load(bad);
      expect(corrupt.baseFor('p1'), isNull);
    });
  });
}
