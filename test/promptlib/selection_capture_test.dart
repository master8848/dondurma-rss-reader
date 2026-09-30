/// WP6 tests: SelectionCaptureService per-OS behavior + prefill placeholders.
import 'package:test/test.dart';
import 'package:ice_cream_rss_reader/promptlib/selection_capture.dart';

void main() {
  group('macOS capture (platform-channel stub)', () {
    test('returns native text when trusted', () async {
      final MacOsSelectionCapture capture = MacOsSelectionCapture(
        nativeRead: () async => 'selected in other app',
        isAccessibilityTrusted: () async => true,
      );
      expect(await capture.getSelectedText(), 'selected in other app');
    });

    test('returns null when untrusted (AX permission) — clipboard path runs',
        () async {
      final MacOsSelectionCapture capture = MacOsSelectionCapture(
        nativeRead: () async => 'should never surface',
        isAccessibilityTrusted: () async => false,
        clipboard: MemoryClipboardReader('fallback clip'),
      );
      expect(await capture.getSelectedText(), isNull);
      expect(await capture.getClipboardFallback(), 'fallback clip');
    });

    test('native throw degrades to null (never throws)', () async {
      final MacOsSelectionCapture capture = MacOsSelectionCapture(
        nativeRead: () async => throw StateError('channel error'),
        isAccessibilityTrusted: () async => true,
      );
      expect(await capture.getSelectedText(), isNull);
    });
  });

  group('Windows / Linux return null for now (later workstreams)', () {
    test('windows capture is null + clipboard fallback works', () async {
      final WindowsSelectionCapture capture = WindowsSelectionCapture(
        clipboard: MemoryClipboardReader('win clip'),
      );
      expect(await capture.getSelectedText(), isNull);
      expect(await capture.getClipboardFallback(), 'win clip');
    });

    test('linux capture is null + clipboard fallback works', () async {
      final LinuxSelectionCapture capture = LinuxSelectionCapture(
        clipboard: MemoryClipboardReader('linux clip'),
      );
      expect(await capture.getSelectedText(), isNull);
      expect(await capture.getClipboardFallback(), 'linux clip');
    });
  });

  group('clipboard fallback normalization', () {
    test('empty / whitespace-only clipboard yields null', () async {
      final WindowsSelectionCapture empty = WindowsSelectionCapture(
        clipboard: MemoryClipboardReader(''),
      );
      expect(await empty.getClipboardFallback(), isNull);
      final WindowsSelectionCapture spaces = WindowsSelectionCapture(
        clipboard: MemoryClipboardReader('   '),
      );
      expect(await spaces.getClipboardFallback(), isNull);
    });
  });

  group('resolveAddPromptText: capture-first-fallback order', () {
    test('selection wins', () {
      expect(
        resolveAddPromptText(selection: 'sel', clipboardText: 'clip'),
        'sel',
      );
    });

    test('empty selection falls back to clipboard', () {
      expect(
        resolveAddPromptText(selection: '', clipboardText: 'clip'),
        'clip',
      );
    });

    test('null selection + null clipboard yields empty string', () {
      expect(
        resolveAddPromptText(selection: null, clipboardText: null),
        isEmpty,
      );
    });
  });

  group('resolvePrefillPlaceholders', () {
    final DateTime fixed = DateTime(2026, 9, 30);
    test('{{clipboard}} substituted', () {
      expect(
        resolvePrefillPlaceholders('a {{clipboard}} b',
            clipboard: 'C', now: fixed),
        'a C b',
      );
    });

    test('{{date}} renders yyyy-MM-dd', () {
      expect(
        resolvePrefillPlaceholders('log {{date}}', clipboard: '', now: fixed),
        'log 2026-09-30',
      );
    });

    test('unknown {{variables}} left untouched', () {
      expect(
        resolvePrefillPlaceholders('hi {{name}}', clipboard: '', now: fixed),
        'hi {{name}}',
      );
    });
  });
}
