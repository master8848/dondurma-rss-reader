/// "Open In" support: reveal a file/folder in the OS file manager or open it
/// in an external editor, with a remembered default target.
/// 
/// Pure Dart (`dart:io` only, no Flutter imports) so it stays unit-testable
/// with plain `dart test`, like everything else under `lib/promptlib/` and
/// `lib/services/skills/`.
library;

import 'dart:io';

/// Targets offered by the [OpenInButton] split button.
///
/// `copyPath` is resolved in the widget layer via [Clipboard] so this
/// service never touches Flutter — [openWith] returns `false` for it and
/// the caller handles the copy.
enum OpenInTarget { reveal, zed, sublime, vscode, copyPath }

/// Parses a persisted [OpenInTarget] name, falling back to [reveal] for
/// null/unknown values so older or corrupt settings never break the button.
OpenInTarget openInTargetFromName(String? name) {
  if (name == null || name.isEmpty) return OpenInTarget.reveal;
  for (final t in OpenInTarget.values) {
    if (t.name == name) return t;
  }
  return OpenInTarget.reveal;
}

/// Single OS command: executable + arguments.
typedef OpenInCommand = ({String executable, List<String> args});

/// Injected process runner (defaults to [Process.run]). Tests pass a fake.
typedef OpenInProcessRunner =
    Future<ProcessResult> Function(String executable, List<String> args);

/// All targets applicable to [path]. Empty/blank paths offer nothing; any
/// real candidate path offers the full menu — visibility is additionally
/// gated by [existsOnDisk] in the widget layer.
List<OpenInTarget> targetsFor(String? path) {
  if (path == null || path.trim().isEmpty) return const [];
  return OpenInTarget.values;
}

/// True when [path] is an existing file or directory. Never throws.
bool existsOnDisk(String path) {
  try {
    if (path.isEmpty) return false;
    return File(path).existsSync() || Directory(path).existsSync();
  } catch (_) {
    return false;
  }
}

/// Parent directory of [path] (handles both `/` and `\` separators).
/// Returns [path] itself when it has no parent segment.
String parentDirOf(String path) {
  final idx = path.lastIndexOf(RegExp(r'[/\\]'));
  if (idx <= 0) return path;
  return path.substring(0, idx);
}

/// Human label for [target]. The reveal label follows the host OS
/// ([osOverride] injects `'macos'`, `'linux'`, or `'windows'` in tests).
String labelFor(OpenInTarget target, {String? osOverride}) {
  switch (target) {
    case OpenInTarget.reveal:
      return switch (_os(osOverride)) {
        'macos' => 'Reveal in Finder',
        'windows' => 'Show in Explorer',
        _ => 'Show in file manager',
      };
    case OpenInTarget.zed:
      return 'Open in Zed';
    case OpenInTarget.sublime:
      return 'Open in Sublime Text';
    case OpenInTarget.vscode:
      return 'Open in VS Code';
    case OpenInTarget.copyPath:
      return 'Copy path';
  }
}

/// Resolves the OS command chain for [target] + [path]: the primary command
/// first, then fallbacks. On macOS, editor CLIs fall back to
/// `open -a <Bundle>` when the CLI is missing. Returns an empty list for
/// [OpenInTarget.copyPath] (widget-owned clipboard action).
List<OpenInCommand> commandChain(
  OpenInTarget target,
  String path, {
  String? osOverride,
}) {
  final os = _os(osOverride);
  switch (target) {
    case OpenInTarget.reveal:
      return switch (os) {
        'macos' => [
          (executable: 'open', args: ['-R', path]),
        ],
        'windows' => [
          (executable: 'explorer', args: ['/select,', path]),
        ],
        _ => [
          (executable: 'xdg-open', args: [parentDirOf(path)]),
        ],
      };
    case OpenInTarget.zed:
      return _editorChain(os, cli: 'zed', bundle: 'Zed', path: path);
    case OpenInTarget.sublime:
      return _editorChain(os, cli: 'subl', bundle: 'Sublime Text', path: path);
    case OpenInTarget.vscode:
      return _editorChain(
        os,
        cli: 'code',
        bundle: 'Visual Studio Code',
        path: path,
      );
    case OpenInTarget.copyPath:
      return const [];
  }
}

List<OpenInCommand> _editorChain(
  String os, {
  required String cli,
  required String bundle,
  required String path,
}) {
  final primary = (executable: cli, args: [path]);
  if (os == 'macos') {
    return [primary, (executable: 'open', args: ['-a', bundle, path])];
  }
  return [primary];
}

/// Best-effort launcher: runs the [commandChain] in order and returns `true`
/// on the first `exitCode == 0`. Returns `false` (never throws) when every
/// command fails, the runner throws, or [target] is [OpenInTarget.copyPath].
Future<bool> openWith(
  OpenInTarget target,
  String path, {
  String? osOverride,
  OpenInProcessRunner runner = Process.run,
}) async {
  final chain = commandChain(target, path, osOverride: osOverride);
  if (chain.isEmpty) return false;
  for (final cmd in chain) {
    try {
      final result = await runner(cmd.executable, cmd.args);
      if (result.exitCode == 0) return true;
    } catch (_) {
      // Missing binary / spawn failure: try the next fallback.
    }
  }
  return false;
}

String _os(String? override) => override ?? Platform.operatingSystem;

/// Pure-Dart holder for the remembered default, used by the widget layer and
/// by plain-`dart test` tests.
///
/// Production wiring persists through the Hive `'settings'` box key
/// `'openInDefault'` (see `SettingsProvider.openInDefault`); tests inject a
/// fake via [onSave] / [persistedName] for the persist roundtrip without
/// needing Hive.
class OpenInDefaultStore {
  OpenInTarget value;
  final void Function(String name)? onSave;

  OpenInDefaultStore({String? persistedName, this.onSave})
    : value = openInTargetFromName(persistedName);

  /// Selects [target] as the new default and persists its name.
  /// Models the split-button menu pick: execute + remember.
  void select(OpenInTarget target) {
    value = target;
    onSave?.call(target.name);
  }
}
