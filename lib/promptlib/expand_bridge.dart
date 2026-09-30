/// `ExpandBridge` — quick-expand core (WP7, pure-Dart).
///
/// Goal: typing a short trigger in any app expands to the full prompt text.
/// Only the pure-Dart core lives here; per-OS typing is done by a native
/// helper behind [ExpandHelper] (platform-channel stub, no native code in
/// this repo).
///
/// Per-OS status (v1):
/// * Windows (first): native side synthesizes keystrokes with `SendInput`
///   (via `package:win32`) after placing the text on the clipboard as a
///   fallback. Requires foreground focus; UAC-elevated windows cannot be
///   typed into — clipboard fallback covers that case.
/// * macOS (second): native side posts `CGEvent`s (or `AXUIElementSetAttributeValue`
///   paste) into the previously focused app. Requires Accessibility (AX)
///   trust; when untrusted the helper throws/returns an error and this core
///   falls back to clipboard (same degrade path as a missing helper).
/// * Linux X11 (third): native side uses XTest (`XTestFakeKeyEvent`) to type.
///   Clipboard fallback always works.
/// * Linux Wayland: documented unsupported for synthetic typing — the core
///   protocol gates key injection behind compositor-private portals, so this
///   core goes straight to clipboard (`method == 'clipboard'`,
///   `degraded == true`, note `wayland-typing-unsupported`) and never calls
///   the helper.
///
/// Minimal placeholders: `{{clipboard}}` and `{{date}}` (`yyyy-MM-dd`).
/// Unknown `{{tokens}}` are left literal so the editor/user can fill them;
/// [missingVariables] lists every referenced name with no value (except
/// `date`, which is always auto-provided).
///
/// Failure policy: the helper path ([expandViaHelper]) never throws — any
/// helper failure (missing helper, throw, unsupported platform) falls back
/// to clipboard (best-effort) and returns [ExpandResult.degraded] == true,
/// so the rest of the app is unaffected.
///
/// Never imports `package:flutter/*` (WP1/WP2/WP6 convention): the clipboard
/// and the helper are injected so this core stays unit-testable without a
/// Flutter SDK. The app layer adapts `Clipboard.setData` / `MethodChannel`
/// (`promptlib/expand`, method `typeText`) to these interfaces.
library;

import 'dart:async';

import 'prompt_doc.dart';

/// Matches `{{name}}` with optional inner whitespace (`{{ clipboard }}`).
/// Names are `[A-Za-z0-9_]+`; anything else (e.g. `{{foo-bar}}`) is left
/// untouched and never reported by [ExpandBridge.missingVariables].
final RegExp expandTokenPattern = RegExp(r'\{\{\s*([A-Za-z0-9_]+)\s*\}\}');

/// Formats [date] as `yyyy-MM-dd` for the `{{date}}` placeholder.
String formatExpandDate(DateTime date) {
  return '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';
}

/// Injectable clipboard sink. The app layer implements this with
/// `Clipboard.setData(ClipboardData(text: ...))`; tests use fakes.
abstract class ClipboardWriter {
  Future<void> writeText(String text);
}

/// In-memory clipboard sink for tests and headless hosts.
class MemoryClipboardWriter implements ClipboardWriter {
  String? lastWritten;
  int writes = 0;

  @override
  Future<void> writeText(String text) async {
    lastWritten = text;
    writes++;
  }
}

/// A clipboard writer that always fails (for degraded-path tests).
class ThrowingClipboardWriter implements ClipboardWriter {
  final Object error;
  ThrowingClipboardWriter([this.error = 'clipboard unavailable']);

  @override
  Future<void> writeText(String text) async {
    throw StateError('$error');
  }
}

/// Native typing helper (platform-channel stub).
///
/// The real native side types [text] into the previously focused app:
/// Windows `SendInput`, macOS `CGEvent` (+ AX trust), Linux X11 XTest.
/// Implemented by the app layer over `MethodChannel('promptlib/expand')`
/// method `typeText`; tests inject fakes. Any throw means "could not type" —
/// [ExpandBridge.expandViaHelper] catches it and degrades to clipboard.
abstract class ExpandHelper {
  Future<void> typeText(String text);
}

/// In-memory helper for tests: records typed text, optionally throws.
class FakeExpandHelper implements ExpandHelper {
  String? lastTyped;
  int calls = 0;

  /// When non-null, [typeText] throws this instead of recording.
  Object? throwOnType;

  FakeExpandHelper({this.throwOnType});

  @override
  Future<void> typeText(String text) async {
    calls++;
    if (throwOnType != null) {
      throw StateError('${throwOnType!}');
    }
    lastTyped = text;
  }
}

/// Target platform for [ExpandBridge.expandViaHelper].
///
/// Wayland never attempts helper typing (clipboard-only by design); all
/// other values attempt the injected [ExpandHelper] when one is present.
enum ExpandPlatform {
  windows,
  macos,
  linuxX11,
  linuxWayland,
  other,
}

/// Outcome of [ExpandBridge.expandViaHelper].
class ExpandResult {
  /// The fully rendered text (what was typed or copied).
  final String text;

  /// True when the helper could not be used and the clipboard fallback ran
  /// (helper missing/threw, Wayland, or clipboard-only host). The rest of
  /// the app should treat this as "prompt is on the clipboard, tell the
  /// user to paste" instead of an error.
  final bool degraded;

  /// `'helper'` when the native helper typed the text, `'clipboard'` when
  /// the clipboard fallback ran.
  final String method;

  /// Machine-readable hint (`helper-missing`, `helper-error`,
  /// `wayland-typing-unsupported`, `clipboard-write-failed`, or null on a
  /// clean helper run).
  final String? note;

  const ExpandResult({
    required this.text,
    required this.degraded,
    required this.method,
    this.note,
  });

  @override
  String toString() =>
      'ExpandResult(method: $method, degraded: $degraded, note: $note)';
}

/// Quick-expand coordinator: render + clipboard + helper-with-fallback.
class ExpandBridge {
  /// Clipboard sink used by [expandToClipboard] and the degraded path.
  final ClipboardWriter clipboard;

  /// Native typing helper. Null = clipboard-only host (helper missing);
  /// every expand then degrades gracefully instead of throwing.
  final ExpandHelper? helper;

  /// Target platform; [ExpandPlatform.linuxWayland] skips the helper.
  final ExpandPlatform platform;

  /// Optional clipboard source used to fill `{{clipboard}}` when the caller
  /// did not pass an explicit value. Best-effort: null/throw means empty.
  /// The app layer wires `Clipboard.getData`; tests inject closures.
  final Future<String?> Function()? clipboardReader;

  /// Injectable clock for `{{date}}` (defaults to `DateTime.now`).
  final DateTime Function()? nowProvider;

  ExpandBridge({
    required this.clipboard,
    this.helper,
    this.platform = ExpandPlatform.other,
    this.clipboardReader,
    this.nowProvider,
  });

  DateTime _now(DateTime? override) {
    if (override != null) return override;
    final DateTime Function()? provider = nowProvider;
    if (provider != null) return provider();
    return DateTime.now();
  }

  /// Renders [doc.body], substituting placeholders from [variables]:
  /// * `date` is always auto-provided (`yyyy-MM-dd`); an explicit
  ///   `variables['date']` overrides the clock.
  /// * `clipboard` uses `variables['clipboard']` when present; otherwise
  ///   the literal is left in place (see [missingVariables]).
  /// * any other `{{name}}` uses `variables[name]` when present, else is
  ///   left literal.
  String render({
    required PromptDoc doc,
    required Map<String, String> variables,
    DateTime? now,
  }) {
    final Map<String, String> effective = Map<String, String>.from(variables);
    effective.putIfAbsent('date', () => formatExpandDate(_now(now)));
    return doc.body.replaceAllMapped(expandTokenPattern, (Match m) {
      final String name = m.group(1)!;
      final String? value = effective[name];
      if (value == null) return m.group(0)!;
      return value;
    });
  }

  /// Lists variable names referenced in [doc.body] that have no value in
  /// [provided]. `date` is never listed (always auto-provided). Order is
  /// first-seen, deduplicated.
  List<String> missingVariables({
    required PromptDoc doc,
    required Map<String, String> provided,
  }) {
    final List<String> missing = <String>[];
    final Set<String> seen = <String>{};
    for (final Match m in expandTokenPattern.allMatches(doc.body)) {
      final String name = m.group(1)!;
      if (name == 'date') continue;
      if (provided.containsKey(name)) continue;
      if (seen.add(name)) missing.add(name);
    }
    return missing;
  }

  /// Builds the effective variable map for an expand call: explicit
  /// [variables] win, then [clipboardText], then [clipboardReader]
  /// (best-effort, failures mean empty).
  Future<Map<String, String>> _effectiveVariables(
    Map<String, String> variables,
    String? clipboardText,
  ) async {
    final Map<String, String> effective =
        Map<String, String>.from(variables);
    if (!effective.containsKey('clipboard')) {
      if (clipboardText != null) {
        effective['clipboard'] = clipboardText;
      } else if (clipboardReader != null) {
        try {
          effective['clipboard'] = await clipboardReader!() ?? '';
        } catch (_) {
          effective['clipboard'] = '';
        }
      }
    }
    return effective;
  }

  /// Renders [doc] and writes the result to the clipboard. Returns the
  /// rendered text. Throws only when the clipboard write itself fails
  /// (use [expandViaHelper] for the never-throws path).
  Future<String> expandToClipboard({
    required PromptDoc doc,
    Map<String, String> variables = const <String, String>{},
    DateTime? now,
    String? clipboardText,
  }) async {
    final Map<String, String> effective =
        await _effectiveVariables(variables, clipboardText);
    final String text = render(doc: doc, variables: effective, now: now);
    await clipboard.writeText(text);
    return text;
  }

  /// Tries the native helper, degrading to clipboard on any failure — never
  /// throws, so a missing/broken helper leaves the rest of the app
  /// unaffected. Returns [ExpandResult] with `degraded == false` only when
  /// the helper actually typed the text.
  Future<ExpandResult> expandViaHelper({
    required PromptDoc doc,
    Map<String, String> variables = const <String, String>{},
    DateTime? now,
    String? clipboardText,
  }) async {
    final Map<String, String> effective =
        await _effectiveVariables(variables, clipboardText);
    final String text = render(doc: doc, variables: effective, now: now);

    if (platform == ExpandPlatform.linuxWayland) {
      await _bestEffortClipboard(text);
      return ExpandResult(
        text: text,
        degraded: true,
        method: 'clipboard',
        note: 'wayland-typing-unsupported',
      );
    }

    final ExpandHelper? typed = helper;
    if (typed == null) {
      await _bestEffortClipboard(text);
      return ExpandResult(
        text: text,
        degraded: true,
        method: 'clipboard',
        note: 'helper-missing',
      );
    }

    try {
      await typed.typeText(text);
      return ExpandResult(
        text: text,
        degraded: false,
        method: 'helper',
        note: null,
      );
    } catch (_) {
      await _bestEffortClipboard(text);
      return ExpandResult(
        text: text,
        degraded: true,
        method: 'clipboard',
        note: 'helper-error',
      );
    }
  }

  /// Clipboard fallback that never throws (records nothing on failure).
  Future<void> _bestEffortClipboard(String text) async {
    try {
      await clipboard.writeText(text);
    } catch (_) {
      // Degraded path must not throw: the text is still returned in the
      // ExpandResult so the caller can show it for manual copy.
    }
  }
}
