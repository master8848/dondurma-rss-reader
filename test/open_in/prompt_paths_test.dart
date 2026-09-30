/// Resolver tests: PromptDoc/category+slug → absolute disk path.
///
/// Pure-Dart (`package:test`, no Flutter, no disk I/O — the registry calls
/// use memory-only registries and fake roots; existence stays `existsOnDisk`
/// in the widget layer).
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:ice_cream_rss_reader/promptlib/prompt_doc.dart';
import 'package:ice_cream_rss_reader/promptlib/prompt_paths.dart';
import 'package:ice_cream_rss_reader/promptlib/repo_mapping.dart';

String _join(List<String> parts) => parts.join(Platform.pathSeparator);

PromptDoc _doc({String id = 'doc-1', String title = 'My Note'}) =>
    PromptDoc(id: id, title: title);

Future<RepoRegistry> _registryWithTeamRepo() async {
  final RepoRegistry reg = RepoRegistry();
  await reg.addRepo(
    const RepoRecord(repoId: 'team', localPath: 'team'),
  );
  await reg.addRepo(
    const RepoRecord(repoId: 'other', localPath: 'other'),
  );
  return reg;
}

void main() {
  const String root = '/tmp/promptlib-test-root';

  group('promptFilePath: category+slug mapping', () {
    test('unbound category maps to prompts/<category>/<slug>.md', () {
      final String? p = promptFilePath(
        _doc(),
        root: root,
        category: 'coding',
        fileSlug: 'my-note',
      );
      expect(
        p,
        _join([root, 'prompts', 'coding', 'my-note.md']),
      );
    });

    test('title-derived stem matches the store write path', () {
      // Same stem PromptStore.save/saveToCategory use for new files.
      final String? p = promptFilePath(
        _doc(title: 'Review Session Notes'),
        root: root,
        category: 'coding',
      );
      expect(
        p,
        _join([root, 'prompts', 'coding', 'review-session-notes.md']),
      );
    });

    test('bound (precreated) category resolves through its repo', () async {
      final RepoRegistry reg = await _registryWithTeamRepo();
      await reg.bind(categorySlug: 'coding', repoId: 'team');
      final String? p = promptFilePath(
        _doc(),
        root: root,
        registry: reg,
        category: 'coding',
        fileSlug: 'my-note',
      );
      expect(
        p,
        _join([root, 'team', 'prompts', 'coding', 'my-note.md']),
      );
    });
  });

  group('renamed categories follow the binding', () {
    test('migrated category resolves to the new repo dir', () async {
      final RepoRegistry reg = await _registryWithTeamRepo();
      await reg.bind(categorySlug: 'coding', repoId: 'team');
      // Fake root: source dir does not exist, so only the binding moves
      // (no I/O) — exactly the post-rename state.
      await reg.migrateCategory(
        categorySlug: 'coding',
        targetRepoId: 'other',
        rootOverride: root,
      );
      final String? p = promptFilePath(
        _doc(),
        root: root,
        registry: reg,
        category: 'coding',
        fileSlug: 'my-note',
      );
      expect(
        p,
        _join([root, 'other', 'prompts', 'coding', 'my-note.md']),
      );
    });

    test('dangling binding (repo removed) falls back to default dir',
        () async {
      final RepoRegistry reg = await _registryWithTeamRepo();
      await reg.bind(categorySlug: 'coding', repoId: 'team');
      await reg.removeRepo('team');
      final String? p = promptFilePath(
        _doc(),
        root: root,
        registry: reg,
        category: 'coding',
        fileSlug: 'my-note',
      );
      expect(
        p,
        _join([root, 'prompts', 'coding', 'my-note.md']),
      );
    });
  });

  group('legacy library + offline mirrors', () {
    test('no category/feed maps to legacy library/*.md', () {
      final String? p = promptFilePath(
        _doc(),
        root: root,
        fileSlug: 'my-note',
      );
      expect(p, _join([root, 'library', 'my-note.md']));
    });

    test('path-escaping category falls back to library, never throws', () {
      for (final String bad in <String>['a/b', '..', '']) {
        final String? p = promptFilePath(
          _doc(),
          root: root,
          category: bad,
          fileSlug: 'my-note',
        );
        expect(p, _join([root, 'library', 'my-note.md']),
            reason: 'category "$bad"');
      }
    });

    test('feedSlug maps to the subscriptions offline mirror', () {
      final String? p = promptFilePath(
        _doc(title: 'Fetched Item'),
        root: root,
        feedSlug: 'Example Prompts',
        fileSlug: 'fetched-item',
      );
      expect(
        p,
        _join([root, 'subscriptions', 'example-prompts', 'fetched-item.md']),
      );
    });

    test('category wins over feedSlug (prompts scope beats subscriptions)',
        () {
      final String? p = promptFilePath(
        _doc(),
        root: root,
        category: 'coding',
        feedSlug: 'some-feed',
        fileSlug: 'my-note',
      );
      expect(
        p,
        _join([root, 'prompts', 'coding', 'my-note.md']),
      );
    });
  });

  group('unresolvable → null', () {
    test('blank root returns null', () {
      expect(
        promptFilePath(_doc(), root: '  ', fileSlug: 'x'),
        isNull,
      );
    });

    test('resolvePromptDir throws ArgumentError on blank root', () {
      expect(
        () => resolvePromptDir(root: ''),
        throwsArgumentError,
      );
    });

    test('explicit blank fileSlug + untitled prompt still slugifies the id',
        () {
      // slugifyTitle never returns empty (falls back to 'untitled'), so a
      // doc always yields a stem; only the root gates null here.
      final String? p = promptFilePath(
        _doc(title: ''),
        root: root,
        fileSlug: '   ',
      );
      expect(p, isNotNull);
      expect(p, endsWith('.md'));
    });
  });

  group('resolvePromptDir', () {
    test('matches PromptStore.resolveCategoryDir for bound categories',
        () async {
      final RepoRegistry reg = await _registryWithTeamRepo();
      await reg.bind(categorySlug: 'coding', repoId: 'team');
      expect(
        resolvePromptDir(
            root: root, registry: reg, category: 'Coding'),
        reg.resolveCategoryDir('coding', rootOverride: root),
      );
    });
  });
}
