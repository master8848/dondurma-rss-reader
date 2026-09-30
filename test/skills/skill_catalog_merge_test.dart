import 'dart:convert';

import 'package:test/test.dart';
import 'package:ice_cream_rss_reader/models/skill.dart';
import 'package:ice_cream_rss_reader/services/skills/skill_catalog_service.dart';
import 'package:ice_cream_rss_reader/services/skills/skill_list_utils.dart';
import 'package:ice_cream_rss_reader/services/skills/skills_http.dart';

Skill _s(String id, [String name = '']) => Skill(
  id: id,
  slug: id,
  name: name.isEmpty ? id : name,
  description: 'd',
  catalog: SkillCatalog.clawhub,
);

void main() {
  group('mergeDedupe', () {
    test('first catalog wins on id collision, order preserved', () {
      final merged = SkillListUtils.mergeDedupe([
        [_s('a', 'claw'), _s('b')],
        [_s('a', 'other'), _s('c')],
      ]);
      expect(merged.map((s) => s.id), ['a', 'b', 'c']);
      expect(merged.first.name, 'claw');
    });

    test('empty ids skipped, limit capped', () {
      final merged = SkillListUtils.mergeDedupe([
        [_s(''), _s('a'), _s('b'), _s('c')],
      ], 2);
      expect(merged.map((s) => s.id), ['a', 'b']);
    });
  });

  group('searchSkills with fakes', () {
    SkillCatalogService svcWith(Map<String, SkillsHttpResponse> canned) =>
        SkillCatalogService(http: FakeSkillsHttpClient(canned));

    String clawUrl(String q, int limit) => Uri.https('clawhub.ai', '/api/v1/search', {
      'q': q,
      'limit': '$limit',
      'mode': 'exact',
    }).toString();

    String shUrl(String q) => Uri.https('skills.sh', '/api/search', {
      'q': q,
      'limit': '50',
    }).toString();

    String hermesUrl() => Uri.https(
      'nousresearch.github.io',
      '/hermes-agent/docs/api/skills.json',
    ).toString();

    test('merges all three catalogs and dedupes', () async {
      final svc = svcWith({
        clawUrl('pdf', 50): SkillsHttpResponse(
          200,
          jsonEncode({
            'skills': [
              {'slug': 'pdf', 'name': 'PDF', 'ownerHandle': 'acme'},
            ],
          }),
        ),
        shUrl('pdf'): SkillsHttpResponse(
          200,
          jsonEncode([
            {'slug': 'pdfx', 'owner': 'o', 'repo': 'r'},
          ]),
        ),
        hermesUrl(): SkillsHttpResponse(
          200,
          jsonEncode([
            {'name': 'pdf-pro', 'description': 'handles pdf files'},
          ]),
        ),
      });
      final out = await svc.searchSkills('pdf');
      expect(out, hasLength(3));
      expect(out.map((s) => s.catalog).toSet(), {
        SkillCatalog.clawhub,
        SkillCatalog.skillsSh,
        SkillCatalog.hermes,
      });
    });

    test('per-source failure is swallowed, survivors returned', () async {
      final svc = svcWith({
        // ClawHub + Hermes have NO canned response -> throw -> guarded to [].
        shUrl('pdf'): SkillsHttpResponse(
          200,
          jsonEncode([
            {'slug': 'pdfx', 'owner': 'o', 'repo': 'r'},
          ]),
        ),
      });
      final out = await svc.searchSkills('pdf');
      expect(out.map((s) => s.id), ['skillssh:o/r/pdfx']);
    });

    test('catalog filter restricts sources', () async {
      final fake = FakeSkillsHttpClient({
        clawUrl('pdf', 50): const SkillsHttpResponse(200, '[]'),
      });
      final svc = SkillCatalogService(http: fake);
      await svc.searchSkills('pdf', catalog: SkillCatalogFilter.clawhub);
      expect(fake.requested.map((u) => u.host), ['clawhub.ai']);
    });

    test('empty query and non-positive limit short-circuit', () async {
      final fake = FakeSkillsHttpClient({});
      final svc = SkillCatalogService(http: fake);
      expect(await svc.searchSkills('  '), isEmpty);
      expect(await svc.searchSkills('pdf', limit: 0), isEmpty);
      expect(fake.requested, isEmpty);
    });

    test('non-200 responses yield no results', () async {
      final svc = svcWith({
        clawUrl('pdf', 50): const SkillsHttpResponse(500, 'err'),
        shUrl('pdf'): const SkillsHttpResponse(500, 'err'),
        hermesUrl(): const SkillsHttpResponse(500, 'err'),
      });
      expect(await svc.searchSkills('pdf'), isEmpty);
    });
  });
}
