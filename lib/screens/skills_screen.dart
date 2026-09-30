import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../models/skill.dart';
import '../providers/skills_provider.dart';
import '../providers/subscription_provider.dart';
import '../services/skills/skill_catalog_service.dart';
import '../services/skills/skills_cache_service.dart';
import '../utils/app_toast.dart';
import '../widgets/constrained_width.dart';
import '../widgets/skills/skill_row.dart';

/// Skills catalog browser: multi-catalog search with audit badges, a saved
/// "Skills" folder, and a detail view rendering SKILL.md plus folder-level
/// version history (git log checkpoints).
class SkillsScreen extends StatefulWidget {
  const SkillsScreen({super.key});

  @override
  State<SkillsScreen> createState() => _SkillsScreenState();
}

class _SkillsScreenState extends State<SkillsScreen> {
  final TextEditingController _searchController = TextEditingController();
  bool _cacheInit = false;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _ensureCache(SkillsProvider provider) async {
    if (_cacheInit) return;
    _cacheInit = true;
    try {
      final dir = await getApplicationSupportDirectory();
      provider.initCache(Directory('${dir.path}/skills_cache'));
    } catch (_) {
      // Cache is best-effort; search/save work without it.
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<SkillsProvider>();
    _ensureCache(context.read<SkillsProvider>());

    return ConstrainedWidth(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: TextField(
              controller: _searchController,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: 'Search skills…',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _searchController.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () {
                          _searchController.clear();
                          provider.clearResults();
                          setState(() {});
                        },
                      )
                    : null,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
              ),
              onChanged: (_) => setState(() {}),
              onSubmitted: (value) => provider.search(value),
            ),
          ),
          // ── Search history (same pattern as HomeSearchHistoryPanel) ──
          if (_searchController.text.isEmpty)
            _SkillSearchHistory(
              onQuerySelected: (q) {
                _searchController.text = q;
                provider.search(q);
              },
            ),
          // ── Catalog filter chips ──────────────────────────────────────
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                _FilterChip(
                  label: 'All',
                  selected:
                      provider.filter == SkillCatalogFilter.all,
                  onTap: () => provider.setFilter(SkillCatalogFilter.all),
                ),
                _FilterChip(
                  label: 'ClawHub',
                  selected:
                      provider.filter == SkillCatalogFilter.clawhub,
                  onTap: () =>
                      provider.setFilter(SkillCatalogFilter.clawhub),
                ),
                _FilterChip(
                  label: 'skills.sh',
                  selected:
                      provider.filter == SkillCatalogFilter.skillsSh,
                  onTap: () =>
                      provider.setFilter(SkillCatalogFilter.skillsSh),
                ),
                _FilterChip(
                  label: 'Hermes',
                  selected:
                      provider.filter == SkillCatalogFilter.hermes,
                  onTap: () =>
                      provider.setFilter(SkillCatalogFilter.hermes),
                ),
              ],
            ),
          ),
          Expanded(
            child: provider.isSearching
                ? const Center(child: CircularProgressIndicator())
                : provider.results.isNotEmpty
                ? ListView.separated(
                    itemCount: provider.results.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      final skill = provider.results[i];
                      final saved = provider.isSaved(skill.id);
                      return SkillRow(
                        skill: skill,
                        saved: saved,
                        onTap: () => _openDetail(context, skill),
                        onSave: () => _save(context, skill),
                        onRemove: () => provider.removeSkill(skill.id),
                      );
                    },
                  )
                : provider.savedSkills.isNotEmpty
                ? _SavedSkillsGroup(
                    onOpen: (s) => _openDetail(context, s),
                  )
                : _EmptyState(
                    onTrySample: () {
                      _searchController.text = 'pdf';
                      provider.search('pdf');
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Future<void> _save(BuildContext context, Skill skill) async {
    await context.read<SkillsProvider>().saveSkill(
      skill,
      subscriptions: context.read<SubscriptionProvider>(),
    );
    if (context.mounted) {
      showAppToast('Saved "${skill.name}" to Skills', type: AppToastType.success);
    }
  }

  void _openDetail(BuildContext context, Skill skill) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => _SkillDetailSheet(skill: skill),
    );
  }
}

// ---------------------------------------------------------------------------
// Filter chip
// ---------------------------------------------------------------------------

class _FilterChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _FilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(label: Text(label), selected: selected, onSelected: (_) => onTap()),
    );
  }
}

// ---------------------------------------------------------------------------
// Search history — mirrors HomeSearchHistoryPanel over SkillsProvider history
// ---------------------------------------------------------------------------

class _SkillSearchHistory extends StatelessWidget {
  final ValueChanged<String> onQuerySelected;

  const _SkillSearchHistory({required this.onQuerySelected});

  @override
  Widget build(BuildContext context) {
    final history = context.watch<SkillsProvider>().skillSearchHistory;
    if (history.isEmpty) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.surfaceContainerHighest.withValues(alpha: 0.6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text(
              'RECENT SKILL SEARCHES',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.0,
                color: cs.onSurface.withValues(alpha: 0.5),
              ),
            ),
          ),
          ...history.map(
            (query) => InkWell(
              onTap: () => onQuerySelected(query),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.history,
                      size: 18,
                      color: cs.onSurface.withValues(alpha: 0.4),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        query,
                        style: TextStyle(fontSize: 14, color: cs.onSurface),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    GestureDetector(
                      onTap: () => context
                          .read<SkillsProvider>()
                          .removeFromHistory(query),
                      child: Icon(
                        Icons.close,
                        size: 16,
                        color: cs.onSurface.withValues(alpha: 0.4),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Divider(
            height: 1,
            color: cs.onSurface.withValues(alpha: 0.1),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Saved skills grouped as one "Skills" folder
// ---------------------------------------------------------------------------

class _SavedSkillsGroup extends StatelessWidget {
  final ValueChanged<Skill> onOpen;

  const _SavedSkillsGroup({required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final saved = context.watch<SkillsProvider>().savedSkills;
    final cs = Theme.of(context).colorScheme;
    return ListView(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: [
              Icon(Icons.folder, size: 18, color: cs.primary),
              const SizedBox(width: 8),
              const Text(
                'SKILLS',
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 2,
                ),
                decoration: BoxDecoration(
                  color: cs.onSurface.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '${saved.length}',
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
        ...saved.map(
          (skill) => Column(
            children: [
              SkillRow(
                skill: skill,
                saved: true,
                onTap: () => onOpen(skill),
                onRemove: () =>
                    context.read<SkillsProvider>().removeSkill(skill.id),
              ),
              const Divider(height: 1),
            ],
          ),
        ),
        const SizedBox(height: 80),
      ],
    );
  }
}

class _EmptyState extends StatelessWidget {
  final VoidCallback onTrySample;

  const _EmptyState({required this.onTrySample});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.psychology_outlined,
              size: 56,
              color: cs.onSurface.withValues(alpha: 0.2),
            ),
            const SizedBox(height: 16),
            Text(
              'Search ClawHub, skills.sh and Hermes for reusable skills.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: cs.onSurface.withValues(alpha: 0.55),
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: onTrySample,
              child: const Text('Try "pdf"'),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Detail sheet: SKILL.md + version-history (checkpoint) dropdown
// ---------------------------------------------------------------------------

class _SkillDetailSheet extends StatefulWidget {
  final Skill skill;

  const _SkillDetailSheet({required this.skill});

  @override
  State<_SkillDetailSheet> createState() => _SkillDetailSheetState();
}

class _SkillDetailSheetState extends State<_SkillDetailSheet> {
  String? _md;
  List<SkillCheckpoint> _history = const [];
  SkillCheckpoint? _selected;
  String? _checkpointMd;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final provider = context.read<SkillsProvider>();
    final md = await provider.readSkillMd(widget.skill);
    final history = await provider.historyFor(widget.skill);
    if (!mounted) return;
    setState(() {
      _md = md;
      _history = history;
      _loading = false;
    });
  }

  Future<void> _viewCheckpoint(SkillCheckpoint? cp) async {
    setState(() {
      _selected = cp;
      _checkpointMd = null;
    });
    if (cp == null) return;
    final md = await context
        .read<SkillsProvider>()
        .openCheckpoint(widget.skill, cp.sha);
    if (!mounted) return;
    setState(() => _checkpointMd = md ?? '(file absent at this checkpoint)');
  }

  @override
  Widget build(BuildContext context) {
    final skill = widget.skill;
    final showing = _selected == null ? _md : _checkpointMd;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      builder: (context, scrollController) => ListView(
        controller: scrollController,
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Text(
                  skill.name.isEmpty ? skill.slug : skill.name,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              SkillAuditBadge(
                verdict: skill.audit,
                reason: skill.auditReason,
              ),
            ],
          ),
          const SizedBox(height: 4),
          if (skill.description.isNotEmpty)
            Text(
              skill.description,
              style: TextStyle(
                fontSize: 13.5,
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.65),
                height: 1.4,
              ),
            ),
          const SizedBox(height: 12),
          // ── Version-history dropdown (folder checkpoints) ──────────
          if (_history.isNotEmpty)
            DropdownButtonFormField<SkillCheckpoint?>(
              initialValue: _selected,
              decoration: const InputDecoration(
                labelText: 'Version history',
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
              ),
              items: [
                const DropdownMenuItem<SkillCheckpoint?>(
                  value: null,
                  child: Text('Latest'),
                ),
                ..._history.map(
                  (cp) => DropdownMenuItem<SkillCheckpoint?>(
                    value: cp,
                    child: Text(
                      '${cp.sha.substring(0, 7)} · ${cp.message}',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ],
              onChanged: _viewCheckpoint,
            ),
          const SizedBox(height: 12),
          if (_loading)
            const Center(child: CircularProgressIndicator())
          else if (showing != null)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(
                  context,
                ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(12),
              ),
              child: SelectableText(
                showing,
                style: const TextStyle(fontSize: 13, height: 1.5),
              ),
            )
          else
            Text(
              'SKILL.md not cached yet — save the skill while online to cache its folder.',
              style: TextStyle(
                fontSize: 13,
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.5),
              ),
            ),
        ],
      ),
    );
  }
}
