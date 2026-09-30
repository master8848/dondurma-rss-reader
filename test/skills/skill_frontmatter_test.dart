import 'package:test/test.dart';
import 'package:ice_cream_rss_reader/services/skills/skill_list_utils.dart';

void main() {
  group('parseSkillFrontmatter', () {
    test('parses name/description/version', () {
      const md = '---\nname: pdf\ndescription: Reads PDFs\nversion: 1.2.3\n---\n\n# body\n';
      final fm = parseSkillFrontmatter(md);
      expect(fm['name'], 'pdf');
      expect(fm['description'], 'Reads PDFs');
      expect(fm['version'], '1.2.3');
    });

    test('handles quoted values and comments', () {
      const md = '---\nname: "my skill" # trailing comment\ndescription: \'does things\'\n---\n';
      final fm = parseSkillFrontmatter(md);
      expect(fm['name'], 'my skill');
      expect(fm['description'], 'does things');
    });

    test('keys are lowercased', () {
      const md = '---\nName: PDF\nDescription: x\n---\n';
      final fm = parseSkillFrontmatter(md);
      expect(fm['name'], 'PDF');
      expect(fm['description'], 'x');
    });

    test('returns empty map without a frontmatter block', () {
      expect(parseSkillFrontmatter('# just a body\n'), isEmpty);
      expect(parseSkillFrontmatter(''), isEmpty);
      expect(parseSkillFrontmatter('---\nno closing\n'), isEmpty);
    });

    test('skips non key-value lines', () {
      const md = '---\nname: pdf\n- a list item\n: weird\n---\n';
      final fm = parseSkillFrontmatter(md);
      expect(fm, {'name': 'pdf'});
    });
  });
}
