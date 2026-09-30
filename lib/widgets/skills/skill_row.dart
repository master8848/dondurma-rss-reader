import 'package:flutter/material.dart';

import '../../models/skill.dart';
import '../../promptlib/version_ux.dart';
import '../sync_state_chip.dart';

/// Single search-result / saved-skill row.
///
/// Shows the skill name, description, catalog + version meta line, an audit
/// badge (green SAFE / red UNSAFE / yellow UNKNOWN with the reason as a
/// tooltip), and a Save/Saved button. The verdict is display-only — it never
/// blocks saving.
class SkillRow extends StatelessWidget {
  final Skill skill;
  final bool saved;
  final VoidCallback? onSave;
  final VoidCallback? onRemove;
  final VoidCallback? onTap;

  /// Local-vs-remote verdict for saved skills (resolve via
  /// `SkillsProvider.checkSkillState(skill.id)`). Renders a small chip next
  /// to the audit badge; `null` or [ItemSyncState.unknown] renders nothing.
  final ItemSyncState? syncState;

  const SkillRow({
    super.key,
    required this.skill,
    this.saved = false,
    this.onSave,
    this.onRemove,
    this.onTap,
    this.syncState,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: cs.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                Icons.psychology_outlined,
                color: cs.primary,
                size: 22,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          skill.name.isEmpty ? skill.slug : skill.name,
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 14.5,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      SkillAuditBadge(
                        verdict: skill.audit,
                        reason: skill.auditReason,
                      ),
                      if (syncState != null &&
                          syncState != ItemSyncState.unknown) ...[
                        const SizedBox(width: 6),
                        SyncStateChip(state: syncState!),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  if (skill.description.isNotEmpty)
                    Text(
                      skill.description,
                      style: TextStyle(
                        fontSize: 13,
                        color: cs.onSurface.withValues(alpha: 0.65),
                        height: 1.35,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  const SizedBox(height: 4),
                  Text(
                    _metaLine(skill),
                    style: TextStyle(
                      fontSize: 11.5,
                      color: cs.onSurface.withValues(alpha: 0.45),
                      fontWeight: FontWeight.w500,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (saved)
              IconButton(
                icon: Icon(Icons.bookmark, color: cs.primary),
                tooltip: 'Remove',
                onPressed: onRemove,
              )
            else
              OutlinedButton(
                onPressed: onSave,
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(64, 32),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  visualDensity: VisualDensity.compact,
                ),
                child: const Text('Save'),
              ),
          ],
        ),
      ),
    );
  }

  static String _metaLine(Skill skill) {
    final parts = <String>[skill.catalog.label];
    if (skill.version.isNotEmpty) parts.add('v${skill.version}');
    if (skill.author.isNotEmpty) parts.add('by ${skill.author}');
    if (skill.owner.isNotEmpty && skill.repo.isNotEmpty) {
      parts.add('${skill.owner}/${skill.repo}');
    }
    return parts.join(' · ');
  }
}

/// Colored audit badge: green SAFE / red UNSAFE / yellow UNKNOWN.
///
/// The [reason] is exposed via tooltip (long-press) and semantics label.
class SkillAuditBadge extends StatelessWidget {
  final SkillVerdict verdict;
  final String reason;

  const SkillAuditBadge({super.key, required this.verdict, this.reason = ''});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final (Color bg, Color fg, String label) = switch (verdict) {
      SkillVerdict.safe => (
        Colors.green.withValues(alpha: 0.15),
        cs.brightness == Brightness.dark
            ? Colors.green.shade300
            : Colors.green.shade800,
        'SAFE',
      ),
      SkillVerdict.unsafe => (
        Colors.red.withValues(alpha: 0.15),
        cs.brightness == Brightness.dark
            ? Colors.red.shade300
            : Colors.red.shade800,
        'UNSAFE',
      ),
      SkillVerdict.unknown => (
        Colors.amber.withValues(alpha: 0.20),
        cs.brightness == Brightness.dark
            ? Colors.amber.shade300
            : Colors.amber.shade900,
        'UNKNOWN',
      ),
    };
    final tooltip = reason.isEmpty
        ? 'Audit: $label'
        : 'Audit: $label — $reason';
    return Tooltip(
      message: tooltip,
      child: Semantics(
        label: tooltip,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: fg,
              fontSize: 10,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.6,
            ),
          ),
        ),
      ),
    );
  }
}
