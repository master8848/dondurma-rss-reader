import 'dart:io';

import 'package:test/test.dart';
import 'package:ice_cream_rss_reader/services/open_in_service.dart';

ProcessResult ok(String exe, List<String> args) =>
    ProcessResult(0, 0, '', '');

ProcessResult fail(String exe, List<String> args) =>
    ProcessResult(0, 1, '', 'nope');

void main() {
  group('targetsFor', () {
    test('offers all five targets for a real path', () {
      expect(targetsFor('/tmp/x'), hasLength(5));
      expect(
        targetsFor('/tmp/x'),
        containsAll(OpenInTarget.values),
      );
    });

    test('offers nothing for null/blank paths', () {
      expect(targetsFor(null), isEmpty);
      expect(targetsFor(''), isEmpty);
      expect(targetsFor('   '), isEmpty);
    });
  });

  group('reveal command resolution per platform', () {
    test('macOS uses open -R', () {
      final chain = commandChain(
        OpenInTarget.reveal,
        '/tmp/skill',
        osOverride: 'macos',
      );
      expect(chain, hasLength(1));
      expect(chain.first.executable, 'open');
      expect(chain.first.args, ['-R', '/tmp/skill']);
    });

    test('linux opens the parent dir with xdg-open', () {
      final chain = commandChain(
        OpenInTarget.reveal,
        '/tmp/skills/pdf/SKILL.md',
        osOverride: 'linux',
      );
      expect(chain, hasLength(1));
      expect(chain.first.executable, 'xdg-open');
      expect(chain.first.args, ['/tmp/skills/pdf']);
    });

    test('windows uses explorer /select,', () {
      final chain = commandChain(
        OpenInTarget.reveal,
        r'C:\skills\pdf',
        osOverride: 'windows',
      );
      expect(chain, hasLength(1));
      expect(chain.first.executable, 'explorer');
      expect(chain.first.args, [r'/select,', r'C:\skills\pdf']);
    });
  });

  group('editor command resolution per platform', () {
    test('linux uses the bare CLI with no fallback', () {
      void check(OpenInTarget target, String cli) {
        final chain = commandChain(target, '/tmp/x', osOverride: 'linux');
        expect(chain, hasLength(1));
        expect(chain.first.executable, cli);
        expect(chain.first.args, ['/tmp/x']);
      }

      check(OpenInTarget.zed, 'zed');
      check(OpenInTarget.sublime, 'subl');
      check(OpenInTarget.vscode, 'code');
    });

    test('macOS adds an open -a bundle fallback after the CLI', () {
      void check(OpenInTarget target, String cli, String bundle) {
        final chain = commandChain(target, '/tmp/x', osOverride: 'macos');
        expect(chain, hasLength(2));
        expect(chain.first.executable, cli);
        expect(chain.first.args, ['/tmp/x']);
        expect(chain.last.executable, 'open');
        expect(chain.last.args, ['-a', bundle, '/tmp/x']);
      }

      check(OpenInTarget.zed, 'zed', 'Zed');
      check(OpenInTarget.sublime, 'subl', 'Sublime Text');
      check(OpenInTarget.vscode, 'code', 'Visual Studio Code');
    });

    test('copyPath has no command chain (widget-owned clipboard)', () {
      expect(
        commandChain(OpenInTarget.copyPath, '/tmp/x', osOverride: 'macos'),
        isEmpty,
      );
    });
  });

  group('openWith', () {
    test('returns true when the primary command succeeds', () async {
      final seen = <String>[];
      final result = await openWith(
        OpenInTarget.vscode,
        '/tmp/x',
        osOverride: 'linux',
        runner: (exe, args) async {
          seen.add(exe);
          return ok(exe, args);
        },
      );
      expect(result, isTrue);
      expect(seen, ['code']);
    });

    test('macOS falls back to open -a when the CLI fails', () async {
      final seen = <String>[];
      final result = await openWith(
        OpenInTarget.zed,
        '/tmp/x',
        osOverride: 'macos',
        runner: (exe, args) async {
          seen.add(exe);
          return exe == 'zed' ? fail(exe, args) : ok(exe, args);
        },
      );
      expect(result, isTrue);
      expect(seen, ['zed', 'open']);
    });

    test('returns false when every command fails, never throws', () async {
      final result = await openWith(
        OpenInTarget.sublime,
        '/tmp/x',
        osOverride: 'macos',
        runner: (exe, args) async => fail(exe, args),
      );
      expect(result, isFalse);
    });

    test('returns false when the runner throws, never throws', () async {
      final result = await openWith(
        OpenInTarget.reveal,
        '/tmp/x',
        osOverride: 'macos',
        runner: (exe, args) async => throw const OSError('no binary'),
      );
      expect(result, isFalse);
    });

    test('copyPath returns false (handled by the widget clipboard)', () async {
      var called = false;
      final result = await openWith(
        OpenInTarget.copyPath,
        '/tmp/x',
        runner: (exe, args) async {
          called = true;
          return ok(exe, args);
        },
      );
      expect(result, isFalse);
      expect(called, isFalse);
    });
  });

  group('labels', () {
    test('reveal label follows the OS', () {
      expect(
        labelFor(OpenInTarget.reveal, osOverride: 'macos'),
        'Reveal in Finder',
      );
      expect(
        labelFor(OpenInTarget.reveal, osOverride: 'windows'),
        'Show in Explorer',
      );
      expect(
        labelFor(OpenInTarget.reveal, osOverride: 'linux'),
        'Show in file manager',
      );
    });

    test('editor and copy labels', () {
      expect(labelFor(OpenInTarget.zed), 'Open in Zed');
      expect(labelFor(OpenInTarget.sublime), 'Open in Sublime Text');
      expect(labelFor(OpenInTarget.vscode), 'Open in VS Code');
      expect(labelFor(OpenInTarget.copyPath), 'Copy path');
    });
  });

  group('existsOnDisk + parentDirOf', () {
    test('real temp file and dir exist; missing path does not', () {
      final dir = Directory.systemTemp.createTempSync('open_in_test');
      try {
        final file = File('${dir.path}/a.md')..writeAsStringSync('x');
        expect(existsOnDisk(dir.path), isTrue);
        expect(existsOnDisk(file.path), isTrue);
        expect(existsOnDisk('${dir.path}/missing.md'), isFalse);
        expect(existsOnDisk(''), isFalse);
      } finally {
        dir.deleteSync(recursive: true);
      }
    });

    test('parentDirOf strips the last segment', () {
      expect(parentDirOf('/a/b/c.md'), '/a/b');
      expect(parentDirOf(r'C:\a\b'), r'C:\a');
      expect(parentDirOf('bare'), 'bare');
    });
  });

  group('default persist roundtrip (in-memory store, fake-Hive style)', () {
    test('defaults to reveal when nothing persisted', () {
      expect(OpenInDefaultStore().value, OpenInTarget.reveal);
      expect(OpenInDefaultStore(persistedName: null).value, OpenInTarget.reveal);
    });

    test('restores a persisted name', () {
      expect(
        OpenInDefaultStore(persistedName: 'vscode').value,
        OpenInTarget.vscode,
      );
    });

    test('unknown persisted names fall back to reveal', () {
      expect(
        OpenInDefaultStore(persistedName: 'not-a-target').value,
        OpenInTarget.reveal,
      );
    });

    test('menu pick updates the default AND persists it', () {
      // Models the split-button menu pick: execute + remember. The onSave
      // hook stands in for the Hive 'settings' box write; a fresh store
      // built from the saved name must restore the pick.
      final fakeHive = <String, String>{};
      final store = OpenInDefaultStore(
        persistedName: fakeHive['openInDefault'],
        onSave: (name) => fakeHive['openInDefault'] = name,
      );
      expect(store.value, OpenInTarget.reveal);

      store.select(OpenInTarget.sublime);

      expect(store.value, OpenInTarget.sublime);
      expect(fakeHive['openInDefault'], 'sublime');
      expect(
        OpenInDefaultStore(persistedName: fakeHive['openInDefault']).value,
        OpenInTarget.sublime,
      );
    });
  });

  group('openInTargetFromName', () {
    test('roundtrips every enum name', () {
      for (final t in OpenInTarget.values) {
        expect(openInTargetFromName(t.name), t);
      }
    });
  });
}
