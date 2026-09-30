/// WP7 tests: ExpandBridge render/missing/clipboard/degraded-fallback +
/// TriggerStore CRUD/validation/persistence.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ice_cream_rss_reader/promptlib/expand_bridge.dart';
import 'package:ice_cream_rss_reader/promptlib/prompt_doc.dart';
import 'package:ice_cream_rss_reader/promptlib/trigger_store.dart';

PromptDoc _doc(String body) => PromptDoc(
      id: '11111111-2222-4333-8444-555555555555',
      title: 'Sample',
      body: body,
    );

final DateTime _fixed = DateTime(2026, 9, 30);

ExpandBridge _bridge({
  ClipboardWriter? clipboard,
  ExpandHelper? helper,
  ExpandPlatform platform = ExpandPlatform.other,
  Future<String?> Function()? clipboardReader,
}) {
  return ExpandBridge(
    clipboard: clipboard ?? MemoryClipboardWriter(),
    helper: helper,
    platform: platform,
    clipboardReader: clipboardReader,
    nowProvider: () => _fixed,
  );
}

void main() {
  group('render', () {
    test('substitutes {{clipboard}} and {{date}}', () {
      final ExpandBridge bridge = _bridge();
      final String out = bridge.render(
        doc: _doc('Summarize: {{clipboard}} ({{date}})'),
        variables: <String, String>{'clipboard': 'pasted'},
      );
      expect(out, 'Summarize: pasted (2026-09-30)');
    });

    test('explicit date variable overrides the clock', () {
      final ExpandBridge bridge = _bridge();
      final String out = bridge.render(
        doc: _doc('log {{date}}'),
        variables: <String, String>{'date': '2000-01-02'},
      );
      expect(out, 'log 2000-01-02');
    });

    test('unknown {{tokens}} left literal', () {
      final ExpandBridge bridge = _bridge();
      final String out = bridge.render(
        doc: _doc('hi {{name}}, review {{topic}}'),
        variables: const <String, String>{},
      );
      expect(out, 'hi {{name}}, review {{topic}}');
    });

    test('inner whitespace tolerated ({{ clipboard }})', () {
      final ExpandBridge bridge = _bridge();
      final String out = bridge.render(
        doc: _doc('a {{ clipboard }} b'),
        variables: <String, String>{'clipboard': 'C'},
      );
      expect(out, 'a C b');
    });

    test('non-name braces untouched', () {
      final ExpandBridge bridge = _bridge();
      final String out = bridge.render(
        doc: _doc('css {{foo-bar}} stays'),
        variables: const <String, String>{},
      );
      expect(out, 'css {{foo-bar}} stays');
    });
  });

  group('missingVariables', () {
    test('lists absent clipboard + unknown, never date', () {
      final ExpandBridge bridge = _bridge();
      final List<String> missing = bridge.missingVariables(
        doc: _doc('{{clipboard}} {{date}} {{name}} {{name}}'),
        provided: const <String, String>{},
      );
      expect(missing, <String>['clipboard', 'name']);
    });

    test('provided values are not missing', () {
      final ExpandBridge bridge = _bridge();
      final List<String> missing = bridge.missingVariables(
        doc: _doc('{{clipboard}} done'),
        provided: const <String, String>{'clipboard': 'x'},
      );
      expect(missing, isEmpty);
    });
  });

  group('expandToClipboard', () {
    test('writes rendered text via injected writer', () async {
      final MemoryClipboardWriter writer = MemoryClipboardWriter();
      final ExpandBridge bridge = _bridge(clipboard: writer);
      final String text = await bridge.expandToClipboard(
        doc: _doc('note {{date}}'),
        variables: const <String, String>{},
      );
      expect(text, 'note 2026-09-30');
      expect(writer.lastWritten, 'note 2026-09-30');
      expect(writer.writes, 1);
    });

    test('clipboardText fills {{clipboard}} without variables', () async {
      final MemoryClipboardWriter writer = MemoryClipboardWriter();
      final ExpandBridge bridge = _bridge(clipboard: writer);
      final String text = await bridge.expandToClipboard(
        doc: _doc('clip: {{clipboard}}'),
        clipboardText: 'from-clip',
      );
      expect(text, 'clip: from-clip');
      expect(writer.lastWritten, 'clip: from-clip');
    });

    test('clipboardReader fills {{clipboard}} when vars omit it', () async {
      final MemoryClipboardWriter writer = MemoryClipboardWriter();
      final ExpandBridge bridge = _bridge(
        clipboard: writer,
        clipboardReader: () async => 'reader-clip',
      );
      final String text = await bridge.expandToClipboard(
        doc: _doc('clip: {{clipboard}}'),
      );
      expect(text, 'clip: reader-clip');
    });
  });

  group('expandViaHelper (graceful fallback, never throws)', () {
    test('helper success types text, degraded=false', () async {
      final MemoryClipboardWriter writer = MemoryClipboardWriter();
      final FakeExpandHelper helper = FakeExpandHelper();
      final ExpandBridge bridge = _bridge(
        clipboard: writer,
        helper: helper,
        platform: ExpandPlatform.windows,
      );
      final ExpandResult result = await bridge.expandViaHelper(
        doc: _doc('hello {{date}}'),
      );
      expect(result.degraded, isFalse);
      expect(result.method, 'helper');
      expect(result.text, 'hello 2026-09-30');
      expect(helper.lastTyped, 'hello 2026-09-30');
      expect(writer.lastWritten, isNull);
    });

    test('helper throw falls back to clipboard, degraded=true', () async {
      final MemoryClipboardWriter writer = MemoryClipboardWriter();
      final FakeExpandHelper helper =
          FakeExpandHelper(throwOnType: 'SendInput denied');
      final ExpandBridge bridge = _bridge(
        clipboard: writer,
        helper: helper,
        platform: ExpandPlatform.windows,
      );
      final ExpandResult result = await bridge.expandViaHelper(
        doc: _doc('fallback me'),
      );
      expect(result.degraded, isTrue);
      expect(result.method, 'clipboard');
      expect(result.note, 'helper-error');
      expect(result.text, 'fallback me');
      expect(writer.lastWritten, 'fallback me');
    });

    test('missing helper degrades to clipboard, app unaffected', () async {
      final MemoryClipboardWriter writer = MemoryClipboardWriter();
      final ExpandBridge bridge = _bridge(
        clipboard: writer,
        platform: ExpandPlatform.macos,
      );
      final ExpandResult result = await bridge.expandViaHelper(
        doc: _doc('no helper here'),
      );
      expect(result.degraded, isTrue);
      expect(result.note, 'helper-missing');
      expect(writer.lastWritten, 'no helper here');
    });

    test('wayland skips helper entirely (clipboard-only)', () async {
      final MemoryClipboardWriter writer = MemoryClipboardWriter();
      final FakeExpandHelper helper = FakeExpandHelper();
      final ExpandBridge bridge = _bridge(
        clipboard: writer,
        helper: helper,
        platform: ExpandPlatform.linuxWayland,
      );
      final ExpandResult result = await bridge.expandViaHelper(
        doc: _doc('wayland text'),
      );
      expect(result.degraded, isTrue);
      expect(result.method, 'clipboard');
      expect(result.note, 'wayland-typing-unsupported');
      expect(helper.calls, 0);
      expect(writer.lastWritten, 'wayland text');
    });

    test('clipboard write failure still returns text, never throws',
        () async {
      final ExpandBridge bridge = _bridge(
        clipboard: ThrowingClipboardWriter(),
        platform: ExpandPlatform.linuxX11,
      );
      final ExpandResult result = await bridge.expandViaHelper(
        doc: _doc('show me anyway'),
      );
      expect(result.degraded, isTrue);
      expect(result.text, 'show me anyway');
    });
  });

  group('TriggerStore CRUD', () {
    test('add / lookup / remove round-trip', () {
      final TriggerStore store = TriggerStore();
      expect(store.lookup(';review'), isNull);
      expect(
        store.add(trigger: ';review', promptId: 'prompt-1'),
        isNull,
      );
      expect(store.lookup(';review'), 'prompt-1');
      expect(store.remove(';review'), isTrue);
      expect(store.lookup(';review'), isNull);
      expect(store.remove(';review'), isFalse);
    });

    test('rebind overwrites, returns previous id', () {
      final TriggerStore store = TriggerStore();
      store.add(trigger: ';r', promptId: 'a');
      expect(store.add(trigger: ';r', promptId: 'b'), 'a');
      expect(store.lookup(';r'), 'b');
    });

    test('empty / whitespace triggers rejected', () {
      final TriggerStore store = TriggerStore();
      expect(() => store.add(trigger: '', promptId: 'a'),
          throwsFormatException);
      expect(() => store.add(trigger: '   ', promptId: 'a'),
          throwsFormatException);
      expect(() => store.add(trigger: ';my trig', promptId: 'a'),
          throwsFormatException);
      expect(() => store.add(trigger: ';ok', promptId: '  '),
          throwsFormatException);
    });

    test('lookup/remove tolerate invalid input (null/false, no throw)', () {
      final TriggerStore store = TriggerStore();
      expect(store.lookup('  '), isNull);
      expect(store.remove('has space'), isFalse);
    });

    test('toJson / fromJson round-trip', () {
      final TriggerStore store = TriggerStore();
      store.add(trigger: ';a', promptId: 'id-a');
      store.add(trigger: ';b', promptId: 'id-b');
      final TriggerStore back =
          TriggerStore.fromJson(store.toJson());
      expect(back.lookup(';a'), 'id-a');
      expect(back.lookup(';b'), 'id-b');
    });

    test('save/load file round-trip; missing file is empty', () async {
      final Directory tmp =
          await Directory.systemTemp.createTemp('expand_test_');
      try {
        final String path = '${tmp.path}/triggers.json';
        expect((await TriggerStore.loadFromFile(path)).isEmpty, isTrue);
        final TriggerStore store = TriggerStore();
        store.add(trigger: ';x', promptId: 'idx');
        await store.saveToFile(path);
        final TriggerStore back = await TriggerStore.loadFromFile(path);
        expect(back.lookup(';x'), 'idx');
      } finally {
        await tmp.delete(recursive: true);
      }
    });
  });
}
