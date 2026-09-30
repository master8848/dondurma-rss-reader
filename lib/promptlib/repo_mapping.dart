/// RepoMapping abstraction: which repo owns each prompt category (repomap).
///
/// Pure-Dart (`dart:io` only, no Flutter). Any category maps to either one
/// shared repo or its own repo — the choice is per category, recorded as a
/// [RepoBinding]. Files only: prompt repos hold Markdown (never RSS).
///
/// Layout contract:
/// * `<root>/prompts/<category>/<slug>.md` — the live file (in-place edits
///   bump `version` in this same file).
/// * `<root>/prompts/<category>/<slug>.v<N>.md` — optional optimize
///   snapshots; same `id` as the live file, `version` N, `supersedes` set to
///   the previous file (repo-relative when under the store root).
/// * `<root>/.promptlib/category.yaml` — category display metadata
///   (`categories: [{slug, displayName}]`).
/// * `<root>/.promptlib/repos.yaml` + `<root>/.promptlib/bindings.yaml` —
///   checked-in mirrors of the in-memory registry below.
///
/// The in-memory maps are Hive-friendly on purpose ("Hive-style"): a Hive
/// box can persist [toJson] directly and rehydrate via [RepoRegistry.fromJson];
/// the YAML files are the human-readable, git-synced mirror. [load]/[persist]
/// move between the two; [bind]/[unbind]/[migrateCategory] keep them in sync
/// whenever the registry knows its [root].
///
/// Binding resolution never throws for bad *data*: a binding that points at
/// an unknown repo falls back to the default local dir
/// (`<root>/prompts/<slug>/`). Only bad *calls* (empty slugs, unknown target
/// repos on bind/migrate) throw.
library;

import 'dart:io';

import 'git_service.dart';

/// Directory holding per-category prompt folders under a store root.
const String promptsDirName = 'prompts';

/// Config directory holding the YAML mirrors under a store root.
const String promptlibConfigDir = '.promptlib';

/// Checked-in mirror of the repo records. See [RepoRegistry.persist].
const String reposFileName = 'repos.yaml';

/// Checked-in mirror of the category bindings. See [RepoRegistry.persist].
const String bindingsFileName = 'bindings.yaml';

/// Category display metadata file. See [RepoRegistry.ensureCategory].
const String categoryFileName = 'category.yaml';

/// One prompt repo: a git checkout (or plain folder) holding Markdown files.
///
/// [localPath] may be absolute or relative to the registry root (relative
/// paths resolve against the root passed to [RepoRegistry.load]). [remoteUrl]
/// may be empty for a local-only repo. [defaultBranch] defaults to `main`.
class RepoRecord {
  /// Stable id, e.g. `main` or `team-prompts`. Never derived from a path.
  final String repoId;

  /// Clone URL. Empty means local-only (no sync remote).
  final String remoteUrl;

  /// Checkout location: absolute, or relative to the registry root.
  final String localPath;

  /// Branch used for sync. Defaults to `main`.
  final String defaultBranch;

  const RepoRecord({
    required this.repoId,
    required this.localPath,
    this.remoteUrl = '',
    this.defaultBranch = 'main',
  });

  Map<String, Object?> toJson() => <String, Object?>{
        'repoId': repoId,
        'remoteUrl': remoteUrl,
        'localPath': localPath,
        'defaultBranch': defaultBranch,
      };

  /// Parses a record; unknown keys are ignored (forward compatibility).
  /// Throws [FormatException] when `repoId`/`localPath` are missing/blank.
  static RepoRecord fromJson(Map<String, Object?> json) {
    final String repoId = _asStr(json['repoId']).trim();
    final String localPath = _asStr(json['localPath']).trim();
    if (repoId.isEmpty) {
      throw const FormatException(
          'promptlib: repo entry is missing required `repoId`');
    }
    if (localPath.isEmpty) {
      throw FormatException(
          'promptlib: repo "$repoId" is missing required `localPath`');
    }
    final String remoteUrl =
        _asStr(json['remoteUrl']).trim();
    final String branch =
        _asStr(json['defaultBranch']).trim();
    return RepoRecord(
      repoId: repoId,
      localPath: localPath,
      remoteUrl: remoteUrl,
      defaultBranch: branch.isEmpty ? 'main' : branch,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RepoRecord && other.repoId == repoId;

  @override
  int get hashCode => repoId.hashCode;

  @override
  String toString() =>
      'RepoRecord(repoId: $repoId, localPath: $localPath, '
      'remoteUrl: $remoteUrl, defaultBranch: $defaultBranch)';
}

/// Binds one category to the repo (and path) that owns its Markdown files.
///
/// [pathInRepo] is repo-relative with `/` separators, e.g.
/// `prompts/coding`. [syncEnabled] defaults to `false`: bound files work
/// local-only until the user opts in.
class RepoBinding {
  /// Category slug, e.g. `coding`. Single path segment, lowercased.
  final String categorySlug;

  /// Owning repo id (see [RepoRecord.repoId]).
  final String repoId;

  /// Directory inside the repo holding the category's `.md` files.
  final String pathInRepo;

  /// Whether this category syncs (push/pull) with the repo remote.
  final bool syncEnabled;

  const RepoBinding({
    required this.categorySlug,
    required this.repoId,
    required this.pathInRepo,
    this.syncEnabled = false,
  });

  Map<String, Object?> toJson() => <String, Object?>{
        'categorySlug': categorySlug,
        'repoId': repoId,
        'pathInRepo': pathInRepo,
        'syncEnabled': syncEnabled,
      };

  /// Parses a binding; unknown keys are ignored. Throws [FormatException]
  /// when `categorySlug`/`repoId` are missing/blank or `syncEnabled` is not
  /// a bool.
  static RepoBinding fromJson(Map<String, Object?> json) {
    final String slug =
        RepoRegistry.normalizeSlug(_asStr(json['categorySlug']));
    final String repoId = _asStr(json['repoId']).trim();
    if (slug.isEmpty) {
      throw const FormatException(
          'promptlib: binding is missing required `categorySlug`');
    }
    if (repoId.isEmpty) {
      throw FormatException(
          'promptlib: binding for "$slug" is missing required `repoId`');
    }
    final Object? syncRaw = json['syncEnabled'];
    final bool sync;
    if (syncRaw == null) {
      sync = false;
    } else if (syncRaw is bool) {
      sync = syncRaw;
    } else if (syncRaw is String) {
      final String lower = syncRaw.trim().toLowerCase();
      if (lower == 'true') {
        sync = true;
      } else if (lower == 'false' || lower.isEmpty) {
        sync = false;
      } else {
        throw FormatException(
            'promptlib: binding for "$slug" has invalid `syncEnabled`: '
            '"$syncRaw" (expected true|false)');
      }
    } else {
      throw FormatException(
          'promptlib: binding for "$slug" has non-bool `syncEnabled`: '
          '"$syncRaw"');
    }
    final String pathRaw = _asStr(json['pathInRepo']).trim();
    return RepoBinding(
      categorySlug: slug,
      repoId: repoId,
      pathInRepo: pathRaw.isEmpty
          ? RepoRegistry.defaultPathInRepo(slug)
          : RepoRegistry.normalizeRepoPath(pathRaw),
      syncEnabled: sync,
    );
  }

  @override
  String toString() =>
      'RepoBinding(categorySlug: $categorySlug, repoId: $repoId, '
      'pathInRepo: $pathInRepo, syncEnabled: $syncEnabled)';
}

/// In-memory category→repo registry with YAML mirrors.
///
/// Create empty and [bind] repos, or [load] from a store root. When the
/// registry knows its [root] (via [load] or the constructor), [bind],
/// [unbind], [addRepo], [removeRepo], [migrateCategory], and
/// [ensureCategory] persist the YAML mirrors best-effort after mutating.
class RepoRegistry {
  final Map<String, RepoRecord> _repos = <String, RepoRecord>{};
  final Map<String, RepoBinding> _bindings = <String, RepoBinding>{};

  /// Store root the YAML mirrors live under, or `null` for memory-only.
  final String? root;

  RepoRegistry({this.root});

  /// Rehydrates from Hive-style JSON (`{'repos': [...], 'bindings': [...]}`).
  /// Unknown entries/keys are skipped only when they are structurally
  /// invalid maps; malformed scalar fields throw [FormatException].
  RepoRegistry.fromJson(Map<String, Object?> json, {String? root})
      : root = root ?? json['root'] as String? {
    final Object? repos = json['repos'];
    if (repos is List) {
      for (final Object? e in repos) {
        if (e is Map<String, Object?>) {
          final RepoRecord r = RepoRecord.fromJson(e);
          _repos[r.repoId] = r;
        }
      }
    }
    final Object? bindings = json['bindings'];
    if (bindings is List) {
      for (final Object? e in bindings) {
        if (e is Map<String, Object?>) {
          final RepoBinding b = RepoBinding.fromJson(e);
          _bindings[b.categorySlug] = b;
        }
      }
    }
  }

  /// Hive-style serialization (suitable for storing in a Hive box as-is).
  Map<String, Object?> toJson() => <String, Object?>{
        if (root != null) 'root': root,
        'repos': _repos.values.map((RepoRecord r) => r.toJson()).toList(),
        'bindings':
            _bindings.values.map((RepoBinding b) => b.toJson()).toList(),
      };

  /// Binding for [slug], or `null` when the category is unbound (callers
  /// fall back to `<root>/prompts/<slug>/`).
  RepoBinding? bindingFor(String slug) =>
      _bindings[normalizeSlug(slug)];

  /// Repo record for [repoId], or `null` when unknown.
  RepoRecord? repo(String repoId) => _repos[repoId.trim()];

  /// All known repos, sorted by id.
  List<RepoRecord> get allRepos {
    final List<RepoRecord> out = _repos.values.toList();
    out.sort((RepoRecord a, RepoRecord b) =>
        a.repoId.compareTo(b.repoId));
    return out;
  }

  /// All bindings, sorted by category slug.
  List<RepoBinding> get allBindings {
    final List<RepoBinding> out = _bindings.values.toList();
    out.sort((RepoBinding a, RepoBinding b) =>
        a.categorySlug.compareTo(b.categorySlug));
    return out;
  }

  /// Adds or replaces a repo record. Blank ids/paths throw [ArgumentError].
  Future<void> addRepo(RepoRecord record) async {
    if (record.repoId.trim().isEmpty) {
      throw ArgumentError('promptlib: repoId must not be empty');
    }
    if (record.localPath.trim().isEmpty) {
      throw ArgumentError(
          'promptlib: localPath must not be empty for repo '
          '"${record.repoId}"');
    }
    _repos[record.repoId] = record;
    await _autoPersist();
  }

  /// Removes a repo record. Bindings that referenced it are left in place;
  /// [resolveCategoryDir] falls back to the default local dir for dangling
  /// bindings (never crashes). No-op when unknown.
  Future<void> removeRepo(String repoId) async {
    _repos.remove(repoId.trim());
    await _autoPersist();
  }

  /// Binds [categorySlug] to [repoId] at [pathInRepo] (defaults to
  /// `prompts/<slug>`). Throws [StateError] when the repo is unknown
  /// (prevents typo'd dangling bindings) and [ArgumentError] on empty slugs
  /// or escaping paths. Persists mirrors when [root] is known.
  Future<void> bind({
    required String categorySlug,
    required String repoId,
    String? pathInRepo,
    bool syncEnabled = false,
  }) async {
    final String slug = normalizeSlug(categorySlug);
    if (slug.isEmpty) {
      throw ArgumentError('promptlib: categorySlug must not be empty');
    }
    final String rid = repoId.trim();
    if (!_repos.containsKey(rid)) {
      throw StateError(
          'promptlib: cannot bind "$slug" to unknown repo "$rid" '
          '(addRepo first)');
    }
    final String rawPath = (pathInRepo ?? '').trim();
    _bindings[slug] = RepoBinding(
      categorySlug: slug,
      repoId: rid,
      pathInRepo:
          rawPath.isEmpty ? defaultPathInRepo(slug) : normalizeRepoPath(rawPath),
      syncEnabled: syncEnabled,
    );
    await _autoPersist();
  }

  /// Removes the binding for [categorySlug]. Files stay where they are;
  /// the category simply resolves to the default local dir afterwards.
  /// No-op when unbound. Persists mirrors when [root] is known.
  Future<void> unbind(String categorySlug) async {
    _bindings.remove(normalizeSlug(categorySlug));
    await _autoPersist();
  }

  /// Filesystem directory owning [categorySlug]'s Markdown files.
  ///
  /// Bound categories resolve through their repo record
  /// (`localPath` + `pathInRepo`; relative localPaths resolve against the
  /// registry root). Unbound categories — and bindings whose repo was
  /// removed — fall back to `<root>/prompts/<slug>/`. Never throws for bad
  /// data; throws [StateError] when no root is known.
  String resolveCategoryDir(String categorySlug, {String? rootOverride}) {
    final String root = _effectiveRoot(rootOverride);
    final String slug = normalizeSlug(categorySlug);
    final RepoBinding? b = _bindings[slug];
    if (b == null) return defaultCategoryDir(root, slug);
    final RepoRecord? r = _repos[b.repoId];
    if (r == null) return defaultCategoryDir(root, slug);
    return joinRepoPath(root, r.localPath, b.pathInRepo);
  }

  /// Moves a category's Markdown files to another repo (or path) and
  /// re-points its binding — the single→multi and multi→single transitions
  /// are the same operation with different targets.
  ///
  /// Git-mv semantics: when [git] is provided and reports available, each
  /// file move is attempted with `git mv` inside its enclosing work tree so
  /// renames within one repo keep history (`git log --follow`); any git
  /// failure (different repos, not a checkout, binary missing) falls back
  /// to a plain filesystem move. Moves *across* repos are therefore plain
  /// moves by nature — history restarts in the target, and the source repo
  /// records deletions on its next commit. Only `*.md` files move; nothing
  /// else is touched, and nothing is deleted except as part of a move.
  ///
  /// Returns the destination paths moved. When the source dir is missing or
  /// identical to the destination, only the binding is updated and the
  /// result is empty. Throws [StateError] for unknown target repos or a
  /// missing root, [ArgumentError] for empty slugs/escaping paths.
  Future<List<String>> migrateCategory({
    required String categorySlug,
    required String targetRepoId,
    String? targetPathInRepo,
    GitService? git,
    String? rootOverride,
  }) async {
    final String root = _effectiveRoot(rootOverride);
    final String slug = normalizeSlug(categorySlug);
    if (slug.isEmpty) {
      throw ArgumentError('promptlib: categorySlug must not be empty');
    }
    final String rid = targetRepoId.trim();
    final RepoRecord? target = _repos[rid];
    if (target == null) {
      throw StateError(
          'promptlib: cannot migrate "$slug" to unknown repo "$rid"');
    }
    final String rawPath = (targetPathInRepo ?? '').trim();
    final String destRel = rawPath.isEmpty
        ? defaultPathInRepo(slug)
        : normalizeRepoPath(rawPath);
    final String sourceDir = resolveCategoryDir(slug, rootOverride: root);
    final String destDir = joinRepoPath(root, target.localPath, destRel);

    final bool same = _sameDir(sourceDir, destDir);
    final Directory src = Directory(sourceDir);
    final List<String> moved = <String>[];
    if (!same && await src.exists()) {
      await Directory(destDir).create(recursive: true);
      final List<File> files = <File>[];
      await for (final FileSystemEntity e
          in src.list(recursive: true, followLinks: false)) {
        if (e is File && e.path.toLowerCase().endsWith('.md')) {
          files.add(e);
        }
      }
      files.sort((File a, File b) => a.path.compareTo(b.path));
      final bool gitOk = await _gitAvailable(git);
      String? cachedTopLevel;
      bool topLevelProbed = false;
      for (final File f in files) {
        final String rel = _relativePath(sourceDir, f.path);
        final String dest = _join(destDir, rel);
        await Directory(_dirname(dest)).create(recursive: true);
        bool done = false;
        if (gitOk) {
          if (!topLevelProbed) {
            cachedTopLevel = await _gitTopLevel(sourceDir);
            topLevelProbed = true;
          }
          if (cachedTopLevel != null) {
            done = await _gitMv(cachedTopLevel, f.path, dest);
          }
        }
        if (!done) await _plainMove(f.path, dest);
        moved.add(dest);
      }
    }

    final bool? keepSync = _bindings[slug]?.syncEnabled;
    _bindings[slug] = RepoBinding(
      categorySlug: slug,
      repoId: rid,
      pathInRepo: destRel,
      syncEnabled: keepSync ?? false,
    );
    await _autoPersist();
    return moved;
  }

  /// Loads the registry from `<root>/.promptlib/repos.yaml` +
  /// `bindings.yaml`. Missing files yield an empty registry (fresh
  /// checkout); malformed files throw [FormatException]. Unknown keys are
  /// ignored.
  static Future<RepoRegistry> load(String root) async {
    final RepoRegistry reg = RepoRegistry(root: root);
    final File reposFile = File(reposPath(root));
    if (await reposFile.exists()) {
      for (final RepoRecord r
          in _parseRepos(await reposFile.readAsString())) {
        reg._repos[r.repoId] = r;
      }
    }
    final File bindingsFile = File(bindingsPath(root));
    if (await bindingsFile.exists()) {
      for (final RepoBinding b
          in _parseBindings(await bindingsFile.readAsString())) {
        reg._bindings[b.categorySlug] = b;
      }
    }
    return reg;
  }

  /// Writes the YAML mirrors under [rootOverride] (or [root]). Creates
  /// `.promptlib/` when absent. Throws [StateError] when no root is known.
  Future<void> persist([String? rootOverride]) async {
    final String root = _effectiveRoot(rootOverride);
    final Directory dir =
        Directory(_join(root, promptlibConfigDir));
    await dir.create(recursive: true);
    await File(reposPath(root)).writeAsString(_serializeRepos(allRepos));
    await File(bindingsPath(root))
        .writeAsString(_serializeBindings(allBindings));
  }

  /// Category metadata path: `<root>/.promptlib/category.yaml`.
  static String categoryMetaPath(String root) =>
      _join(_join(root, promptlibConfigDir), categoryFileName);

  /// Repos mirror path: `<root>/.promptlib/repos.yaml`.
  static String reposPath(String root) =>
      _join(_join(root, promptlibConfigDir), reposFileName);

  /// Bindings mirror path: `<root>/.promptlib/bindings.yaml`.
  static String bindingsPath(String root) =>
      _join(_join(root, promptlibConfigDir), bindingsFileName);

  /// Default dir for an unbound category: `<root>/prompts/<slug>/`.
  static String defaultCategoryDir(String root, String categorySlug) =>
      _join(_join(root, promptsDirName), normalizeSlug(categorySlug));

  /// Default in-repo path for a category: `prompts/<slug>`.
  static String defaultPathInRepo(String categorySlug) =>
      'prompts/${normalizeSlug(categorySlug)}';

  /// Normalizes a category slug: trimmed + lowercased. Rejects path
  /// separators, `..`, and empties by returning `''` (callers throw).
  static String normalizeSlug(String raw) {
    final String s = raw.trim().toLowerCase();
    if (s.isEmpty) return '';
    if (s.contains('/') ||
        s.contains('\\') ||
        s.split('/').contains('..') ||
        s == '.' ||
        s == '..') {
      return '';
    }
    return s;
  }

  /// Normalizes a repo-relative path: backslashes → `/`, collapses
  /// `.`/`..`/duplicate slashes. Throws [ArgumentError] on absolute or
  /// repo-escaping paths.
  static String normalizeRepoPath(String raw) {
    String p = raw.trim().replaceAll('\\', '/');
    while (p.startsWith('./')) {
      p = p.substring(2);
    }
    final List<String> kept = <String>[];
    for (final String seg in p.split('/')) {
      if (seg.isEmpty || seg == '.') continue;
      if (seg == '..') {
        throw ArgumentError(
            'promptlib: repo path escapes its repo: "$raw"');
      }
      kept.add(seg);
    }
    final String out = kept.join('/');
    if (out.isEmpty) {
      throw ArgumentError('promptlib: repo path must not be empty');
    }
    if (raw.trim().startsWith('/')) {
      throw ArgumentError(
          'promptlib: repo path must be relative, got "$raw"');
    }
    return out;
  }

  /// Upserts `{slug, displayName}` in `<root>/.promptlib/category.yaml`
  /// (single file holding every category). Creates the file when absent;
  /// preserves other entries and ignores unknown keys on read.
  Future<void> ensureCategory(String categorySlug,
      {String? displayName, String? rootOverride}) async {
    final String root = _effectiveRoot(rootOverride);
    final String slug = normalizeSlug(categorySlug);
    if (slug.isEmpty) {
      throw ArgumentError('promptlib: categorySlug must not be empty');
    }
    final Map<String, String> all = await readCategories(rootOverride: root);
    all[slug] = (displayName ?? '').trim().isEmpty
        ? (all[slug] ?? slug)
        : displayName!.trim();
    await writeCategories(all, rootOverride: root);
  }

  /// Reads `<root>/.promptlib/category.yaml` → `slug → displayName`.
  /// Missing file yields `{}`; malformed file throws [FormatException].
  Future<Map<String, String>> readCategories(
      {String? rootOverride}) async {
    final String root = _effectiveRoot(rootOverride);
    final File f = File(categoryMetaPath(root));
    if (!await f.exists()) return <String, String>{};
    return parseCategoryMeta(await f.readAsString());
  }

  /// Writes the whole category map (see [ensureCategory] for upserts).
  Future<void> writeCategories(Map<String, String> categories,
      {String? rootOverride}) async {
    final String root = _effectiveRoot(rootOverride);
    await Directory(_join(root, promptlibConfigDir)).create(recursive: true);
    await File(categoryMetaPath(root))
        .writeAsString(serializeCategoryMeta(categories));
  }

  /// Parses `category.yaml` text. Empty/blank yields `{}`.
  static Map<String, String> parseCategoryMeta(String yamlText) {
    final Map<String, String> out = <String, String>{};
    if (yamlText.trim().isEmpty) return out;
    final _YamlDoc doc = _parseSimpleYaml(yamlText, 'category.yaml');
    final List<Map<String, Object>> items = doc.listItems('categories');
    for (final Map<String, Object> fields in items) {
      final String slug = normalizeSlug(_asStr(fields['slug']));
      if (slug.isEmpty) {
        throw const FormatException(
            'promptlib: category.yaml entry is missing required `slug`');
      }
      final String name = _asStr(fields['displayName']).trim().isEmpty
          ? _asStr(fields['name'])
          : _asStr(fields['displayName']);
      out[slug] = name.trim().isEmpty ? slug : name.trim();
    }
    return out;
  }

  /// Serializes the category map to `category.yaml` text.
  static String serializeCategoryMeta(Map<String, String> categories) {
    final StringBuffer buf = StringBuffer()..writeln('categories:');
    final List<String> slugs = categories.keys.toList()..sort();
    if (slugs.isEmpty) return buf.toString();
    for (final String slug in slugs) {
      buf.writeln('  - slug: ${_yamlScalar(slug)}');
      buf.writeln(
          '    displayName: ${_yamlScalar(categories[slug] ?? slug)}');
    }
    return buf.toString();
  }

  // ---- internals ----

  String _effectiveRoot(String? override) {
    final String? r = override ?? root;
    if (r == null || r.trim().isEmpty) {
      throw StateError(
          'promptlib: RepoRegistry has no root (load(root) first or pass '
          'rootOverride)');
    }
    return r;
  }

  Future<void> _autoPersist() async {
    if (root == null) return;
    await persist();
  }

  static bool _isAbsolute(String p) =>
      p.startsWith('/') ||
      p.startsWith('\\') ||
      RegExp(r'^[A-Za-z]:[\\/]').hasMatch(p);

  /// Joins `<root>/<localPath>/<pathInRepo …>`; absolute localPaths ignore
  /// the root. `pathInRepo` segments split on `/` so Windows separators
  /// never leak in.
  static String joinRepoPath(
      String root, String localPath, String pathInRepo) {
    final List<String> parts = <String>[];
    if (_isAbsolute(localPath)) {
      parts.add(localPath);
    } else {
      parts.add(root);
      parts.add(localPath);
    }
    parts.addAll(pathInRepo.split('/').where((String s) => s.isNotEmpty));
    return parts.join(Platform.pathSeparator);
  }

  static String _join(String a, String b) {
    if (a.endsWith(Platform.pathSeparator)) return '$a$b';
    return '$a${Platform.pathSeparator}$b';
  }

  static String _dirname(String p) {
    final int i = p.lastIndexOf(Platform.pathSeparator);
    return i < 0 ? '.' : p.substring(0, i);
  }

  static bool _sameDir(String a, String b) {
    String norm(String p) {
      String n = p.replaceAll('\\', '/');
      while (n.endsWith('/') && n.length > 1) {
        n = n.substring(0, n.length - 1);
      }
      return n.toLowerCase();
    }

    return norm(a) == norm(b);
  }

  static String _relativePath(String dir, String path) {
    String norm(String p) => p.replaceAll('\\', '/');
    String d = norm(dir);
    if (!d.endsWith('/')) d = '$d/';
    final String n = norm(path);
    if (n.toLowerCase().startsWith(d.toLowerCase())) {
      return n.substring(d.length).replaceAll('/', Platform.pathSeparator);
    }
    final int i = path.lastIndexOf(Platform.pathSeparator);
    return i < 0 ? path : path.substring(i + 1);
  }

  /// Repo-relative path for [absPath] when under [root], else the basename.
  /// Used for `supersedes` links.
  static String relativeOrBase(String root, String absPath) {
    final String rel = _relativePath(root, absPath);
    if (rel.contains(Platform.pathSeparator) || !rel.contains('..')) {
      // _relativePath only strips the prefix when actually nested; a
      // returned basename means the file sits outside the root.
      final String normRoot =
          root.replaceAll('\\', '/').toLowerCase();
      final String normAbs =
          absPath.replaceAll('\\', '/').toLowerCase();
      if (normAbs.startsWith(
          normRoot.endsWith('/') ? normRoot : '$normRoot/')) {
        return rel.replaceAll(Platform.pathSeparator, '/');
      }
    }
    final int i = absPath.lastIndexOf(Platform.pathSeparator);
    return i < 0 ? absPath : absPath.substring(i + 1);
  }

  static Future<bool> _gitAvailable(GitService? git) async {
    if (git == null) return false;
    try {
      return await git.isGitAvailable;
    } catch (_) {
      return false;
    }
  }

  static Future<String?> _gitTopLevel(String dir) async {
    try {
      final ProcessResult r = await Process.run(
        'git',
        const ['rev-parse', '--show-toplevel'],
        workingDirectory: dir,
      );
      if (r.exitCode != 0) return null;
      final String out = '${r.stdout}'.trim();
      return out.isEmpty ? null : out;
    } catch (_) {
      return null;
    }
  }

  static Future<bool> _gitMv(
      String topLevel, String src, String dest) async {
    try {
      final ProcessResult r = await Process.run(
        'git',
        ['mv', src, dest],
        workingDirectory: topLevel,
      );
      return r.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  static Future<void> _plainMove(String src, String dest) async {
    try {
      await File(src).rename(dest);
      return;
    } on FileSystemException {
      // Cross-device rename: copy + delete.
      await File(dest).writeAsBytes(await File(src).readAsBytes());
      await File(src).delete();
    }
  }

  static List<RepoRecord> _parseRepos(String text) {
    if (text.trim().isEmpty) return <RepoRecord>[];
    final _YamlDoc doc = _parseSimpleYaml(text, 'repos.yaml');
    return doc
        .listItems('repos')
        .map<RepoRecord>(RepoRecord.fromJson)
        .toList();
  }

  static List<RepoBinding> _parseBindings(String text) {
    if (text.trim().isEmpty) return <RepoBinding>[];
    final _YamlDoc doc = _parseSimpleYaml(text, 'bindings.yaml');
    return doc
        .listItems('bindings')
        .map<RepoBinding>(RepoBinding.fromJson)
        .toList();
  }

  static String _serializeRepos(List<RepoRecord> repos) {
    final StringBuffer buf = StringBuffer()..writeln('repos:');
    for (final RepoRecord r in repos) {
      buf.writeln('  - repoId: ${_yamlScalar(r.repoId)}');
      buf.writeln('    remoteUrl: ${_yamlScalar(r.remoteUrl)}');
      buf.writeln('    localPath: ${_yamlScalar(r.localPath)}');
      buf.writeln('    defaultBranch: ${_yamlScalar(r.defaultBranch)}');
    }
    return buf.toString();
  }

  static String _serializeBindings(List<RepoBinding> bindings) {
    final StringBuffer buf = StringBuffer()..writeln('bindings:');
    for (final RepoBinding b in bindings) {
      buf.writeln('  - categorySlug: ${_yamlScalar(b.categorySlug)}');
      buf.writeln('    repoId: ${_yamlScalar(b.repoId)}');
      buf.writeln('    pathInRepo: ${_yamlScalar(b.pathInRepo)}');
      buf.writeln('    syncEnabled: ${b.syncEnabled}');
    }
    return buf.toString();
  }
}

/// Minimal line parser for the fixed-shape registry YAML files.
///
/// Covers exactly: a top-level `<key>:` header, `- ` items, and indented
/// `key: value` continuation lines (plus blank lines / `#` comments).
/// Anything else throws [FormatException]; unknown keys are preserved in the
/// field maps so callers can ignore them.
class _YamlDoc {
  final Map<String, List<Map<String, Object>>> lists;

  _YamlDoc(this.lists);

  List<Map<String, Object>> listItems(String key) =>
      lists[key] ?? <Map<String, Object>>[];
}

_YamlDoc _parseSimpleYaml(String text, String fileLabel) {
  final List<String> lines = text.split(RegExp(r'\r?\n'));
  final Map<String, List<Map<String, Object>>> out =
      <String, List<Map<String, Object>>>{};
  final RegExp headerRe = RegExp(r'^([A-Za-z_][A-Za-z0-9_]*)\s*:(.*)$');
  final RegExp itemRe = RegExp(r'^(\s*)-\s*(.*)$');
  final RegExp kvRe = RegExp(r'^([A-Za-z_][A-Za-z0-9_]*)\s*:(.*)$');

  int i = 0;
  String? nextMeaningful() {
    while (i < lines.length) {
      final String t = lines[i].trim();
      if (t.isEmpty || t.startsWith('#')) {
        i++;
        continue;
      }
      return lines[i];
    }
    return null;
  }

  String? currentList;
  String? line;
  while ((line = nextMeaningful()) != null) {
    final String raw = line!;
    final RegExpMatch? item = itemRe.firstMatch(raw);
    if (item != null) {
      if (currentList == null) {
        throw FormatException(
            'promptlib: $fileLabel has a `- ` item before any top-level key');
      }
      final int indent = item.group(1)!.length;
      final Map<String, Object> fields = <String, Object>{};
      final String rest = item.group(2)!;
      if (rest.trim().isNotEmpty) {
        final RegExpMatch? kv = kvRe.firstMatch(rest.trim());
        if (kv == null) {
          throw FormatException(
              'promptlib: $fileLabel malformed field: "$rest"');
        }
        fields[kv.group(1)!] = _parseScalar(_unquote(kv.group(2)!.trim()));
      }
      i++;
      while (i < lines.length) {
        final String cont = lines[i];
        final String t = cont.trim();
        if (t.isEmpty || t.startsWith('#')) {
          i++;
          continue;
        }
        final int cIndent = cont.length - cont.trimLeft().length;
        if (cIndent <= indent || t.startsWith('- ')) break;
        final RegExpMatch? kv = kvRe.firstMatch(t);
        if (kv == null) {
          throw FormatException(
              'promptlib: $fileLabel malformed field on line ${i + 1}: '
              '"$cont"');
        }
        fields[kv.group(1)!] = _parseScalar(_unquote(kv.group(2)!.trim()));
        i++;
      }
      out[currentList]!.add(fields);
      continue;
    }
    final RegExpMatch? header = headerRe.firstMatch(raw.trim());
    if (header == null) {
      throw FormatException(
          'promptlib: $fileLabel expected a top-level `key:` or `- ` item, '
          'got: "$raw"');
    }
    final String key = header.group(1)!;
    final String rest = header.group(2)!.trim();
    i++;
    if (rest == '[]') {
      out.putIfAbsent(key, () => <Map<String, Object>>[]);
      currentList = key;
    } else if (rest.isNotEmpty) {
      throw FormatException(
          'promptlib: $fileLabel `$key:` must be followed by a `- ` list');
    } else {
      out.putIfAbsent(key, () => <Map<String, Object>>[]);
      currentList = key;
    }
  }
  return _YamlDoc(out);
}

String _unquote(String value) {
  String v = value.trim();
  if (v.length >= 2) {
    final String first = v[0];
    final String last = v[v.length - 1];
    if ((first == '"' && last == '"') ||
        (first == "'" && last == "'")) {
      v = v.substring(1, v.length - 1);
    }
  }
  return v;
}

/// Parses a YAML scalar: `true`/`false` (any case) become bools so files
/// like `syncEnabled: false` read back correctly; everything else stays a
/// string (unknown keys pass through untouched).
Object _parseScalar(String value) {
  final String lower = value.toLowerCase();
  if (lower == 'true') return true;
  if (lower == 'false') return false;
  return value;
}

/// Stringifies a registry field; non-strings (e.g. a bool where a string
/// was expected) degrade to `''` so callers throw the proper
/// [FormatException] instead of a cast error.
String _asStr(Object? value) => value is String ? value : '';

/// Renders a scalar for YAML output: bare when unambiguous, double-quoted
/// otherwise. Round-trips through [_unquote] for the common cases.
String _yamlScalar(String value) {
  if (value.isEmpty) return '""';
  if (value == 'true' ||
      value == 'false' ||
      value == 'null' ||
      value == 'yes' ||
      value == 'no') {
    return '"$value"';
  }
  if (double.tryParse(value) != null) return '"$value"';
  final bool simple =
      RegExp(r'^[A-Za-z0-9_][A-Za-z0-9 _.\-/]*$').hasMatch(value);
  if (simple) return value;
  final String escaped =
      value.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
  return '"$escaped"';
}
