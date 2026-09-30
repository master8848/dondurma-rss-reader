/// `SelectionCaptureService` — per-OS selected-text capture (WP6, pure-Dart).
///
/// Contract (ARCHITECTURE.md section 8, DECISIONS.md D9): return the user's
/// current selection in the previously focused app, or `null` when no
/// selection is exposed. Never throws — returns `null` on permission denial,
/// unsupported control, or platform gap so the caller runs the clipboard
/// fallback instead.
///
/// Platform status (v1):
/// * macOS (first): native read goes through a platform-channel stub
///   ([MacOsSelectionCapture]). The native side reads
///   `kAXSelectedTextAttribute` on the focused `AXUIElement`
///   (`AXUIElementCopyAttributeValue` via `kAXFocusedUIElementAttribute`),
///   falling back to `kAXSelectedTextRangeAttribute` + `kAXValueAttribute`
///   when the control exposes a range but not the text slice. Requires
///   Accessibility trust (`AXIsProcessTrusted()`); when the process is
///   untrusted the stub returns `null` and the caller falls back to the
///   clipboard while surfacing a one-time "grant Accessibility permission"
///   hint (see [isAccessibilityTrusted], wired by the app layer).
/// * Windows (later): UI Automation `TextPattern.GetSelection()` /
///   `IUIAutomationTextPattern::GetSelection` on the focused element after
///   checking `SupportedTextSelection`. Many apps do not expose TextPattern,
///   so `null` + clipboard fallback is the normal path there.
/// * Linux (later): X11 `PRIMARY` selection (mirrors the highlight per ICCCM
///   convention). Wayland has no primary selection in the core protocol (the
///   `primary-selection` protocol is compositor-optional), so Wayland is
///   clipboard-only by design.
/// * Until the native sides land, [WindowsSelectionCapture] and
///   [LinuxSelectionCapture] return `null` unconditionally (documented
///   platform gap, QUESTIONS.md Tier-3).
///
/// Never imports `package:flutter/*` (WP1/WP2 convention): the clipboard is
/// injected via [ClipboardReader] so this core stays unit-testable without
/// Flutter. The app layer adapts `Clipboard.getData` / `MethodChannel` to
/// these interfaces.
library;

/// Injectable clipboard source. The app layer implements this with
/// `Clipboard.getData(Clipboard.kTextPlain)`; tests use fakes.
abstract class ClipboardReader {
  Future<String?> getText();
}

/// Trivial in-memory clipboard for tests and non-Flutter hosts.
class MemoryClipboardReader implements ClipboardReader {
  String? text;
  MemoryClipboardReader([this.text]);
  @override
  Future<String?> getText() async => text;
}

abstract class SelectionCaptureService {
  /// Currently selected text in the focused app, or null if none
  /// available / permission denied / platform unsupported. Never throws.
  Future<String?> getSelectedText();

  /// Universal fallback: current clipboard text (explicit copy), or null
  /// if empty. Never throws.
  Future<String?> getClipboardFallback();
}

/// Shared base: [getClipboardFallback] delegates to the injected
/// [ClipboardReader], normalizing empty/whitespace-only text to `null`.
/// Subclasses only implement [getSelectedText].
abstract class BaseSelectionCapture implements SelectionCaptureService {
  final ClipboardReader clipboard;
  BaseSelectionCapture({ClipboardReader? clipboard})
      : clipboard = clipboard ?? MemoryClipboardReader();

  @override
  Future<String?> getClipboardFallback() async {
    try {
      final String? text = await clipboard.getText();
      if (text == null || text.trim().isEmpty) {
        return null;
      }
      return text;
    } catch (_) {
      return null;
    }
  }
}

/// macOS (v1) capture via an injected native stub.
///
/// The real native side (Swift/MethodChannel `promptlib/selection`,
/// method `getSelectedText`) performs the AX reads described above. The
/// channel returns `null` when the process is not Accessibility-trusted
/// ([isAccessibilityTrusted] false) — the app layer should then show the
/// one-time System Settings → Privacy & Security → Accessibility hint and
/// let the clipboard fallback run.
class MacOsSelectionCapture extends BaseSelectionCapture {
  /// Native AX read; `null` = no selection / untrusted / unsupported.
  /// Injected so unit tests never touch a MethodChannel.
  final Future<String?> Function() nativeRead;

  /// Whether the process is AX-trusted (`AXIsProcessTrusted()`).
  /// The app layer wires the real check; defaults to false (deny-safe).
  final Future<bool> Function() isAccessibilityTrusted;

  MacOsSelectionCapture({
    required this.nativeRead,
    Future<bool> Function()? isAccessibilityTrusted,
    super.clipboard,
  }) : isAccessibilityTrusted =
            isAccessibilityTrusted ?? (() async => false);

  @override
  Future<String?> getSelectedText() async {
    try {
      if (!await isAccessibilityTrusted()) {
        return null;
      }
      final String? text = await nativeRead();
      if (text == null || text.isEmpty) {
        return null;
      }
      return text;
    } catch (_) {
      return null;
    }
  }
}

/// Windows capture — later workstream (UIA TextPattern). Always `null` for
/// now so the add-prompt flow falls back to the clipboard.
class WindowsSelectionCapture extends BaseSelectionCapture {
  WindowsSelectionCapture({super.clipboard});
  @override
  Future<String?> getSelectedText() async => null;
}

/// Linux capture — later workstream (X11 PRIMARY; Wayland clipboard-only).
/// Always `null` for now so the add-prompt flow falls back to the clipboard.
class LinuxSelectionCapture extends BaseSelectionCapture {
  LinuxSelectionCapture({super.clipboard});
  @override
  Future<String?> getSelectedText() async => null;
}

/// Placeholder-aware prefill resolution for the add-prompt editor.
///
/// Order (ARCHITECTURE.md section 8 pseudocode): selected text first, then
/// clipboard fallback, then empty string. After the source text is chosen,
/// `{{clipboard}}` and `{{date}}` placeholders are substituted so a captured
/// template like `Summarize: {{clipboard}} ({{date}})` prefills correctly.
///
/// * [selection] — result of `getSelectedText()` (null/empty = miss).
/// * [clipboardText] — result of `getClipboardFallback()`.
/// * [now] — injectable clock for `{{date}}` (defaults to `DateTime.now()`).
///   `{{date}}` renders as `yyyy-MM-dd`.
String resolveAddPromptText({
  required String? selection,
  required String? clipboardText,
  DateTime? now,
}) {
  final String raw;
  if (selection != null && selection.isNotEmpty) {
    raw = selection;
  } else {
    raw = clipboardText ?? '';
  }
  return resolvePrefillPlaceholders(
    raw,
    clipboard: clipboardText ?? '',
    now: now,
  );
}

/// Substitutes `{{clipboard}}` and `{{date}}` (yyyy-MM-dd) in [template].
/// Unknown `{{variables}}` are left untouched for the editor to fill.
String resolvePrefillPlaceholders(
  String template, {
  required String clipboard,
  DateTime? now,
}) {
  final DateTime date = now ?? DateTime.now();
  final String dateStr =
      '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';
  return template
      .replaceAll('{{clipboard}}', clipboard)
      .replaceAll('{{date}}', dateStr);
}
