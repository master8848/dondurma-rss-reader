/// A discoverable/installable skill entry from a skill catalog.
///
/// Pure Dart — no Flutter imports so this file stays runnable with plain
/// `dart` (unit tests, tooling) as well as inside the Flutter app.
///
/// A skill on disk is a folder containing a `SKILL.md` file (YAML frontmatter
/// with `name`, `description`, optional `version`) plus optional
/// `scripts/`, `references/` and `assets/` subfolders.
class Skill {
  /// Stable dedupe key, typically `<catalog>:<owner>/<repo>/<slug>` or the
  /// catalog-provided id.
  final String id;

  /// URL-safe short name of the skill within its repo/catalog.
  final String slug;

  /// Human-readable display name.
  final String name;

  /// Short description of what the skill does.
  final String description;

  /// Version string when known (git ref, catalog version, or SKILL.md
  /// frontmatter `version`). Empty string when unknown.
  final String version;

  /// Author or owner handle when known.
  final String author;

  /// License identifier when known (e.g. `MIT`).
  final String license;

  /// Which catalog this entry came from.
  final SkillCatalog catalog;

  /// GitHub-style owner (user/org) for git-backed skills. Empty when n/a.
  final String owner;

  /// Repository name for git-backed skills. Empty when n/a.
  final String repo;

  /// Path of the skill folder inside its repo (e.g. `skills/pdf`).
  /// Empty when the skill is the repo root.
  final String skillPath;

  /// Git ref (branch/tag) the skill was fetched at. Empty when n/a.
  final String ref;

  /// Direct install/download URL when the catalog provides one.
  final String installUrl;

  /// Homepage or source URL for the skill.
  final String homepage;

  /// Free-form tags/keywords.
  final List<String> tags;

  /// Latest known audit verdict (defaults to [SkillVerdict.unknown]).
  final SkillVerdict audit;

  /// Human-readable reason for [audit] (e.g. `score 92`, `socket alerts: 2`).
  final String auditReason;

  const Skill({
    required this.id,
    required this.slug,
    required this.name,
    required this.description,
    this.version = '',
    this.author = '',
    this.license = '',
    required this.catalog,
    this.owner = '',
    this.repo = '',
    this.skillPath = '',
    this.ref = '',
    this.installUrl = '',
    this.homepage = '',
    this.tags = const [],
    this.audit = SkillVerdict.unknown,
    this.auditReason = '',
  });

  /// Copy with helper for attaching audit results / install metadata.
  Skill copyWith({
    String? id,
    String? slug,
    String? name,
    String? description,
    String? version,
    String? author,
    String? license,
    SkillCatalog? catalog,
    String? owner,
    String? repo,
    String? skillPath,
    String? ref,
    String? installUrl,
    String? homepage,
    List<String>? tags,
    SkillVerdict? audit,
    String? auditReason,
  }) {
    return Skill(
      id: id ?? this.id,
      slug: slug ?? this.slug,
      name: name ?? this.name,
      description: description ?? this.description,
      version: version ?? this.version,
      author: author ?? this.author,
      license: license ?? this.license,
      catalog: catalog ?? this.catalog,
      owner: owner ?? this.owner,
      repo: repo ?? this.repo,
      skillPath: skillPath ?? this.skillPath,
      ref: ref ?? this.ref,
      installUrl: installUrl ?? this.installUrl,
      homepage: homepage ?? this.homepage,
      tags: tags ?? this.tags,
      audit: audit ?? this.audit,
      auditReason: auditReason ?? this.auditReason,
    );
  }

  /// Deserializes a [Skill] from a JSON map with fallback defaults for
  /// backward compatibility (mirrors the FeedSubscription pattern).
  factory Skill.fromJson(Map<String, dynamic> json) {
    return Skill(
      id: json['id'] as String? ?? '',
      slug: json['slug'] as String? ?? '',
      name: json['name'] as String? ?? '',
      description: json['description'] as String? ?? '',
      version: json['version'] as String? ?? '',
      author: json['author'] as String? ?? '',
      license: json['license'] as String? ?? '',
      catalog: SkillCatalogX.fromName(json['catalog'] as String? ?? ''),
      owner: json['owner'] as String? ?? '',
      repo: json['repo'] as String? ?? '',
      skillPath: json['skillPath'] as String? ?? '',
      ref: json['ref'] as String? ?? '',
      installUrl: json['installUrl'] as String? ?? '',
      homepage: json['homepage'] as String? ?? '',
      tags:
          (json['tags'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          const [],
      audit: SkillVerdictX.fromName(json['audit'] as String? ?? ''),
      auditReason: json['auditReason'] as String? ?? '',
    );
  }

  /// Serializes this skill to a JSON-compatible map for Hive persistence.
  Map<String, dynamic> toJson() => {
    'id': id,
    'slug': slug,
    'name': name,
    'description': description,
    'version': version,
    'author': author,
    'license': license,
    'catalog': catalog.name,
    'owner': owner,
    'repo': repo,
    'skillPath': skillPath,
    'ref': ref,
    'installUrl': installUrl,
    'homepage': homepage,
    'tags': tags,
    'audit': audit.name,
    'auditReason': auditReason,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is Skill && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'Skill(id: $id, name: $name, catalog: ${catalog.name})';
}

/// Source catalog a [Skill] entry was discovered in.
enum SkillCatalog {
  /// ClawHub registry (https://clawhub.ai).
  clawhub,

  /// skills.sh index (https://skills.sh).
  skillsSh,

  /// Hermes agent skills snapshot (static JSON).
  hermes,

  /// Well-known / curated list entry.
  wellKnown,

  /// Already installed locally / on-disk skill.
  local,
}

/// Parsing helper for [SkillCatalog] with an [unknown]-tolerant fallback.
///
/// Unknown or missing names map to [SkillCatalog.wellKnown] so that
/// persisted records never fail to deserialize.
extension SkillCatalogX on SkillCatalog {
  static SkillCatalog fromName(String name) {
    for (final v in SkillCatalog.values) {
      if (v.name == name) return v;
    }
    return SkillCatalog.wellKnown;
  }

  /// Short display label used for filter chips.
  String get label => switch (this) {
    SkillCatalog.clawhub => 'ClawHub',
    SkillCatalog.skillsSh => 'skills.sh',
    SkillCatalog.hermes => 'Hermes',
    SkillCatalog.wellKnown => 'Curated',
    SkillCatalog.local => 'Local',
  };
}

/// Audit verdict for a skill.
///
/// Fail-open: anything that cannot be proven safe stays [unknown], and the
/// verdict is display-only — it NEVER blocks installation.
enum SkillVerdict { safe, unsafe, unknown }

/// Parsing helper for [SkillVerdict]; unknown/missing names map to
/// [SkillVerdict.unknown] (fail-open).
extension SkillVerdictX on SkillVerdict {
  static SkillVerdict fromName(String name) {
    for (final v in SkillVerdict.values) {
      if (v.name == name) return v;
    }
    return SkillVerdict.unknown;
  }
}
