import 'package:test/test.dart';
import 'package:ice_cream_rss_reader/models/skill.dart';

Skill _sample() => const Skill(
  id: 'skillssh:owner/repo/pdf',
  slug: 'pdf',
  name: 'PDF reader',
  description: 'Reads PDFs',
  version: '1.2.3',
  author: 'owner',
  license: 'MIT',
  catalog: SkillCatalog.skillsSh,
  owner: 'owner',
  repo: 'repo',
  skillPath: 'skills/pdf',
  ref: 'main',
  installUrl: 'https://skills.sh/api/download/owner/repo/pdf',
  homepage: 'https://github.com/owner/repo',
  tags: ['pdf', 'docs'],
  audit: SkillVerdict.safe,
  auditReason: 'audit passed (score 92)',
);

void main() {
  test('json roundtrip preserves every field', () {
    final back = Skill.fromJson(_sample().toJson());
    expect(back.id, 'skillssh:owner/repo/pdf');
    expect(back.slug, 'pdf');
    expect(back.name, 'PDF reader');
    expect(back.description, 'Reads PDFs');
    expect(back.version, '1.2.3');
    expect(back.author, 'owner');
    expect(back.license, 'MIT');
    expect(back.catalog, SkillCatalog.skillsSh);
    expect(back.owner, 'owner');
    expect(back.repo, 'repo');
    expect(back.skillPath, 'skills/pdf');
    expect(back.ref, 'main');
    expect(back.installUrl, contains('download'));
    expect(back.homepage, contains('github'));
    expect(back.tags, ['pdf', 'docs']);
    expect(back.audit, SkillVerdict.safe);
    expect(back.auditReason, contains('92'));
  });

  test('missing fields fall back to safe defaults (never throws)', () {
    final skill = Skill.fromJson({});
    expect(skill.id, '');
    expect(skill.tags, isEmpty);
    expect(skill.catalog, SkillCatalog.wellKnown);
    expect(skill.audit, SkillVerdict.unknown);
  });

  test('unknown catalog/verdict names fail open, never throw', () {
    final skill = Skill.fromJson({'catalog': 'nope', 'audit': 'bogus'});
    expect(skill.catalog, SkillCatalog.wellKnown);
    expect(skill.audit, SkillVerdict.unknown);
  });

  test('equality is id-based', () {
    expect(_sample(), Skill.fromJson(_sample().toJson()));
    expect(
      _sample(),
      const Skill(id: 'skillssh:owner/repo/pdf', slug: 'x', name: 'y', description: 'z', catalog: SkillCatalog.clawhub),
    );
    expect(_sample().hashCode, 'skillssh:owner/repo/pdf'.hashCode);
  });

  test('copyWith attaches audit results', () {
    final updated = _sample().copyWith(
      audit: SkillVerdict.unsafe,
      auditReason: 'risk: high',
    );
    expect(updated.audit, SkillVerdict.unsafe);
    expect(updated.auditReason, 'risk: high');
    expect(updated.id, _sample().id);
  });
}
