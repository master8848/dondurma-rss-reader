import 'package:test/test.dart';
import 'package:ice_cream_rss_reader/models/skill.dart';
import 'package:ice_cream_rss_reader/services/skills/skill_audit_service.dart';
import 'package:ice_cream_rss_reader/services/skills/skills_http.dart';

void main() {
  group('mapAuditPayload verdict mapping', () {
    test('critical/high risk => UNSAFE', () {
      expect(
        SkillAuditService.mapAuditPayload({'risk': 'critical'}, 's').verdict,
        SkillVerdict.unsafe,
      );
      expect(
        SkillAuditService.mapAuditPayload({'risk': 'HIGH'}, 's').verdict,
        SkillVerdict.unsafe,
      );
    });

    test('socket alerts => UNSAFE', () {
      expect(
        SkillAuditService.mapAuditPayload({
          'risk': 'low',
          'socket': {'alerts': 2},
        }, 's').verdict,
        SkillVerdict.unsafe,
      );
      expect(
        SkillAuditService.mapAuditPayload({
          'socket': {'alerts': ['x']},
        }, 's').verdict,
        SkillVerdict.unsafe,
      );
    });

    test('score below 80 => UNSAFE', () {
      final r = SkillAuditService.mapAuditPayload({'score': 79}, 's');
      expect(r.verdict, SkillVerdict.unsafe);
      expect(r.reason, contains('79'));
    });

    test('clean payload => SAFE', () {
      final r = SkillAuditService.mapAuditPayload(
        {'risk': 'low', 'score': 92, 'socket': {'alerts': 0}},
        's',
      );
      expect(r.verdict, SkillVerdict.safe);
      expect(r.reason, contains('92'));
    });

    test('envelope shapes resolve the slug entry', () {
      final r = SkillAuditService.mapAuditPayload({
        'skills': {'pdf': {'risk': 'high'}},
      }, 'pdf');
      expect(r.verdict, SkillVerdict.unsafe);
    });

    test('missing entry => UNKNOWN (fail-open)', () {
      expect(
        SkillAuditService.mapAuditPayload({'skills': {}}, 'pdf').verdict,
        SkillVerdict.unknown,
      );
      expect(
        SkillAuditService.mapAuditPayload('garbage', 'pdf').verdict,
        SkillVerdict.unknown,
      );
    });
  });

  group('verdictForCoords', () {
    test('missing coordinates => UNKNOWN without any HTTP call', () async {
      final fake = FakeSkillsHttpClient({});
      final svc = SkillAuditService(http: fake);
      final r = await svc.verdictForCoords(owner: '', repo: 'r', slug: 's');
      expect(r.verdict, SkillVerdict.unknown);
      expect(r.reason, contains('missing'));
      expect(fake.requested, isEmpty);
    });

    test('HTTP failure => UNKNOWN (fail-open)', () async {
      final svc = SkillAuditService(http: FakeSkillsHttpClient({}));
      final r = await svc.verdictForCoords(owner: 'o', repo: 'r', slug: 's');
      expect(r.verdict, SkillVerdict.unknown);
    });

    test('audit payload flows through to the skill copy', () async {
      final url = Uri.https('add-skill.vercel.sh', '/audit', {
        'source': 'o/r',
        'skills': 'pdf',
      }).toString();
      final fake = FakeSkillsHttpClient({
        url: const SkillsHttpResponse(200, '{"risk": "high"}'),
      });
      final svc = SkillAuditService(http: fake);
      final skill = await svc.verdictFor(
        const Skill(
          id: 'x',
          slug: 'pdf',
          name: 'pdf',
          description: '',
          catalog: SkillCatalog.skillsSh,
          owner: 'o',
          repo: 'r',
        ),
      );
      expect(skill.audit, SkillVerdict.unsafe);
      expect(skill.auditReason, contains('high'));
    });
  });
}
