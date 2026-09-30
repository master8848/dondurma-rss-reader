/// Tri-state local-vs-remote determination: pure logic, no widgets, no git.
import 'package:test/test.dart';
import 'package:ice_cream_rss_reader/promptlib/prompt_doc.dart';
import 'package:ice_cream_rss_reader/promptlib/version_ux.dart';

void main() {
  group('contentHash / syncHash', () {
    test('stable for identical input', () {
      expect(contentHash('hello'), contentHash('hello'));
    });

    test('differs when words change', () {
      expect(contentHash('hello'), isNot(contentHash('hello!')));
    });

    test('syncHash ignores timestamps and version bumps', () {
      final DateTime t1 = DateTime.utc(2026, 1, 1);
      final DateTime t2 = DateTime.utc(2026, 5, 5);
      final PromptDoc a = PromptDoc(
        id: 'x',
        title: 'T',
        tags: const ['a'],
        body: 'body',
        version: 1,
        created: t1,
        updated: t1,
      );
      final PromptDoc b = a.copyWith(
        created: () => t2,
        updated: () => t2,
        version: 7,
      );
      expect(syncHash(a), syncHash(b));
    });

    test('syncHash moves with title, tags, or body', () {
      const PromptDoc a = PromptDoc(id: 'x', title: 'T', body: 'b');
      expect(syncHash(a), isNot(syncHash(a.copyWith(title: 'T2'))));
      expect(syncHash(a), isNot(syncHash(a.copyWith(body: 'b2'))));
      expect(
        syncHash(a),
        isNot(syncHash(a.copyWith(tags: const ['t']))),
      );
    });
  });

  group('determineSyncState', () {
    test('in-sync when hashes agree (even without a baseline)', () {
      expect(
        determineSyncState(localHash: 'h', remoteHash: 'h'),
        ItemSyncState.inSync,
      );
    });

    test('edited-locally: local moved on from the agreed base', () {
      expect(
        determineSyncState(
          localHash: 'local2',
          baseHash: 'base',
          remoteHash: 'base',
        ),
        ItemSyncState.localNewer,
      );
    });

    test('remote-ahead: remote moved on from the agreed base', () {
      expect(
        determineSyncState(
          localHash: 'base',
          baseHash: 'base',
          remoteHash: 'remote2',
        ),
        ItemSyncState.remoteNewer,
      );
    });

    test('both moved: strictly-newer remote wins', () {
      final DateTime local = DateTime.utc(2026, 1, 2);
      final DateTime remote = DateTime.utc(2026, 1, 3);
      expect(
        determineSyncState(
          localHash: 'l2',
          baseHash: 'b',
          remoteHash: 'r2',
          localUpdated: local,
          remoteUpdated: remote,
        ),
        ItemSyncState.remoteNewer,
      );
    });

    test('both moved: tie or missing dates protect local work', () {
      final DateTime same = DateTime.utc(2026, 1, 2);
      expect(
        determineSyncState(
          localHash: 'l2',
          baseHash: 'b',
          remoteHash: 'r2',
          localUpdated: same,
          remoteUpdated: same,
        ),
        ItemSyncState.localNewer,
      );
      expect(
        determineSyncState(
          localHash: 'l2',
          baseHash: 'b',
          remoteHash: 'r2',
        ),
        ItemSyncState.localNewer,
      );
    });

    test('unknown when there is no local copy', () {
      expect(
        determineSyncState(remoteHash: 'r'),
        ItemSyncState.unknown,
      );
      expect(
        determineSyncState(localHash: '', remoteHash: 'r'),
        ItemSyncState.unknown,
      );
    });

    test('offline-graceful: no remote and no baseline is unknown', () {
      expect(
        determineSyncState(localHash: 'l'),
        ItemSyncState.unknown,
      );
      expect(
        determineSyncState(),
        ItemSyncState.unknown,
      );
    });

    test('offline still reports an un-acked local edit', () {
      expect(
        determineSyncState(localHash: 'l2', baseHash: 'b'),
        ItemSyncState.localNewer,
      );
      // Unchanged local copy with no remote to compare: unknown, not newer.
      expect(
        determineSyncState(localHash: 'b', baseHash: 'b'),
        ItemSyncState.unknown,
      );
    });

    test('no baseline: newer timestamp wins, ties protect local', () {
      expect(
        determineSyncState(
          localHash: 'l',
          remoteHash: 'r',
          localUpdated: DateTime.utc(2026, 1, 1),
          remoteUpdated: DateTime.utc(2026, 2, 1),
        ),
        ItemSyncState.remoteNewer,
      );
      expect(
        determineSyncState(localHash: 'l', remoteHash: 'r'),
        ItemSyncState.localNewer,
      );
    });
  });

  group('SyncStateLabels', () {
    test('plain words, no jargon', () {
      expect(ItemSyncState.inSync.label, 'Up to date');
      expect(ItemSyncState.localNewer.label, 'Edited here');
      expect(ItemSyncState.remoteNewer.label, 'Update available');
      expect(ItemSyncState.unknown.label, 'Not checked yet');
      for (final ItemSyncState s in ItemSyncState.values) {
        expect(s.detail, isNotEmpty);
        expect(s.label, isNot(contains('HEAD')));
        expect(s.label, isNot(contains('diverged')));
      }
    });
  });
}
