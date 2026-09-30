/// WP6 tests: HotkeyService register/unregister, conflicts, add flow order.
import 'package:flutter_test/flutter_test.dart';
import 'package:ice_cream_rss_reader/promptlib/hotkey_service.dart';
import 'package:ice_cream_rss_reader/promptlib/selection_capture.dart';
import 'package:ice_cream_rss_reader/promptlib/shortcut_config.dart';

class _FakeCapture extends BaseSelectionCapture {
  String? selection;
  int selectionCalls = 0;
  int clipboardCalls = 0;
  _FakeCapture({this.selection, super.clipboard});

  @override
  Future<String?> getSelectedText() async {
    selectionCalls++;
    return selection;
  }

  @override
  Future<String?> getClipboardFallback() async {
    clipboardCalls++;
    return super.getClipboardFallback();
  }
}

HotkeyService _service({
  String? selection,
  String? clipboard,
  List<String>? opened,
  DateTime? now,
}) {
  return HotkeyService(
    backend: InMemoryHotkeyBackend(),
    capture: _FakeCapture(
      selection: selection,
      clipboard: MemoryClipboardReader(clipboard),
    ),
    openAddPrompt: (String text) {
      opened?.add(text);
      return text;
    },
    nowForPlaceholders: now == null ? null : () => now,
  );
}

void main() {
  group('register / unregister', () {
    test('registers summon + addPrompt and exposes bindings', () async {
      final HotkeyService svc = _service();
      await svc.register(summon: 'ctrl+shift+p', addPrompt: 'ctrl+shift+n');
      expect(svc.bindings[HotkeyService.summonId], 'ctrl+shift+p');
      expect(svc.bindings[HotkeyService.addPromptId], 'ctrl+shift+n');
      await svc.dispose();
    });

    test('unregister(id) removes one binding; unregister() clears all',
        () async {
      final HotkeyService svc = _service();
      await svc.register(summon: 'ctrl+shift+p', addPrompt: 'ctrl+shift+n');
      await svc.unregister(id: HotkeyService.summonId);
      expect(svc.bindings.containsKey(HotkeyService.summonId), isFalse);
      expect(svc.bindings.containsKey(HotkeyService.addPromptId), isTrue);
      await svc.unregister();
      expect(svc.bindings, isEmpty);
      await svc.dispose();
    });

    test('summon press fires onSummon (search palette entry point)',
        () async {
      final InMemoryHotkeyBackend backend = InMemoryHotkeyBackend();
      final HotkeyService svc = HotkeyService(
        backend: backend,
        capture: _FakeCapture(),
      );
      await svc.register(summon: 'ctrl+shift+p');
      final Future<void> fired = svc.onSummon.first;
      backend.press(HotkeyService.summonId);
      await fired;
      await svc.dispose();
      await backend.dispose();
    });

    test('per-category register fires onCategorySummon with slug', () async {
      final InMemoryHotkeyBackend backend = InMemoryHotkeyBackend();
      final HotkeyService svc = HotkeyService(
        backend: backend,
        capture: _FakeCapture(),
      );
      await svc.registerCategoryShortcut('coding', 'ctrl+shift+1');
      final Future<String> fired = svc.onCategorySummon.first;
      backend.press(HotkeyService.categoryId('coding'));
      expect(await fired, 'coding');
      expect(await svc.unregisterCategory('coding'), isTrue);
      expect(await svc.unregisterCategory('coding'), isFalse);
      await svc.dispose();
      await backend.dispose();
    });
  });

  group('conflict report', () {
    test('second binding on same shortcut reports inUse with holder',
        () async {
      final HotkeyService svc = _service();
      await svc.register(summon: 'ctrl+shift+p');
      try {
        await svc.register(addPrompt: 'ctrl+shift+p');
        fail('expected HotkeyConflictException');
      } on HotkeyConflictException catch (e) {
        expect(e.reason, HotkeyConflictReason.inUse);
        expect(e.heldBy, HotkeyService.summonId);
      }
      await svc.dispose();
    });

    test('OS-reserved shortcut reports osReserved', () async {
      final HotkeyService svc = _service();
      try {
        await svc.register(summon: 'cmd+space');
        fail('expected HotkeyConflictException');
      } on HotkeyConflictException catch (e) {
        expect(e.reason, HotkeyConflictReason.osReserved);
      }
      await svc.dispose();
    });
  });

  group('add-prompt flow: capture first, clipboard fallback', () {
    test('selected text wins over clipboard', () async {
      final List<String> opened = <String>[];
      final HotkeyService svc =
          _service(selection: 'highlighted', clipboard: 'clip', opened: opened);
      final String text = await svc.handleAddPrompt();
      expect(text, 'highlighted');
      expect(opened, <String>['highlighted']);
      await svc.dispose();
    });

    test('empty selection falls back to clipboard', () async {
      final List<String> opened = <String>[];
      final HotkeyService svc =
          _service(selection: '', clipboard: 'clip text', opened: opened);
      expect(await svc.handleAddPrompt(), 'clip text');
      expect(opened, <String>['clip text']);
      await svc.dispose();
    });

    test('null selection + empty clipboard yields empty prefill', () async {
      final HotkeyService svc = _service(selection: null, clipboard: null);
      expect(await svc.handleAddPrompt(), isEmpty);
      await svc.dispose();
    });

    test('selection checked before clipboard (call order)', () async {
      final _FakeCapture capture = _FakeCapture(
        selection: 'sel',
        clipboard: MemoryClipboardReader('clip'),
      );
      final HotkeyService svc = HotkeyService(
        backend: InMemoryHotkeyBackend(),
        capture: capture,
      );
      await svc.handleAddPrompt();
      expect(capture.selectionCalls, 1);
      expect(capture.clipboardCalls, 1);
      await svc.dispose();
    });

    test('onAddPrompt stream emits prefilled text', () async {
      final HotkeyService svc =
          _service(selection: null, clipboard: 'from-clip');
      final Future<String> fired = svc.onAddPrompt.first;
      await svc.handleAddPrompt();
      expect(await fired, 'from-clip');
      await svc.dispose();
    });
  });

  group('placeholder substitution before prefill', () {
    final DateTime fixed = DateTime(2026, 9, 30);
    test('{{clipboard}} resolves against fallback clipboard', () async {
      final HotkeyService svc = _service(
        selection: 'note: {{clipboard}}',
        clipboard: 'pasted',
        now: fixed,
      );
      expect(await svc.handleAddPrompt(), 'note: pasted');
      await svc.dispose();
    });

    test('{{date}} resolves to yyyy-MM-dd', () async {
      final HotkeyService svc = _service(
        selection: 'log {{date}}',
        clipboard: null,
        now: fixed,
      );
      expect(await svc.handleAddPrompt(), 'log 2026-09-30');
      await svc.dispose();
    });
  });

  group('per-category rebind via ShortcutConfig', () {
    test('rebind + applyConfig registers category bindings', () async {
      final ShortcutConfig config = ShortcutConfig();
      config.rebindCategory('coding', 'ctrl+shift+1');
      config.rebindCategory('coding', 'ctrl+shift+2');
      expect(config.shortcutForCategory('coding'), 'ctrl+shift+2');

      final HotkeyService svc = _service();
      await svc.applyConfig(config);
      expect(
        svc.bindings[HotkeyService.categoryId('coding')],
        'ctrl+shift+2',
      );
      await svc.dispose();
    });

    test('rebind conflict raises StateError', () {
      final ShortcutConfig config = ShortcutConfig();
      expect(
        () => config.rebindCategory('x', config.summon),
        throwsStateError,
      );
      expect(
        () => config.rebindSummon(config.addPrompt),
        throwsStateError,
      );
    });

    test('config round-trips through JSON (persisted rebinds)', () {
      final ShortcutConfig config = ShortcutConfig();
      config.rebindSummon('ctrl+shift+l');
      config.rebindCategory('coding', 'ctrl+shift+1');
      final ShortcutConfig back =
          ShortcutConfig.fromJson(config.toJson());
      expect(back.summon, 'ctrl+shift+l');
      expect(back.shortcutForCategory('coding'), 'ctrl+shift+1');
    });
  });
}
