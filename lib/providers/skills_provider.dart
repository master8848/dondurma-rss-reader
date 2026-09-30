import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';

import '../models/skill.dart';
import '../promptlib/version_ux.dart';
import '../services/skills/skill_audit_service.dart';
import '../services/skills/skill_catalog_service.dart';
import '../services/skills/skills_cache_service.dart';
import '../services/skills/skill_list_utils.dart';
import 'subscription_provider.dart';

/// Browses remote skill catalogs, audits results, and manages saved skills.
///
/// STORAGE (documented choice): everything lives in the existing `'settings'`
/// Hive box — key `'skillSearchHistory'` (MRU-10 string list, same pattern as
/// `SettingsProvider.searchHistory`) and key `'savedSkills'` (JSON list of
/// [Skill] maps). No new Hive box is opened, so `_migrateHiveBoxes()` in
/// `main.dart` is untouched.
///
/// Saved skills are ALSO grouped in the UI as one virtual "Skills" folder;
/// [saveSkill] creates the real custom category via [SubscriptionProvider]
/// (default name `'Skills'`) so the folder appears alongside feed categories.
class SkillsProvider extends ChangeNotifier {
  static const String defaultCategory = 'Skills';
  static const String _historyKey = 'skillSearchHistory';
  static const String _savedKey = 'savedSkills';
  static const String _baselinesKey = 'skillBaselines';

  /// How long a skill verdict is reused without re-checking remote HEAD.
  /// Remote fetches only happen in [checkSkillState] after expiry (or
  /// `force: true`); list rows stay cheap and the UI never blocks.
  static const Duration checkTtl = Duration(minutes: 15);

  final SkillCatalogService _catalog;
  final SkillAuditService _audit;

  /// Set via [initCache] once the app-support directory is known. Git caching
  /// is best-effort: saving works even when this is null (offline / no git).
  SkillsCacheService? _cache;

  List<String> _searchHistory = [];
  List<Skill> _savedSkills = [];
  List<Skill> _results = [];
  SkillCatalogFilter _filter = SkillCatalogFilter.all;
  bool _isSearching = false;
  String _lastQuery = '';

  /// Acknowledged SHAs per saved skill id ("keep mine" records the pinned
  /// SHA as agreed; a later remote HEAD flags "Update available" afresh).
  /// Persisted in the `'settings'` box under [_baselinesKey].
  Map<String, String> _skillBaselines = {};

  /// Memoized verdicts per saved skill id (see [checkTtl]).
  final Map<String, ({ItemSyncState state, DateTime at})> _skillChecks = {};

  SkillsProvider({SkillCatalogService? catalog, SkillAuditService? audit})
    : _catalog = catalog ?? SkillCatalogService(),
      _audit = audit ?? SkillAuditService() {
    _loadPersisted();
  }

  // ---------------------------------------------------------------------------
  // Getters
  // ---------------------------------------------------------------------------

  List<String> get skillSearchHistory => List.unmodifiable(_searchHistory);
  List<Skill> get savedSkills => List.unmodifiable(_savedSkills);
  List<Skill> get results => List.unmodifiable(_results);
  SkillCatalogFilter get filter => _filter;
  bool get isSearching => _isSearching;
  String get lastQuery => _lastQuery;

  bool isSaved(String id) => _savedSkills.any((s) => s.id == id);

  /// Lazily cached reference to the `'settings'` Hive box.
  Box get _box => Hive.box('settings');

  /// Provides the on-disk cache root (call once from the Skills screen with
  /// `<appSupport>/skills_cache`).
  void initCache(Directory baseDir) {
    _cache ??= SkillsCacheService(baseDir: baseDir);
  }

  // ---------------------------------------------------------------------------
  // Search
  // ---------------------------------------------------------------------------

  void setFilter(SkillCatalogFilter filter) {
    if (_filter == filter) return;
    _filter = filter;
    notifyListeners();
    if (_lastQuery.isNotEmpty) {
      search(_lastQuery);
    }
  }

  /// Searches the catalogs for [query], records history (MRU-10), and attaches
  /// best-effort audit verdicts (fail-open: errors keep `unknown`).
  Future<void> search(String query) async {
    final q = query.trim();
    _lastQuery = q;
    if (q.isEmpty) {
      _results = [];
      notifyListeners();
      return;
    }
    _isSearching = true;
    notifyListeners();
    try {
      final found = await _catalog.searchSkills(
        q,
        catalog: _filter,
        limit: 50,
      );
      // Attach audit verdicts concurrently; each is fail-open on its own.
      final withVerdicts = await Future.wait(
        found.map((s) async {
          try {
            return await _audit.verdictFor(s);
          } catch (_) {
            return s;
          }
        }),
      );
      _results = withVerdicts;
      await addToHistory(q);
    } finally {
      _isSearching = false;
      notifyListeners();
    }
  }

  void clearResults() {
    _results = [];
    _lastQuery = '';
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Search history (MRU-10, same pattern as SettingsProvider)
  // ---------------------------------------------------------------------------

  Future<void> addToHistory(String query) async {
    if (query.trim().isEmpty) return;
    _searchHistory = SkillListUtils.mruInsert(_searchHistory, query, 10);
    notifyListeners();
    await _box.put(_historyKey, _searchHistory);
  }

  Future<void> removeFromHistory(String query) async {
    _searchHistory = List<String>.from(_searchHistory)..remove(query);
    notifyListeners();
    await _box.put(_historyKey, _searchHistory);
  }

  Future<void> clearHistory() async {
    _searchHistory = [];
    notifyListeners();
    await _box.put(_historyKey, <String>[]);
  }

  // ---------------------------------------------------------------------------
  // Saved skills
  // ---------------------------------------------------------------------------

  /// Saves [skill] and ensures [category] exists as a custom category so the
  /// skill appears under one "Skills" folder. The skill folder is cached via
  /// git best-effort (offline failures never fail the save).
  Future<void> saveSkill(
    Skill skill, {
    String category = defaultCategory,
    SubscriptionProvider? subscriptions,
  }) async {
    if (isSaved(skill.id)) return;
    if (subscriptions != null && !subscriptions.categories.contains(category)) {
      await subscriptions.addCategory(category);
    }
    _savedSkills = [..._savedSkills, skill];
    notifyListeners();
    await _persistSaved();

    // Best-effort folder cache — never fails the save.
    try {
      await ensureCached(skill);
    } catch (_) {
      // Offline / no git: the skill metadata is still saved.
    }
  }

  Future<void> removeSkill(String id) async {
    _savedSkills = _savedSkills.where((s) => s.id != id).toList();
    notifyListeners();
    await _persistSaved();
  }

  /// Ensures the git folder cache for [skill] exists and returns the repo dir,
  /// or null when the skill has no git coordinates / no cache configured.
  Future<Directory?> ensureCached(Skill skill) async {
    final cache = _cache;
    final repoUrl = repoUrlFor(skill);
    if (cache == null || repoUrl == null) return null;
    return cache.ensure(
      repoUrl,
      ref: skill.ref.isEmpty ? 'HEAD' : skill.ref,
      sparsePaths: skill.skillPath.isEmpty ? const [] : [skill.skillPath],
    );
  }

  /// Fetches the latest remote state for [skill] into its folder cache
  /// (`fetch` + `reset --hard`, like the pre-existing update path) and
  /// re-checks the verdict. Returns false when there is nothing to update
  /// from (no coordinates / no cache / offline). Never throws.
  Future<bool> updateSkill(Skill skill) async {
    final cache = _cache;
    final repoUrl = repoUrlFor(skill);
    if (cache == null || repoUrl == null) return false;
    try {
      await cache.ensure(
        repoUrl,
        ref: skill.ref.isEmpty ? 'HEAD' : skill.ref,
        sparsePaths: skill.skillPath.isEmpty ? const [] : [skill.skillPath],
        update: true,
      );
    } catch (_) {
      return false;
    }
    _skillChecks.remove(skill.id);
    notifyListeners();
    return true;
  }

  /// Tri-state local-vs-remote verdict for a saved [skill], backed by commit
  /// SHAs (cached pin vs remote HEAD) plus a dirty-tree check:
  ///
  /// * Up to date — pinned SHA matches remote HEAD.
  /// * Edited here — the cached checkout has uncommitted changes, or the pin
  ///   moved on from the acknowledged baseline while offline.
  /// * Update available — remote HEAD moved on from the pin/baseline.
  /// * Not checked yet — no coordinates / not cached / offline (degrades
  ///   gracefully, never throws, never blocks: the check is memoized for
  ///   [checkTtl]).
  Future<ItemSyncState> checkSkillState(
    Skill skill, {
    bool force = false,
  }) async {
    final DateTime now = DateTime.now().toUtc();
    final cached = _skillChecks[skill.id];
    if (!force &&
        cached != null &&
        now.difference(cached.at) < checkTtl) {
      return cached.state;
    }
    ItemSyncState state = ItemSyncState.unknown;
    try {
      state = await _computeSkillState(skill);
    } catch (_) {
      state = ItemSyncState.unknown;
    }
    _skillChecks[skill.id] = (state: state, at: now);
    return state;
  }

  /// Keeps the local copy: records the currently pinned SHA as the agreed
  /// baseline, clearing "Update available" until remote HEAD actually moves
  /// again. Best-effort and silent when there is nothing pinned.
  Future<void> keepSkillMine(Skill skill) async {
    final cache = _cache;
    final repoUrl = repoUrlFor(skill);
    if (cache == null || repoUrl == null) return;
    try {
      final SkillRepoMeta? meta = await cache.readMeta(
        repoUrl,
        ref: skill.ref.isEmpty ? 'HEAD' : skill.ref,
      );
      final String sha = meta?.commitSha.trim() ?? '';
      if (sha.isEmpty) return;
      _skillBaselines[skill.id] = sha;
      await _box.put(_baselinesKey, _skillBaselines);
    } catch (_) {
      // Baseline persistence must never break the keep flow.
    }
    _skillChecks.remove(skill.id);
    notifyListeners();
  }

  /// Captures the before/after `SKILL.md` bodies around an [updateSkill] so
  /// the UI can show what changed. Either side may be null (not cached /
  /// file absent); the update itself still proceeds. Never throws.
  Future<({String? before, String? after})> fetchUpdateDiff(
    Skill skill,
  ) async {
    String? before;
    try {
      before = await readSkillMd(skill);
    } catch (_) {
      before = null;
    }
    await updateSkill(skill);
    String? after;
    try {
      after = await readSkillMd(skill);
    } catch (_) {
      after = null;
    }
    return (before: before, after: after);
  }

  Future<ItemSyncState> _computeSkillState(Skill skill) async {
    final SkillsCacheService? cache = _cache;
    final String? repoUrl = repoUrlFor(skill);
    if (cache == null || repoUrl == null) return ItemSyncState.unknown;
    final String ref = skill.ref.isEmpty ? 'HEAD' : skill.ref;
    final Directory? dir = cache.repoDirFor(repoUrl, ref: ref);
    if (dir == null || !await dir.exists()) {
      return ItemSyncState.unknown;
    }
    // Local edits first: a dirty checkout is "edited here" regardless of
    // what the remote says.
    bool? dirty;
    try {
      dirty = await cache.isSkillDirty(repoUrl, skill.skillPath, ref: ref);
    } catch (_) {
      dirty = null;
    }
    if (dirty == true) return ItemSyncState.localNewer;
    String localSha = '';
    try {
      localSha = (await cache.readMeta(repoUrl, ref: ref))?.commitSha.trim() ?? '';
    } catch (_) {
      localSha = '';
    }
    // Remote HEAD best-effort: offline / auth / timeout all degrade to null
    // (unknown), never to an exception.
    String? remoteSha;
    try {
      remoteSha = await cache.remoteHeadSha(repoUrl, ref: ref);
    } catch (_) {
      remoteSha = null;
    }
    return determineSyncState(
      localHash: localSha.isEmpty ? null : localSha,
      baseHash: _skillBaselines[skill.id] ?? _shaish(skill.version),
      remoteHash: remoteSha,
    );
  }

  /// Uses [Skill.version] as a baseline only when it looks like a commit
  /// SHA (short or full hex); catalog versions like `1.2.3` are not SHAs.
  static String? _shaish(String version) {
    final String v = version.trim();
    if (RegExp(r'^[0-9a-f]{7,40}$').hasMatch(v)) return v;
    return null;
  }

  /// Reads the checked-out `SKILL.md` body for [skill], or null when the
  /// skill is not cached (offline / no git / no coordinates).
  Future<String?> readSkillMd(Skill skill) async {
    try {
      final dir = await ensureCached(skill);
      if (dir == null) return null;
      final path = skill.skillPath.isEmpty
          ? 'SKILL.md'
          : '${skill.skillPath}/SKILL.md';
      final file = File('${dir.path}${Platform.pathSeparator}$path');
      if (!await file.exists()) return null;
      return await file.readAsString();
    } catch (_) {
      return null;
    }
  }

  /// Folder-level version history (git log checkpoints) for [skill].
  Future<List<SkillCheckpoint>> historyFor(Skill skill) async {
    final cache = _cache;
    final repoUrl = repoUrlFor(skill);
    if (cache == null || repoUrl == null) return const [];
    try {
      return await cache.history(
        repoUrl,
        skill.skillPath,
        ref: skill.ref.isEmpty ? 'HEAD' : skill.ref,
      );
    } catch (_) {
      return const [];
    }
  }

  /// Reads `SKILL.md` content for [skill] at checkpoint [sha].
  /// Returns null when unavailable (not cached / file absent at that commit).
  Future<String?> openCheckpoint(Skill skill, String sha) async {
    final cache = _cache;
    final repoUrl = repoUrlFor(skill);
    if (cache == null || repoUrl == null) return null;
    final path = skill.skillPath.isEmpty
        ? 'SKILL.md'
        : '${skill.skillPath}/SKILL.md';
    try {
      return await cache.readFileAt(
        repoUrl,
        path,
        sha: sha,
        ref: skill.ref.isEmpty ? 'HEAD' : skill.ref,
      );
    } catch (_) {
      return null;
    }
  }

  /// Best-effort clone URL for a git-backed skill. GitHub is assumed when only
  /// `owner/repo` coordinates are known; an explicit [Skill.homepage] that
  /// already looks like a git URL wins.
  static String? repoUrlFor(Skill skill) {
    final home = skill.homepage.trim();
    if (home.isNotEmpty &&
        (home.endsWith('.git') || SkillRepoCoords.parse(home) != null)) {
      // Homepage points at (or is) a repo URL — but only trust it when the
      // skill also carries matching owner/repo coordinates, otherwise a
      // docs page could be mistaken for a clone URL.
      if (skill.owner.isEmpty || skill.repo.isEmpty) return null;
      return home.endsWith('.git') ? home : 'https://github.com/${skill.owner}/${skill.repo}';
    }
    if (skill.owner.isEmpty || skill.repo.isEmpty) return null;
    return 'https://github.com/${skill.owner}/${skill.repo}';
  }

  // ---------------------------------------------------------------------------
  // Persistence
  // ---------------------------------------------------------------------------

  void _loadPersisted() {
    _searchHistory =
        (_box.get(_historyKey) as List<dynamic>?)
            ?.map((e) => e.toString())
            .toList() ??
        [];
    try {
      final raw = _box.get(_baselinesKey) as Map<dynamic, dynamic>?;
      _skillBaselines = raw == null
          ? <String, String>{}
          : <String, String>{
              for (final MapEntry<dynamic, dynamic> e in raw.entries)
                e.key.toString(): e.value.toString(),
            };
    } catch (_) {
      _skillBaselines = {};
    }
    try {
      final raw = _box.get(_savedKey) as List<dynamic>?;
      _savedSkills =
          raw
              ?.whereType<Map>()
              .map((e) => Skill.fromJson(Map<String, dynamic>.from(e)))
              .toList() ??
          [];
    } catch (_) {
      _savedSkills = [];
    }
  }

  Future<void> _persistSaved() async {
    try {
      await _box.put(
        _savedKey,
        _savedSkills.map((s) => s.toJson()).toList(),
      );
    } catch (_) {
      // Persistence failure must not crash the save flow.
    }
  }
}
