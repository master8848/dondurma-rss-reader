import 'dart:async';

import '../../models/skill.dart';
import 'skill_list_utils.dart';
import 'skills_http.dart';

/// Which remote catalog(s) to query. `null` (or [SkillCatalogFilter.all])
/// means all catalogs concurrently.
enum SkillCatalogFilter { all, clawhub, skillsSh, hermes }

/// Multi-catalog skill search over ClawHub, skills.sh, and the Hermes static
/// snapshot.
///
/// Pure-Dart-friendly: the HTTP layer is an injected [SkillsHttpClient]
/// (default: `dart:io`-backed, 10s timeouts, no auth). All three sources are
/// hit concurrently via [Future.wait]; per-source failures are swallowed
/// (best-effort reads) and results are merged, deduped by [Skill.id], and
/// capped at [limit].
class SkillCatalogService {
  static const Duration timeout = Duration(seconds: 10);

  final SkillsHttpClient _http;

  SkillCatalogService({SkillsHttpClient? http})
    : _http = http ?? IoSkillsHttpClient();

  /// Searches one or all catalogs for [query].
  Future<List<Skill>> searchSkills(
    String query, {
    SkillCatalogFilter catalog = SkillCatalogFilter.all,
    int limit = 50,
  }) async {
    final q = query.trim();
    if (q.isEmpty || limit <= 0) return const [];

    final futures = <Future<List<Skill>>>[];
    if (catalog == SkillCatalogFilter.all ||
        catalog == SkillCatalogFilter.clawhub) {
      futures.add(_guard(() => searchClawHub(q, limit: limit)));
    }
    if (catalog == SkillCatalogFilter.all ||
        catalog == SkillCatalogFilter.skillsSh) {
      futures.add(_guard(() => searchSkillsSh(q, limit: limit)));
    }
    if (catalog == SkillCatalogFilter.all ||
        catalog == SkillCatalogFilter.hermes) {
      futures.add(_guard(() => searchHermes(q, limit: limit)));
    }

    final results = await Future.wait(futures);
    return SkillListUtils.mergeDedupe(results, limit);
  }

  /// Runs [fn], returning an empty list on ANY failure (network, timeout,
  /// malformed JSON). One catalog going down must never break the others.
  static Future<List<Skill>> _guard(Future<List<Skill>> Function() fn) async {
    try {
      return await fn();
    } catch (_) {
      return const [];
    }
  }

  // -------------------------------------------------------------------------
  // ClawHub — https://clawhub.ai
  // JSON: GET /api/v1/search?q&limit&mode=exact
  // Detail: GET /api/v1/skills/{slug}?ownerHandle=
  // Download ZIP: GET /api/v1/download?slug=&version= (no auth for reads)
  // -------------------------------------------------------------------------

  Future<List<Skill>> searchClawHub(String query, {int limit = 50}) async {
    final uri = Uri.https('clawhub.ai', '/api/v1/search', {
      'q': query,
      'limit': '$limit',
      'mode': 'exact',
    });
    final res = await _http.get(uri, timeout: timeout);
    if (res.statusCode != 200) return const [];
    return _listOf(res.json()).map(_clawHubSkill).whereType<Skill>().toList();
  }

  Skill? _clawHubSkill(Map<String, dynamic> j) {
    final slug = _str(j, ['slug', 'name_slug', 'id']);
    if (slug.isEmpty) return null;
    final owner = _str(j, ['ownerHandle', 'owner', 'author']);
    final version = _str(j, ['version', 'latestVersion']);
    final name = _str(j, ['name', 'title', 'displayName']);
    return Skill(
      id: 'clawhub:$owner/$slug',
      slug: slug,
      name: name.isEmpty ? slug : name,
      description: _str(j, ['description', 'summary']),
      version: version,
      author: owner,
      license: _str(j, ['license']),
      catalog: SkillCatalog.clawhub,
      owner: owner,
      repo: _str(j, ['repo']),
      skillPath: _str(j, ['path', 'skillPath']),
      ref: version,
      installUrl:
          'https://clawhub.ai/api/v1/download?slug=$slug${version.isEmpty ? '' : '&version=$version'}',
      homepage: _str(j, ['homepage', 'url', 'source']),
      tags: _strList(j, ['tags', 'keywords']),
    );
  }

  // -------------------------------------------------------------------------
  // skills.sh — GET https://skills.sh/api/search?q=&limit=20&owner=
  // Download: GET https://skills.sh/api/download/{owner}/{repo}/{slug}
  // -------------------------------------------------------------------------

  Future<List<Skill>> searchSkillsSh(
    String query, {
    int limit = 20,
    String owner = '',
  }) async {
    final params = <String, String>{'q': query, 'limit': '$limit'};
    if (owner.isNotEmpty) params['owner'] = owner;
    final uri = Uri.https('skills.sh', '/api/search', params);
    final res = await _http.get(uri, timeout: timeout);
    if (res.statusCode != 200) return const [];
    return _listOf(res.json()).map(_skillsShSkill).whereType<Skill>().toList();
  }

  Skill? _skillsShSkill(Map<String, dynamic> j) {
    final slug = _str(j, ['slug', 'name_slug', 'id']);
    if (slug.isEmpty) return null;
    final owner = _str(j, ['owner', 'ownerHandle', 'author']);
    final repo = _str(j, ['repo', 'repository']);
    final version = _str(j, ['version', 'ref', 'commitSha']);
    final name = _str(j, ['name', 'title']);
    final path = _str(j, ['path', 'skillPath', 'skill_path']);
    return Skill(
      id: 'skillssh:$owner/$repo/$slug',
      slug: slug,
      name: name.isEmpty ? slug : name,
      description: _str(j, ['description', 'summary']),
      version: version,
      author: owner,
      license: _str(j, ['license']),
      catalog: SkillCatalog.skillsSh,
      owner: owner,
      repo: repo,
      skillPath: path,
      ref: _str(j, ['ref', 'branch', 'defaultBranch']),
      installUrl: owner.isNotEmpty && repo.isNotEmpty
          ? 'https://skills.sh/api/download/$owner/$repo/$slug'
          : '',
      homepage: owner.isNotEmpty && repo.isNotEmpty
          ? 'https://github.com/$owner/$repo'
          : _str(j, ['homepage', 'url']),
      tags: _strList(j, ['tags', 'keywords']),
    );
  }

  // -------------------------------------------------------------------------
  // Hermes — static snapshot
  // https://nousresearch.github.io/hermes-agent/docs/api/skills.json
  // entries: {name,description,version,author,license,platforms,tags,path,source}
  // -------------------------------------------------------------------------

  Future<List<Skill>> searchHermes(String query, {int limit = 50}) async {
    final uri = Uri.https(
      'nousresearch.github.io',
      '/hermes-agent/docs/api/skills.json',
    );
    final res = await _http.get(uri, timeout: timeout);
    if (res.statusCode != 200) return const [];
    final q = query.toLowerCase();
    final out = <Skill>[];
    for (final j in _listOf(res.json())) {
      final name = _str(j, ['name']);
      final description = _str(j, ['description']);
      if (q.isNotEmpty &&
          !name.toLowerCase().contains(q) &&
          !description.toLowerCase().contains(q)) {
        continue;
      }
      if (name.isEmpty) continue;
      final source = _str(j, ['source']);
      out.add(
        Skill(
          id: 'hermes:$name',
          slug: name,
          name: name,
          description: description,
          version: _str(j, ['version']),
          author: _str(j, ['author']),
          license: _str(j, ['license']),
          catalog: SkillCatalog.hermes,
          skillPath: _str(j, ['path']),
          homepage: source,
          tags: _strList(j, ['tags']),
        ),
      );
      if (out.length >= limit) break;
    }
    return out;
  }

  // -------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------

  /// Normalizes the many envelope shapes catalog APIs use: a bare list, or a
  /// map wrapping the list under `skills`/`results`/`data`/`items`.
  static List<Map<String, dynamic>> _listOf(dynamic decoded) {
    if (decoded is List) {
      return decoded.whereType<Map<String, dynamic>>().toList();
    }
    if (decoded is Map<String, dynamic>) {
      for (final key in ['skills', 'results', 'data', 'items']) {
        final inner = decoded[key];
        if (inner is List) {
          return inner.whereType<Map<String, dynamic>>().toList();
        }
      }
    }
    return const [];
  }

  static String _str(Map<String, dynamic> j, List<String> keys) {
    for (final k in keys) {
      final v = j[k];
      if (v is String && v.isNotEmpty) return v;
      if (v is num) return v.toString();
    }
    return '';
  }

  static List<String> _strList(Map<String, dynamic> j, List<String> keys) {
    for (final k in keys) {
      final v = j[k];
      if (v is List) {
        return v.map((e) => e.toString()).where((e) => e.isNotEmpty).toList();
      }
      if (v is String && v.isNotEmpty) {
        return v.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
      }
    }
    return const [];
  }
}
