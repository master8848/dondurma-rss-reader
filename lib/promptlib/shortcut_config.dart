/// `ShortcutConfig` — rebindable shortcut registry for WP6 (pure-Dart).
///
/// Holds the global summon shortcut (library search palette), the add-prompt
/// shortcut (highlight-to-add), and per-category search shortcuts. Persisted
/// via [toJson]/[fromJson] so the UI/settings layer can store it in the
/// Hive `settings` box (or `.promptlib/` file) without this core caring.
///
/// Shortcut format: `ctrl+shift+p` — one or more modifiers joined with `+`
/// plus exactly one main key, all case-insensitive, stored normalized
/// lowercase. Allowed modifiers: `ctrl`, `cmd`/`meta`/`super` (normalized to
/// `cmd`), `alt`/`option` (normalized to `alt`), `shift`. Everything else in
/// a segment is treated as the main key.
///
/// Never imports `package:flutter/*` (WP1/WP2 convention).
library;

const String defaultSummonShortcut = 'ctrl+shift+p';
const String defaultAddPromptShortcut = 'ctrl+shift+n';

const Set<String> _modifierAliases = <String>{
  'ctrl',
  'control',
  'cmd',
  'meta',
  'super',
  'command',
  'alt',
  'option',
  'shift',
};

String _normalizeModifier(String segment) {
  switch (segment) {
    case 'control':
      return 'ctrl';
    case 'command':
    case 'meta':
    case 'super':
      return 'cmd';
    case 'option':
      return 'alt';
    default:
      return segment;
  }
}

/// Normalizes a shortcut string (`Ctrl+Shift+P` → `ctrl+shift+p`).
///
/// Throws [FormatException] when the string has no main key (modifiers only
/// or empty) or is otherwise malformed.
String normalizeShortcut(String shortcut) {
  final List<String> segments = shortcut
      .split('+')
      .map((String s) => s.trim().toLowerCase())
      .where((String s) => s.isNotEmpty)
      .toList();
  if (segments.isEmpty) {
    throw FormatException('Empty shortcut', shortcut);
  }
  final List<String> modifiers = <String>[];
  String? mainKey;
  for (final String segment in segments) {
    if (_modifierAliases.contains(segment)) {
      final String mod = _normalizeModifier(segment);
      if (!modifiers.contains(mod)) {
        modifiers.add(mod);
      }
    } else {
      if (mainKey != null) {
        throw FormatException(
          'Multiple main keys in shortcut: "$shortcut"',
          shortcut,
        );
      }
      mainKey = segment;
    }
  }
  if (mainKey == null) {
    throw FormatException(
      'Shortcut has modifiers but no main key: "$shortcut"',
      shortcut,
    );
  }
  modifiers.sort();
  return <String>[...modifiers, mainKey].join('+');
}

/// Rebindable shortcut registry: global summon + add-prompt + per-category.
///
/// Equality of shortcuts is by normalized form, so `Ctrl+Shift+P` and
/// `ctrl+shift+p` count as the same binding (conflict).
class ShortcutConfig {
  String _summon;
  String _addPrompt;
  final Map<String, String> _perCategory;

  ShortcutConfig({
    String summon = defaultSummonShortcut,
    String addPrompt = defaultAddPromptShortcut,
    Map<String, String>? perCategory,
  })  : _summon = normalizeShortcut(summon),
        _addPrompt = normalizeShortcut(addPrompt),
        _perCategory = <String, String>{
          if (perCategory != null)
            for (final MapEntry<String, String> e in perCategory.entries)
              e.key: normalizeShortcut(e.value),
        } {
    _assertNoInternalConflict();
  }

  String get summon => _summon;
  String get addPrompt => _addPrompt;

  /// Category slug → normalized shortcut. Returned copy is unmodifiable.
  Map<String, String> get perCategory =>
      Map<String, String>.unmodifiable(_perCategory);

  String? shortcutForCategory(String category) => _perCategory[category];

  void _assertNoInternalConflict() {
    if (_summon == _addPrompt) {
      throw StateError(
        'Summon and add-prompt shortcuts conflict: "$_summon"',
      );
    }
    final Set<String> seen = <String>{_summon, _addPrompt};
    for (final MapEntry<String, String> e in _perCategory.entries) {
      if (!seen.add(e.value)) {
        throw StateError(
          'Shortcut "${e.value}" for category "${e.key}" conflicts '
          'with another binding',
        );
      }
    }
  }

  /// Rebind the global summon (search palette) shortcut. Returns the
  /// normalized binding. Throws [StateError] on conflict with another
  /// binding, [FormatException] on malformed input.
  String rebindSummon(String shortcut) {
    final String normalized = normalizeShortcut(shortcut);
    if (normalized == _addPrompt || _perCategory.containsValue(normalized)) {
      throw StateError('Shortcut "$normalized" is already bound');
    }
    _summon = normalized;
    return _summon;
  }

  /// Rebind the add-prompt (highlight-to-add) shortcut. Same errors as
  /// [rebindSummon].
  String rebindAddPrompt(String shortcut) {
    final String normalized = normalizeShortcut(shortcut);
    if (normalized == _summon || _perCategory.containsValue(normalized)) {
      throw StateError('Shortcut "$normalized" is already bound');
    }
    _addPrompt = normalized;
    return _addPrompt;
  }

  /// Bind (or rebind) a per-category search shortcut. Same errors as
  /// [rebindSummon].
  String rebindCategory(String category, String shortcut) {
    final String normalized = normalizeShortcut(shortcut);
    if (normalized == _summon || normalized == _addPrompt) {
      throw StateError('Shortcut "$normalized" is already bound');
    }
    for (final MapEntry<String, String> e in _perCategory.entries) {
      if (e.key != category && e.value == normalized) {
        throw StateError(
          'Shortcut "$normalized" is already bound to "${e.key}"',
        );
      }
    }
    _perCategory[category] = normalized;
    return normalized;
  }

  /// Removes a per-category binding. Returns true when one existed.
  bool removeCategory(String category) => _perCategory.remove(category) != null;

  Map<String, Object?> toJson() => <String, Object?>{
        'summon': _summon,
        'addPrompt': _addPrompt,
        'perCategory': Map<String, String>.from(_perCategory),
      };

  factory ShortcutConfig.fromJson(Map<String, Object?> json) {
    final Object? rawCats = json['perCategory'];
    return ShortcutConfig(
      summon: (json['summon'] as String?) ?? defaultSummonShortcut,
      addPrompt: (json['addPrompt'] as String?) ?? defaultAddPromptShortcut,
      perCategory: rawCats is Map
          ? <String, String>{
              for (final MapEntry<Object?, Object?> e in rawCats.entries)
                e.key.toString(): (e.value as String),
            }
          : null,
    );
  }
}
