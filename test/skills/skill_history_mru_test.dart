import 'package:test/test.dart';
import 'package:ice_cream_rss_reader/services/skills/skill_list_utils.dart';

void main() {
  group('mruInsert (MRU cap 10)', () {
    test('inserts most-recent-first', () {
      expect(SkillListUtils.mruInsert([], 'pdf'), ['pdf']);
      expect(
        SkillListUtils.mruInsert(['a', 'b'], 'c'),
        ['c', 'a', 'b'],
      );
    });

    test('duplicate moves to front without growing', () {
      expect(SkillListUtils.mruInsert(['a', 'b'], 'b'), ['b', 'a']);
    });

    test('trims and ignores empty queries', () {
      expect(SkillListUtils.mruInsert(['a'], '  '), ['a']);
      expect(SkillListUtils.mruInsert(['a'], '  b  '), ['b', 'a']);
    });

    test('caps at 10 entries', () {
      var history = <String>[];
      for (var i = 0; i < 15; i++) {
        history = SkillListUtils.mruInsert(history, 'q$i');
      }
      expect(history, hasLength(10));
      expect(history.first, 'q14');
      expect(history.last, 'q5');
    });

    test('custom cap respected, input never mutated', () {
      final input = ['a'];
      final out = SkillListUtils.mruInsert(input, 'b', 1);
      expect(out, ['b']);
      expect(input, ['a']);
    });
  });
}
