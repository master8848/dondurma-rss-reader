import 'dart:io';

import 'package:test/test.dart';
import 'package:ice_cream_rss_reader/services/skills/skill_list_utils.dart';
import 'package:ice_cream_rss_reader/services/skills/skills_cache_service.dart';

void main() {
  group('cache-key derivation', () {
    test('format is <ref>--<hash8> with 8 hex chars', () {
      final key = SkillListUtils.repoCacheKey(
        host: 'github.com',
        owner: 'o',
        repo: 'r',
        ref: 'main',
      );
      expect(key, startsWith('main--'));
      expect(key.split('--').last, matches(RegExp(r'^[0-9a-f]{8}$')));
    });

    test('empty ref normalizes to HEAD', () {
      final a = SkillListUtils.repoCacheKey(host: 'h', owner: 'o', repo: 'r', ref: '');
      expect(a, startsWith('HEAD--'));
    });

    test('different repos/refs give different keys', () {
      String k(String o, String r, String ref) => SkillListUtils.repoCacheKey(
        host: 'github.com',
        owner: o,
        repo: r,
        ref: ref,
      );
      expect(k('a', 'r', 'main'), isNot(k('b', 'r', 'main')));
      expect(k('a', 'r', 'main'), isNot(k('a', 'r', 'dev')));
    });

    test('hash8 is deterministic', () {
      expect(SkillListUtils.hash8('x'), SkillListUtils.hash8('x'));
    });
  });

  group('SkillRepoCoords.parse', () {
    test('parses https urls with and without .git', () {
      final a = SkillRepoCoords.parse('https://github.com/o/r')!;
      expect(a.host, 'github.com');
      expect(a.owner, 'o');
      expect(a.repo, 'r');
      expect(SkillRepoCoords.parse('https://github.com/o/r.git')!.repo, 'r');
    });

    test('parses ssh urls', () {
      final a = SkillRepoCoords.parse('git@github.com:o/r.git')!;
      expect(a.host, 'github.com');
      expect(a.owner, 'o');
      expect(a.repo, 'r');
    });

    test('returns null for unparseable urls', () {
      expect(SkillRepoCoords.parse(''), isNull);
      expect(SkillRepoCoords.parse('not a url'), isNull);
      expect(SkillRepoCoords.parse('https://github.com/onlyowner'), isNull);
    });
  });

  group('repoDirFor layout', () {
    test('mirrors mskill repos/<host>/<owner>/<repo>/<key>', () {
      final svc = SkillsCacheService(baseDir: _fakeDir());
      final dir = svc.repoDirFor('https://github.com/o/r', ref: 'main')!;
      final seps = dir.path.split('/');
      expect(seps.sublist(seps.length - 5), [
        'repos',
        'github.com',
        'o',
        'r',
        SkillListUtils.repoCacheKey(host: 'github.com', owner: 'o', repo: 'r', ref: 'main'),
      ]);
    });

    test('returns null for bad urls', () {
      expect(SkillsCacheService(baseDir: _fakeDir()).repoDirFor('nope'), isNull);
    });
  });

  group('SkillRepoMeta', () {
    test('json roundtrip keeps the pin record', () {
      const meta = SkillRepoMeta(
        host: 'github.com',
        owner: 'o',
        repo: 'r',
        ref: 'main',
        cloneUrl: 'https://github.com/o/r',
        commitSha: 'abc123',
        shallow: true,
        lastFetch: '2026-01-01T00:00:00Z',
      );
      final back = SkillRepoMeta.fromJson(meta.toJson());
      expect(back.commitSha, 'abc123');
      expect(back.shallow, isTrue);
      expect(back.cloneUrl, contains('github'));
    });
  });
}

// Directory is only used for path math here — never touched on disk.
Directory _fakeDir() => Directory('/tmp/skills-cache-test');
