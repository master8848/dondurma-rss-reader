// ignore_for_file: avoid_relative_lib_imports, avoid_print
// Plain-`dart` smoke script for the skills data layer.
//
// Runs WITHOUT `pub get` / Flutter SDK: it imports the lib files via
// relative paths, and those files use only `dart:` libraries.
// Execute: `dart test/skills/smoke_run.dart` (NOT `dart run`).
// The `test/skills/*_test.dart` files cover the same behavior in
// `package:test` style for CI with the Flutter SDK.

import '../../lib/models/skill.dart';
import '../../lib/services/skills/skill_audit_service.dart';
import '../../lib/services/skills/skill_catalog_service.dart'; // ignore: unused_import
import '../../lib/services/skills/skill_list_utils.dart';
import '../../lib/services/skills/skills_cache_service.dart';
import '../../lib/services/skills/skills_http.dart';

int _failures = 0;

void check(bool cond, String label) {
  if (cond) {
    print('ok   $label');
  } else {
    _failures++;
    print('FAIL $label');
  }
}

Future<void> main() async {
  // Model roundtrip.
  const skill = Skill(
    id: 'skillssh:o/r/pdf',
    slug: 'pdf',
    name: 'PDF',
    description: 'Reads PDFs',
    catalog: SkillCatalog.skillsSh,
    owner: 'o',
    repo: 'r',
  );
  final back = Skill.fromJson(skill.toJson());
  check(back == skill, 'model json roundtrip');
  check(Skill.fromJson({}).audit == SkillVerdict.unknown, 'model fail-open defaults');

  // Frontmatter.
  final fm = parseSkillFrontmatter('---\nname: pdf\ndescription: x\nversion: 2\n---\nbody');
  check(fm['name'] == 'pdf' && fm['version'] == '2', 'frontmatter parse');
  check(parseSkillFrontmatter('no block').isEmpty, 'frontmatter empty without block');

  // Cache key.
  final key = SkillListUtils.repoCacheKey(host: 'github.com', owner: 'o', repo: 'r', ref: 'main');
  check(RegExp(r'^main--[0-9a-f]{8}$').hasMatch(key), 'cache-key format $key');
  check(
    SkillListUtils.repoCacheKey(host: 'h', owner: 'o', repo: 'r', ref: '') !=
        SkillListUtils.repoCacheKey(host: 'h', owner: 'o', repo: 'r2', ref: ''),
    'cache-key uniqueness',
  );
  check(
    SkillRepoCoords.parse('git@github.com:o/r.git')!.repo == 'r',
    'ssh url parse',
  );

  // Verdict mapping.
  check(
    SkillAuditService.mapAuditPayload({'risk': 'critical'}, 's').verdict == SkillVerdict.unsafe,
    'verdict critical=>unsafe',
  );
  check(
    SkillAuditService.mapAuditPayload({'score': 79}, 's').verdict == SkillVerdict.unsafe,
    'verdict score<80=>unsafe',
  );
  check(
    SkillAuditService.mapAuditPayload({'risk': 'low', 'score': 95}, 's').verdict == SkillVerdict.safe,
    'verdict clean=>safe',
  );
  check(
    SkillAuditService.mapAuditPayload('garbage', 's').verdict == SkillVerdict.unknown,
    'verdict garbage=>unknown',
  );

  // MRU cap.
  var h = <String>[];
  for (var i = 0; i < 12; i++) {
    h = SkillListUtils.mruInsert(h, 'q$i');
  }
  check(h.length == 10 && h.first == 'q11' && h.last == 'q2', 'mru cap 10');

  // Merge/dedupe.
  Skill s(String id) => Skill(id: id, slug: id, name: id, description: '', catalog: SkillCatalog.clawhub);
  final merged = SkillListUtils.mergeDedupe([
    [s('a'), s('b')],
    [s('a'), s('c')],
  ], 2);
  check(merged.length == 2 && merged.first.id == 'a', 'merge dedupe+cap');

  // Catalog search with fake HTTP (per-source failure swallowed).
  final svc = SkillCatalogService(
    http: FakeSkillsHttpClient({
      'https://skills.sh/api/search?q=pdf&limit=50': const SkillsHttpResponse(
        200,
        '[{"slug":"pdfx","owner":"o","repo":"r"}]',
      ),
    }),
  );
  final found = await svc.searchSkills('pdf');
  check(found.length == 1 && found.first.id == 'skillssh:o/r/pdfx', 'catalog search with fakes');

  if (_failures > 0) {
    print('SMOKE FAILED: $_failures failures');
    throw StateError('smoke failed');
  }
  print('SMOKE PASSED');
}
