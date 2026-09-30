/// WP4 UI: prompt detail — body preview plus a history entry point.
///
/// Route target for ARCHITECTURE.md section 4 `/library/:id` (router wiring
/// is out of scope for WP4; push with `Navigator` or register the route in
/// `lib/router/app_router.dart` later).
library;

import 'package:flutter/material.dart';

import '../promptlib/git_service.dart';
import '../promptlib/prompt_doc.dart';
import '../promptlib/ui/library_controller.dart';
import '../promptlib/version_ux.dart';
import '../utils/app_toast.dart';
import '../widgets/open_in_button.dart';
import '../widgets/prompt_diff_view.dart';
import '../widgets/sync_state_chip.dart';
import 'add_prompt_screen.dart';

/// Shows one prompt's body plus recent history for its file.
///
/// History resolves via [git] (`GitService.log`, scoped to [filePath] when
/// known, else the recent repo log). When [git] is null a placeholder is
/// shown instead of failing. [previousBody], when provided, renders a
/// [PromptDiffView] of old vs current text above the full body.
class PromptDetailScreen extends StatefulWidget {
  final LibraryController controller;
  final String promptId;
  final GitService? git;
  final String? filePath;
  final String? previousBody;

  const PromptDetailScreen({
    super.key,
    required this.controller,
    required this.promptId,
    this.git,
    this.filePath,
    this.previousBody,
  });

  @override
  State<PromptDetailScreen> createState() => _PromptDetailScreenState();
}

class _PromptDetailScreenState extends State<PromptDetailScreen> {
  Future<PromptDoc?>? _doc;
  Future<({String? path, bool isOffline})>? _fileState;
  Future<List<CommitInfo>>? _history;

  @override
  void initState() {
    super.initState();
    _doc = widget.controller.getById(widget.promptId);
    // Saved prompts always map to a file on disk (library/,
    // prompts/<category>/, subscriptions/<feed>/): prefer the explicit
    // [filePath], else resolve the exact id-based path + offline state via
    // the store (rename- and snapshot-proof). History scopes to the file.
    _fileState = _resolveFileState();
    final GitService? git = widget.git;
    if (git != null) {
      _history = _fileState!.then(
        (({String? path, bool isOffline}) s) =>
            git.log(path: s.path, limit: 20),
      );
    }
  }

  /// Explicit `filePath` wins for location; otherwise the exact store lookup
  /// for this prompt id (path + subscriptions-scope offline flag). Never
  /// throws — unresolvable means "no file" (null), and the [OpenInButton]
  /// hides itself.
  Future<({String? path, bool isOffline})> _resolveFileState() async {
    final String? direct = widget.filePath;
    if (direct != null && direct.trim().isNotEmpty) {
      bool offline = false;
      try {
        offline = await widget.controller.isOffline(widget.promptId);
      } catch (_) {}
      return (path: direct, isOffline: offline);
    }
    try {
      return await widget.controller.fileStateFor(widget.promptId);
    } catch (_) {
      return (path: null, isOffline: false);
    }
  }

  Future<void> _openEdit(PromptDoc doc) async {
    // Offline files edit in place (same path, no fork); everything else
    // keeps the fork-on-edit path via AddPromptScreen.
    bool offline = false;
    try {
      offline = await widget.controller.isOffline(widget.promptId);
    } catch (_) {}
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AddPromptScreen(
          controller: widget.controller,
          existing: doc,
          isOffline: offline,
        ),
      ),
    );
    if (mounted) {
      setState(() {
        _doc = widget.controller.getById(widget.promptId);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Prompt'),
        actions: [
          // "Open In" split button — unified on the resolved file path
          // (explicit filePath, else the store id lookup); visible only
          // when it maps to a real file on disk, else hidden.
          FutureBuilder<({String? path, bool isOffline})>(
            future: _fileState,
            builder: (context, snapshot) =>
                OpenInButton(path: snapshot.data?.path, compact: true),
          ),
        ],
      ),
      body: FutureBuilder<PromptDoc?>(
        future: _doc,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final PromptDoc? doc = snapshot.data;
          if (doc == null) {
            return const Center(child: Text('Prompt not found.'));
          }
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                doc.title.isEmpty ? '(untitled)' : doc.title,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 8),
              if (doc.tags.isNotEmpty)
                Wrap(
                  spacing: 6,
                  children: [
                    for (final String tag in doc.tags) Chip(label: Text(tag)),
                  ],
                ),
              if (doc.sourceFeed != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    'Source: ${doc.sourceFeed}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              if (doc.needsReview)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text(
                    'Needs review: this id was recovered on parse.',
                    style: TextStyle(color: Colors.orange),
                  ),
                ),
              _SyncSection(
                controller: widget.controller,
                promptId: widget.promptId,
              ),
              const SizedBox(height: 16),
              if (widget.previousBody != null) ...[
                Text(
                  'Changes',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Card(
                  clipBehavior: Clip.antiAlias,
                  child: PromptDiffView(
                    oldText: widget.previousBody!,
                    newText: doc.body,
                  ),
                ),
                const SizedBox(height: 16),
              ],
              Text(
                'Body',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: SelectableText(doc.body),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'History',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              _historySection(),
              const SizedBox(height: 80),
            ],
          );
        },
      ),
      floatingActionButton: FutureBuilder<({String? path, bool isOffline})>(
        future: _fileState,
        builder: (context, stateSnapshot) {
          final bool offline = stateSnapshot.data?.isOffline ?? false;
          return FutureBuilder<PromptDoc?>(
            future: _doc,
            builder: (context, snapshot) {
              final PromptDoc? doc = snapshot.data;
              if (doc == null) return const SizedBox.shrink();
              return FloatingActionButton(
                onPressed: () => _openEdit(doc),
                tooltip: offline
                    ? 'Edit in place (offline file)'
                    : 'Edit (forks subscribed items to library)',
                child: const Icon(Icons.edit),
              );
            },
          );
        },
      ),
    );
  }

  Widget _historySection() {
    final Future<List<CommitInfo>>? history = _history;
    if (history == null) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text(
            'History unavailable: no git service attached to this view.',
          ),
        ),
      );
    }
    return FutureBuilder<List<CommitInfo>>(
      future: history,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text('History failed to load: ${snapshot.error}'),
            ),
          );
        }
        final List<CommitInfo> commits = snapshot.data ?? const [];
        if (commits.isEmpty) {
          return const Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text('No commits yet.'),
            ),
          );
        }
        return Card(
          child: Column(
            children: [
              for (final CommitInfo c in commits)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.history, size: 18),
                  title: Text(
                    c.message,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    '${c.hash.length > 7 ? c.hash.substring(0, 7) : c.hash}'
                    ' · ${c.author}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Sync section: local-vs-remote tri-state with one-tap actions.
// ---------------------------------------------------------------------------

/// Banner under the prompt header showing the sync verdict for [promptId]
/// with one-tap actions and no dead ends:
///
/// * Up to date — quiet chip only.
/// * Edited here — "See what changed" expands a diff (source vs mine).
/// * Update available — Update (take the source), Keep mine (dismiss until
///   the source moves again), See what changed.
/// * Not checked yet — shown only when a source exists; Retry re-checks.
///
/// Pure-local prompts (never subscribed: no mirror, no verdict) render
/// nothing. Checks are memoized and best-effort — the section never blocks
/// the body below it.
class _SyncSection extends StatefulWidget {
  final LibraryController controller;
  final String promptId;

  const _SyncSection({required this.controller, required this.promptId});

  @override
  State<_SyncSection> createState() => _SyncSectionState();
}

class _SyncSectionState extends State<_SyncSection> {
  Future<PromptSyncSnapshot>? _snap;
  Future<({String oldText, String newText})?>? _diff;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _snap = widget.controller.syncSnapshotFor(widget.promptId);
  }

  void _reload({bool force = false}) {
    setState(() {
      _snap = widget.controller.syncSnapshotFor(
        widget.promptId,
        force: force,
      );
      _diff = null;
    });
  }

  Future<void> _takeUpdate() async {
    setState(() => _busy = true);
    try {
      final PromptDoc? saved =
          await widget.controller.takeSyncUpdate(widget.promptId);
      if (!mounted) return;
      showAppToast(
        saved == null ? 'Nothing new to take' : 'Updated from the source',
        type: saved == null ? AppToastType.info : AppToastType.success,
      );
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        _reload(force: true);
      }
    }
  }

  Future<void> _keepMine() async {
    setState(() => _busy = true);
    try {
      await widget.controller.keepSyncMine(widget.promptId);
      if (!mounted) return;
      showAppToast('Kept your copy', type: AppToastType.success);
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        _reload(force: true);
      }
    }
  }

  Future<void> _checkForUpdates() async {
    setState(() => _busy = true);
    try {
      await widget.controller.refreshSourceFor(widget.promptId);
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        _reload(force: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<PromptSyncSnapshot>(
      future: _snap,
      builder: (context, snapshot) {
        final PromptSyncSnapshot? snap = snapshot.data;
        if (snap == null) return const SizedBox.shrink();
        // Pure-local prompt with no source and nothing to say: hide.
        if (snap.state == ItemSyncState.unknown && snap.remote == null) {
          return const SizedBox.shrink();
        }
        return Card(
          margin: const EdgeInsets.only(top: 12),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    SyncStateChip(state: snap.state, showUnknown: true),
                    const Spacer(),
                    if (_busy)
                      const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    else if (snap.state == ItemSyncState.unknown)
                      TextButton(
                        onPressed: _checkForUpdates,
                        child: const Text('Check again'),
                      )
                    else if (snap.state == ItemSyncState.remoteNewer)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          TextButton(
                            onPressed: _keepMine,
                            child: const Text('Keep mine'),
                          ),
                          const SizedBox(width: 4),
                          FilledButton(
                            onPressed: _takeUpdate,
                            child: const Text('Update'),
                          ),
                        ],
                      ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    snap.state.detail,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                if (snap.state == ItemSyncState.localNewer ||
                    snap.state == ItemSyncState.remoteNewer) ...[
                  const SizedBox(height: 4),
                  TextButton.icon(
                    onPressed: () {
                      setState(() {
                        _diff = _diff == null
                            ? widget.controller.syncDiffFor(widget.promptId)
                            : null;
                      });
                    },
                    icon: const Icon(Icons.compare_arrows, size: 18),
                    label: Text(
                      _diff == null
                          ? 'See what changed'
                          : 'Hide changes',
                    ),
                  ),
                  if (_diff != null)
                    FutureBuilder<({String oldText, String newText})?>(
                      future: _diff,
                      builder: (context, diffSnap) {
                        if (diffSnap.connectionState ==
                            ConnectionState.waiting) {
                          return const Padding(
                            padding: EdgeInsets.all(8),
                            child: Center(
                              child: CircularProgressIndicator(),
                            ),
                          );
                        }
                        final diff = diffSnap.data;
                        if (diff == null) {
                          return const Text(
                            'Nothing to compare right now.',
                          );
                        }
                        return Container(
                          clipBehavior: Clip.antiAlias,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: PromptDiffView(
                            oldText: diff.oldText,
                            newText: diff.newText,
                          ),
                        );
                      },
                    ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}
