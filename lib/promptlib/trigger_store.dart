/// `TriggerStore` — trigger → prompt-id map for quick expand (WP7, pure-Dart).
///
/// A trigger is the short string the user types in any app (e.g. `;review`)
/// that expands to the full prompt via [ExpandBridge]. This store owns the
/// map only; listening for keystrokes is the native helper's job (see
/// `expand_bridge.dart` per-OS notes).
///
/// Validation: triggers must be non-empty after trimming and must not
/// contain whitespace (whitespace would make the trigger untypable as a
/// single token). Violations throw [FormatException]. Prompt ids must be
/// non-empty. Rebinding an existing trigger to another prompt overwrites
/// (returns the previous prompt id, if any).
///
/// Lookup is by trimmed trigger, case-sensitive (so `;Review` and `;review`
/// can coexist; the UI layer may enforce its own casing policy).
///
/// Persistence: [toJson]/[fromJson] round-trip the map for the settings
/// layer (Hive `settings` box or `.promptlib/` file — this core does not
/// care); [saveToFile]/[loadFromFile] offer a direct JSON-file option.
/// A missing file loads as an empty store; malformed JSON throws
/// [FormatException].
library;

import 'dart:convert';
import 'dart:io';

/// Normalizes a trigger for storage/lookup: trims surrounding whitespace.
/// Throws [FormatException] on empty or whitespace-containing triggers.
String normalizeTrigger(String trigger) {
  final String trimmed = trigger.trim();
  if (trimmed.isEmpty) {
    throw FormatException('Trigger must not be empty', trigger);
  }
  if (RegExp(r'\s').hasMatch(trimmed)) {
    throw FormatException(
      'Trigger must not contain whitespace: "$trigger"',
      trigger,
    );
  }
  return trimmed;
}

/// Trigger → prompt-id map with validation and JSON (de)serialization.
class TriggerStore {
  final Map<String, String> _triggers = <String, String>{};

  TriggerStore();

  /// All bindings: trigger → prompt id. Returned map is unmodifiable.
  Map<String, String> get triggers =>
      Map<String, String>.unmodifiable(_triggers);

  /// Number of bindings.
  int get length => _triggers.length;

  bool get isEmpty => _triggers.isEmpty;

  /// Returns the prompt id bound to [trigger], or null when unbound.
  /// [trigger] is trimmed before lookup; invalid (empty/whitespace)
  /// triggers look up as null instead of throwing.
  String? lookup(String trigger) {
    final String trimmed = trigger.trim();
    if (trimmed.isEmpty || RegExp(r'\s').hasMatch(trimmed)) {
      return null;
    }
    return _triggers[trimmed];
  }

  /// Binds [trigger] to [promptId], overwriting any existing binding.
  /// Returns the previous prompt id, or null when the trigger was unbound.
  /// Throws [FormatException] on invalid trigger or empty prompt id.
  String? add({required String trigger, required String promptId}) {
    final String normalized = normalizeTrigger(trigger);
    if (promptId.trim().isEmpty) {
      throw FormatException('promptId must not be empty', promptId);
    }
    return _replace(normalized, promptId);
  }

  String? _replace(String normalized, String promptId) {
    final String? previous = _triggers[normalized];
    _triggers[normalized] = promptId;
    return previous;
  }

  /// Removes the binding for [trigger]. Returns true when one existed.
  /// Invalid triggers return false instead of throwing.
  bool remove(String trigger) {
    final String trimmed = trigger.trim();
    if (trimmed.isEmpty || RegExp(r'\s').hasMatch(trimmed)) {
      return false;
    }
    return _triggers.remove(trimmed) != null;
  }

  /// Clears all bindings.
  void clear() => _triggers.clear();

  Map<String, Object?> toJson() => <String, Object?>{
        'version': 1,
        'triggers': Map<String, String>.from(_triggers),
      };

  factory TriggerStore.fromJson(Map<String, Object?> json) {
    final TriggerStore store = TriggerStore();
    final Object? raw = json['triggers'];
    if (raw is Map) {
      for (final MapEntry<Object?, Object?> e in raw.entries) {
        final String trigger = e.key.toString();
        final Object? value = e.value;
        if (value is String) {
          try {
            store.add(trigger: trigger, promptId: value);
          } on FormatException {
            // Skip invalid persisted entries instead of failing the load.
            continue;
          }
        }
      }
    }
    return store;
  }

  /// Writes this store as JSON to [path] (creates parent dirs as needed).
  Future<void> saveToFile(String path) async {
    final File file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(toJson()));
  }

  /// Loads a store from the JSON file at [path]. A missing file yields an
  /// empty store. Malformed JSON throws [FormatException].
  static Future<TriggerStore> loadFromFile(String path) async {
    final File file = File(path);
    if (!await file.exists()) {
      return TriggerStore();
    }
    final String raw = await file.readAsString();
    if (raw.trim().isEmpty) {
      return TriggerStore();
    }
    late final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException catch (e) {
      throw FormatException('TriggerStore file is not valid JSON: $e', raw);
    }
    if (decoded is! Map<String, Object?> && decoded is! Map) {
      throw FormatException('TriggerStore file must hold a JSON object', raw);
    }
    return TriggerStore.fromJson(
      Map<String, Object?>.from(decoded as Map),
    );
  }
}
