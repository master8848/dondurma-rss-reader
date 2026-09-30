import 'dart:async';

import '../../models/skill.dart';
import 'skills_http.dart';

/// Audit verdict lookup for skills.
///
/// Data source: `GET https://add-skill.vercel.sh/audit?source=owner/repo&skills=slug`
/// returning per-slug audit objects. Mapping (fail-open, display-only):
///
/// - `risk` of `critical` or `high` → [SkillVerdict.unsafe]
/// - `socket.alerts` non-empty/non-zero, or numeric `score` < 80 → unsafe
/// - otherwise → [SkillVerdict.safe]
/// - any network/parse error (or skill without owner/repo/slug) → [SkillVerdict.unknown]
///
/// The verdict NEVER blocks installation — it only drives the audit badge.
class SkillAuditService {
  static const Duration timeout = Duration(seconds: 10);

  final SkillsHttpClient _http;

  SkillAuditService({SkillsHttpClient? http}) : _http = http ?? IoSkillsHttpClient();

  /// Returns a copy of [skill] with [Skill.audit]/[Skill.auditReason] filled in.
  Future<Skill> verdictFor(Skill skill) async {
    final verdict = await verdictForCoords(
      owner: skill.owner,
      repo: skill.repo,
      slug: skill.slug,
    );
    return skill.copyWith(audit: verdict.verdict, auditReason: verdict.reason);
  }

  /// Audits raw coordinates without needing a full [Skill].
  Future<SkillAuditResult> verdictForCoords({
    required String owner,
    required String repo,
    required String slug,
  }) async {
    if (owner.isEmpty || repo.isEmpty || slug.isEmpty) {
      return const SkillAuditResult(
        SkillVerdict.unknown,
        'not auditable: missing owner/repo/slug',
      );
    }
    try {
      final uri = Uri.https('add-skill.vercel.sh', '/audit', {
        'source': '$owner/$repo',
        'skills': slug,
      });
      final res = await _http.get(uri, timeout: timeout);
      if (res.statusCode != 200) {
        return SkillAuditResult(
          SkillVerdict.unknown,
          'audit service returned ${res.statusCode}',
        );
      }
      return mapAuditPayload(res.json(), slug);
    } catch (e) {
      return SkillAuditResult(SkillVerdict.unknown, 'audit failed: $e');
    }
  }

  /// Pure mapping from a decoded audit payload to a verdict.
  ///
  /// Accepts either the per-slug object directly (`{risk, score, socket…}`)
  /// or an envelope (`{skills: {slug: {...}}}`, `{results: …}`, bare list).
  /// Exported (and static) so unit tests can pin the mapping without HTTP.
  static SkillAuditResult mapAuditPayload(dynamic decoded, String slug) {
    try {
      final entry = _findSlugEntry(decoded, slug);
      if (entry == null) {
        return const SkillAuditResult(
          SkillVerdict.unknown,
          'no audit entry for skill',
        );
      }

      final risk = entry['risk']?.toString().toLowerCase() ?? '';
      if (risk == 'critical' || risk == 'high') {
        return SkillAuditResult(
          SkillVerdict.unsafe,
          'risk: ${entry['risk']}',
        );
      }

      final socket = entry['socket'];
      if (socket is Map) {
        final alerts = socket['alerts'];
        final count = _alertCount(alerts);
        if (count > 0) {
          return SkillAuditResult(
            SkillVerdict.unsafe,
            'socket alerts: $count',
          );
        }
      } else if (socket is List && socket.isNotEmpty) {
        return SkillAuditResult(
          SkillVerdict.unsafe,
          'socket alerts: ${socket.length}',
        );
      }

      final score = entry['score'];
      if (score is num && score < 80) {
        return SkillAuditResult(
          SkillVerdict.unsafe,
          'score ${score.toString()} below 80',
        );
      }

      final passed = entry['passed'] ?? entry['safe'];
      if (passed == false) {
        return const SkillAuditResult(SkillVerdict.unsafe, 'audit failed');
      }

      final scoreStr = score is num ? ' (score ${score.toString()})' : '';
      return SkillAuditResult(SkillVerdict.safe, 'audit passed$scoreStr');
    } catch (e) {
      return SkillAuditResult(SkillVerdict.unknown, 'audit parse failed: $e');
    }
  }

  static Map<String, dynamic>? _findSlugEntry(dynamic decoded, String slug) {
    if (decoded is Map<String, dynamic>) {
      // Direct per-slug object.
      if (decoded.containsKey('risk') ||
          decoded.containsKey('score') ||
          decoded.containsKey('socket') ||
          decoded.containsKey('passed') ||
          decoded.containsKey('safe')) {
        return decoded;
      }
      for (final key in ['skills', 'results', 'data']) {
        final inner = decoded[key];
        if (inner is Map<String, dynamic>) {
          final hit = inner[slug];
          if (hit is Map<String, dynamic>) return hit;
          // Single-entry envelope without slug key.
          if (inner.containsKey('risk') || inner.containsKey('score')) {
            return inner;
          }
        }
        if (inner is List) {
          for (final item in inner) {
            if (item is Map<String, dynamic> &&
                (item['slug'] == slug || item['name'] == slug)) {
              return item;
            }
          }
          if (inner.isNotEmpty && inner.first is Map<String, dynamic>) {
            return inner.first as Map<String, dynamic>;
          }
        }
      }
    }
    if (decoded is List) {
      for (final item in decoded) {
        if (item is Map<String, dynamic> &&
            (item['slug'] == slug || item['name'] == slug)) {
          return item;
        }
      }
    }
    return null;
  }

  static int _alertCount(dynamic alerts) {
    if (alerts is num) return alerts.toInt();
    if (alerts is List) return alerts.length;
    if (alerts is Map) {
      if (alerts.isEmpty) return 0;
      // `{critical: 0, high: 1, …}` shape — sum numeric values.
      var total = 0;
      var anyNumeric = false;
      for (final v in alerts.values) {
        if (v is num) {
          anyNumeric = true;
          total += v.toInt();
        }
      }
      return anyNumeric ? total : alerts.length;
    }
    if (alerts is bool) return alerts ? 1 : 0;
    return 0;
  }
}

/// A verdict plus the human-readable reason shown in the badge tooltip.
class SkillAuditResult {
  final SkillVerdict verdict;
  final String reason;

  const SkillAuditResult(this.verdict, this.reason);
}
