/// WP1 tests: front-matter parser/serializer contract.
import 'package:flutter_test/flutter_test.dart';
import 'package:ice_cream_rss_reader/promptlib/front_matter.dart';
import 'package:ice_cream_rss_reader/promptlib/prompt_doc.dart';

PromptDoc _sample() => PromptDoc(
      id: '9f2c3a10-7b1d-4e5a-9c0f-123456789abc',
      title: 'Code review checklist',
      tags: const ['coding', 'review'],
      sourceFeed: 'example-prompts',
      created: DateTime.utc(2026, 1, 2, 3, 4, 5),
      updated: DateTime.utc(2026, 5, 6, 7, 8, 9),
      body: '# Hello\n\nBody with a --- delimiter line inside.\n',
    );

void main() {
  group('front matter round-trip', () {
    test('valid doc serializes and parses back exactly', () {
      final PromptDoc doc = _sample();
      final PromptDoc back = parse(serialize(doc));
      expect(back.id, doc.id);
      expect(back.title, doc.title);
      expect(back.tags, doc.tags);
      expect(back.sourceFeed, doc.sourceFeed);
      expect(back.created, doc.created);
      expect(back.updated, doc.updated);
      expect(back.body, doc.body);
      expect(back.needsReview, isFalse);
    });

    test('unicode title/body round-trips', () {
      const PromptDoc doc = PromptDoc(
        id: 'abc',
        title: 'Türkçe ünïcode başlık ✨ with spaces',
        tags: ['a b', 'c:d'],
        body: 'emoji 🎉 and --- dashes',
      );
      final PromptDoc back = parse(serialize(doc));
      expect(back.title, doc.title);
      expect(back.tags, doc.tags);
      expect(back.body, doc.body);
    });

    test('tags accept flow list, block list, and scalar forms', () {
      const String flowDoc =
          '---\nid: a\ntitle: t\ntags: [x, y]\n---\nbody';
      const String block =
          '---\nid: a\ntitle: t\ntags:\n  - x\n  - y\n---\nbody';
      const String scalar =
          '---\nid: a\ntitle: t\ntags: solo\n---\nbody';
      const String absent = '---\nid: a\ntitle: t\n---\nbody';
      expect(parse(flowDoc).tags, ['x', 'y']);
      expect(parse(block).tags, ['x', 'y']);
      expect(parse(scalar).tags, ['solo']);
      expect(parse(absent).tags, isEmpty);
    });
  });

  group('malformed front matter throws FormatException', () {
    test('missing opening delimiter', () {
      expect(() => parse('# no front matter\nbody'),
          throwsFormatException);
    });

    test('missing closing delimiter', () {
      expect(() => parse('---\nid: a\ntitle: t\nno closing here'),
          throwsFormatException);
    });

    test('non key:value line inside front matter', () {
      expect(() => parse('---\nid: a\njust some words\n---\nbody'),
          throwsFormatException);
    });

    test('unclosed flow list', () {
      expect(
          () => parse('---\nid: a\ntitle: t\ntags: [x, y\n---\nbody'),
          throwsFormatException);
    });

    test('invalid date', () {
      expect(
          () => parse(
              '---\nid: a\ntitle: t\ncreated: not-a-date\n---\nbody'),
          throwsFormatException);
    });

    test('never throws a non-FormatException', () {
      // Fuzz-ish: control chars / strange inputs must surface only as
      // FormatException, never a crash (RangeError, CastError, ...).
      const List<String> weird = [
        '',
        '---',
        '---\n---',
        '---\n\x00\x01\x02\n---\n',
        '---\nid:\n---\n',
      ];
      for (final String w in weird) {
        try {
          parse(w);
        } on FormatException {
          // expected for malformed inputs
        } catch (e) {
          fail('non-FormatException for input "$w": $e');
        }
      }
    });
  });

  group('missing id', () {
    test('generates a UUID and flags REVIEW', () {
      final PromptDoc doc =
          parse('---\ntitle: No id here\n---\nbody text');
      expect(doc.id, isNotEmpty);
      expect(
        RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-'
          r'[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        ).hasMatch(doc.id),
        isTrue,
        reason: 'expected UUID v4, got "${doc.id}"',
      );
      expect(doc.needsReview, isTrue);
    });

    test('blank id is treated as missing', () {
      final PromptDoc doc =
          parse('---\nid:   \ntitle: t\n---\nbody');
      expect(doc.id, isNotEmpty);
      expect(doc.needsReview, isTrue);
    });
  });
}
