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
import '../widgets/open_in_button.dart';
import '../widgets/prompt_diff_view.dart';
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
  Future<List<CommitInfo>>? _history;

  @override
  void initState() {
    super.initState();
    _doc = widget.controller.getById(widget.promptId);
    final GitService? git = widget.git;
    if (git != null) {
      _history = git.log(path: widget.filePath, limit: 20);
    }
  }

  Future<void> _openEdit(PromptDoc doc) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AddPromptScreen(
          controller: widget.controller,
          existing: doc,
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
          // "Open In" split button — visible only when this prompt maps to
          // a real file on disk (filePath set + exists), else hidden.
          OpenInButton(path: widget.filePath, compact: true),
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
      floatingActionButton: FutureBuilder<PromptDoc?>(
        future: _doc,
        builder: (context, snapshot) {
          final PromptDoc? doc = snapshot.data;
          if (doc == null) return const SizedBox.shrink();
          return FloatingActionButton(
            onPressed: () => _openEdit(doc),
            tooltip: 'Edit (forks subscribed items to library)',
            child: const Icon(Icons.edit),
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
