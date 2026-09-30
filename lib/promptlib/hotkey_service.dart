/// `HotkeyService` — desktop global summon + add-prompt flow (WP6, pure-Dart).
///
/// ARCHITECTURE.md section 6 contract:
/// * `register(summon + addPrompt shortcuts)` — OS global hotkeys
///   (Windows/macOS/Linux only; no mobile in v1).
/// * `onSummon` — app shows/focuses the `/library` search palette.
/// * `onAddPrompt` — emits the prefilled add-prompt text:
///   `SelectionCaptureService.getSelectedText()` first, fallback to
///   `getClipboardFallback()`; non-empty result opens/pre-fills the
///   Add-Prompt editor via the injected [openAddPrompt].
///
/// hotkey_manager wiring (approved: `hotkey_manager: 0.2.3` + tray_manager):
/// this core never imports `package:hotkey_manager/*` (or flutter) so it
/// stays unit-testable without a Flutter SDK (WP1/WP2 convention, and
/// `flutter pub` is intentionally never run on these branches). The app
/// layer adapts hotkey_manager to [HotkeyBackend]:
/// ```dart
/// class HotkeyManagerBackend implements HotkeyBackend {
///   final Map<String, HotKey> _keys = {};
///   @override
///   Future<void> register(String id, String shortcut) async {
///     await hotkeyManager.register(
///       HotKey(identifier: id, key: ..., modifiers: ...,
///         scope: HotKeyScope.system), // OS-global, not in-app
///       keyDownHandler: (_) => _dispatch(id),
///     );
///   }
///   ...
/// }
/// ```
/// `HotKeyScope.system` is required — the default in-app scope only fires
/// while the window is focused, which defeats global summon. See also
/// tray_manager for the tray-context-menu entry points that call the same
/// [handleSummon]/[handleAddPrompt] entry points.
///
/// Conflict detection: [register] throws [HotkeyConflictException] when the
/// requested shortcut is already bound in this service ([reason] `inUse`) or
/// is a well-known OS-reserved binding ([reason] `osReserved`). Callers
/// report the conflict (toast/dialog) instead of silently overriding the OS.
library;

import 'dart:async';

import 'selection_capture.dart';
import 'shortcut_config.dart' show normalizeShortcut;
import 'shortcut_config.dart' as config show ShortcutConfig;

/// Why a registration was refused.
enum HotkeyConflictReason {
  /// Already bound by this service (summon/add-prompt/category).
  inUse,

  /// Known OS-reserved binding (would steal a system shortcut).
  osReserved,
}

/// Thrown by [HotkeyService.register]/[registerCategoryShortcut] on conflict.
class HotkeyConflictException implements Exception {
  final String shortcut;
  final HotkeyConflictReason reason;
  final String? heldBy;

  const HotkeyConflictException({
    required this.shortcut,
    required this.reason,
    this.heldBy,
  });

  @override
  String toString() =>
      'HotkeyConflictException: "$shortcut" refused '
      '(${reason.name}${heldBy != null ? ', held by $heldBy' : ''})';
}

/// OS-reserved shortcuts this service refuses to steal. Small curated set —
/// the app layer may extend it per OS (e.g. macOS Spotlight `cmd+space`).
const Set<String> osReservedShortcuts = <String>{
  'cmd+space', // macOS Spotlight / launchers
  'alt+tab', // window switcher
  'ctrl+alt+delete', // Windows secure attention
  'cmd+tab', // macOS app switcher
  'alt+f4', // window close (Windows/Linux)
};

/// Platform adapter implemented by the app layer with hotkey_manager.
/// [onPressed] fires with the binding id whenever the OS delivers the key.
abstract class HotkeyBackend {
  Future<void> register(String id, String shortcut);
  Future<void> unregister(String id);
  Stream<String> get onPressed;
}

/// In-memory backend for tests and headless hosts. [press] simulates the
/// OS delivering a global key press.
class InMemoryHotkeyBackend implements HotkeyBackend {
  final Map<String, String> bindings = <String, String>{};
  final StreamController<String> _pressed =
      StreamController<String>.broadcast();

  @override
  Future<void> register(String id, String shortcut) async {
    bindings[id] = shortcut;
  }

  @override
  Future<void> unregister(String id) async {
    bindings.remove(id);
  }

  /// Simulate an OS global key press for binding [id].
  void press(String id) {
    if (bindings.containsKey(id)) {
      _pressed.add(id);
    }
  }

  @override
  Stream<String> get onPressed => _pressed.stream;

  Future<void> dispose() => _pressed.close();
}

/// Desktop global-hotkey coordinator.
class HotkeyService {
  static const String summonId = 'promptlib.summon';
  static const String addPromptId = 'promptlib.addPrompt';
  static String categoryId(String category) => 'promptlib.category.$category';

  final HotkeyBackend _backend;
  final SelectionCaptureService _capture;

  /// Opens/pre-fills the Add-Prompt editor. Injected so the core has no UI
  /// dependency; the app layer routes to the editor screen. Defaults to a
  /// no-op returning the text (useful in tests via [onAddPrompt]).
  final FutureOr<String> Function(String initialText)? openAddPrompt;

  /// Clock injected for deterministic `{{date}}` placeholder tests.
  final DateTime Function()? nowForPlaceholders;

  final StreamController<void> _summon =
      StreamController<void>.broadcast();
  final StreamController<String> _addPrompt =
      StreamController<String>.broadcast();
  final StreamController<String> _category =
      StreamController<String>.broadcast();

  final Map<String, String> _bindings = <String, String>{};
  late final StreamSubscription<String> _backendSub;
  bool _disposed = false;

  HotkeyService({
    required HotkeyBackend backend,
    required SelectionCaptureService capture,
    this.openAddPrompt,
    this.nowForPlaceholders,
  })  : _backend = backend,
        _capture = capture {
    _backendSub = _backend.onPressed.listen((String id) {
      if (id == summonId) {
        handleSummon();
      } else if (id == addPromptId) {
        unawaited(handleAddPrompt());
      } else if (id.startsWith('promptlib.category.')) {
        if (!_category.isClosed) {
          _category.add(id.substring('promptlib.category.'.length));
        }
      }
    });
  }

  /// Fires when the summon hotkey is pressed — app shows/focuses the
  /// `/library` search palette.
  Stream<void> get onSummon => _summon.stream;

  /// Fires with the prefilled text when the add-prompt hotkey is pressed.
  Stream<String> get onAddPrompt => _addPrompt.stream;

  /// Fires with the category slug when a per-category search hotkey fires.
  Stream<String> get onCategorySummon => _category.stream;

  /// Currently registered bindings: binding id → normalized shortcut.
  Map<String, String> get bindings =>
      Map<String, String>.unmodifiable(_bindings);

  void _checkConflict(String normalized, String id) {
    for (final MapEntry<String, String> e in _bindings.entries) {
      if (e.value == normalized && e.key != id) {
        throw HotkeyConflictException(
          shortcut: normalized,
          reason: HotkeyConflictReason.inUse,
          heldBy: e.key,
        );
      }
    }
    if (osReservedShortcuts.contains(normalized)) {
      throw HotkeyConflictException(
        shortcut: normalized,
        reason: HotkeyConflictReason.osReserved,
      );
    }
  }

  /// Registers the summon (search palette) and add-prompt shortcuts.
  ///
  /// Either may be null to leave that binding untouched. Throws
  /// [HotkeyConflictException] on internal or OS-reserved conflict, and
  /// [FormatException] on malformed shortcut strings.
  Future<void> register({String? summon, String? addPrompt}) async {
    _ensureLive();
    if (summon != null) {
      final String normalized = normalizeShortcut(summon);
      _checkConflict(normalized, summonId);
      if (_bindings[summonId] != normalized) {
        await _backend.register(summonId, normalized);
        _bindings[summonId] = normalized;
      }
    }
    if (addPrompt != null) {
      final String normalized = normalizeShortcut(addPrompt);
      _checkConflict(normalized, addPromptId);
      if (_bindings[addPromptId] != normalized) {
        await _backend.register(addPromptId, normalized);
        _bindings[addPromptId] = normalized;
      }
    }
  }

  /// Registers a per-category search shortcut (rebindable; see
  /// `ShortcutConfig.rebindCategory`). Throws [HotkeyConflictException] on
  /// conflict.
  Future<void> registerCategoryShortcut(
    String category,
    String shortcut,
  ) async {
    _ensureLive();
    final String normalized = normalizeShortcut(shortcut);
    final String id = categoryId(category);
    _checkConflict(normalized, id);
    if (_bindings[id] != normalized) {
      await _backend.register(id, normalized);
      _bindings[id] = normalized;
    }
  }

  /// Applies a whole [config.ShortcutConfig] (summon + add-prompt +
  /// per-category) in one call.
  Future<void> applyConfig(config.ShortcutConfig config) async {
    await register(summon: config.summon, addPrompt: config.addPrompt);
    for (final MapEntry<String, String> e in config.perCategory.entries) {
      await registerCategoryShortcut(e.key, e.value);
    }
  }

  /// Removes one binding ([summonId]/[addPromptId]/category id) or, when
  /// [id] is null, all bindings.
  Future<void> unregister({String? id}) async {
    if (id != null) {
      await _backend.unregister(id);
      _bindings.remove(id);
      return;
    }
    final List<String> ids = _bindings.keys.toList();
    for (final String bindingId in ids) {
      await _backend.unregister(bindingId);
    }
    _bindings.clear();
  }

  /// Removes a per-category binding. Returns true when one existed.
  Future<bool> unregisterCategory(String category) async {
    final String id = categoryId(category);
    if (!_bindings.containsKey(id)) {
      return false;
    }
    await unregister(id: id);
    return true;
  }

  /// Summon entry point (also callable from tray_manager menu items).
  void handleSummon() {
    if (!_summon.isClosed) {
      _summon.add(null);
    }
  }

  /// Add-prompt entry point: selected text first, clipboard fallback, then
  /// placeholder substitution, then [openAddPrompt]. Returns the prefilled
  /// text and emits it on [onAddPrompt].
  Future<String> handleAddPrompt() async {
    String? selection;
    try {
      selection = await _capture.getSelectedText();
    } catch (_) {
      selection = null;
    }
    String? clipboard;
    try {
      clipboard = await _capture.getClipboardFallback();
    } catch (_) {
      clipboard = null;
    }
    final String text = resolveAddPromptText(
      selection: selection,
      clipboardText: clipboard,
      now: nowForPlaceholders?.call(),
    );
    final Object? opened = openAddPrompt?.call(text);
    if (opened is Future) {
      await opened;
    }
    if (!_addPrompt.isClosed) {
      _addPrompt.add(text);
    }
    return text;
  }

  void _ensureLive() {
    if (_disposed) {
      throw StateError('HotkeyService is disposed');
    }
  }

  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    await _backendSub.cancel();
    await _summon.close();
    await _addPrompt.close();
    await _category.close();
  }
}
