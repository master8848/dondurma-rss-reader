/// WP4 UI: library browser — search by query/tags/type over [PromptStore].
///
/// Route target for ARCHITECTURE.md section 4 `/library` (router wiring is
/// out of scope for WP4; push this screen with `Navigator` or register the
/// route in `lib/router/app_router.dart` in a later workstream).
library;

import 'package:flutter/material.dart';

import '../promptlib/feed_config.dart';
import '../promptlib/git_service.dart';
import '../promptlib/prompt_doc.dart';
import '../promptlib/ui/library_controller.dart';
import '../widgets/prompt_list_tile.dart';
import 'add_prompt_screen.dart';
import 'prompt_detail_screen.dart';

/// Browses local prompts with query / tag / type filters, plus the feed list
/// with a per-feed type dropdown (writes `.promptlib/feeds.yaml` via
/// [LibraryController.setFeedType]).
class LibraryScreen extends StatefulWidget {
  final LibraryController controller;
  final GitService? git;

  const LibraryScreen({super.key, required this.controller, this.git});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  final TextEditingController _query = TextEditingController();
  final TextEditingController _tags = TextEditingController();
  FeedType? _typeFilter;
  Future<List<PromptDoc>>? _results;
  bool _savingFeedType = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _query.dispose();
    _tags.dispose();
    super.dispose();
  }

  Set<String> get _tagSet => _tags.text
      .split(',')
      .map((String t) => t.trim())
      .where((String t) => t.isNotEmpty)
      .toSet();

  void _refresh() {
    setState(() {
      _results = widget.controller.list(
        query: _query.text.isEmpty ? null : _query.text,
        tags: _tagSet.isEmpty ? null : _tagSet,
        type: _typeFilter,
      );
    });
  }

  Future<void> _openDetail(String id) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PromptDetailScreen(
          controller: widget.controller,
          promptId: id,
          git: widget.git,
        ),
      ),
    );
    if (mounted) _refresh();
  }

  Future<void> _openAdd() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AddPromptScreen(controller: widget.controller),
      ),
    );
    if (mounted) _refresh();
  }

  Future<void> _changeFeedType(String feedUrl, FeedType type) async {
    setState(() => _savingFeedType = true);
    try {
      await widget.controller.setFeedType(feedUrl: feedUrl, type: type);
    } finally {
      if (mounted) {
        setState(() => _savingFeedType = false);
        _refresh();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Library')),
      floatingActionButton: FloatingActionButton(
        onPressed: _openAdd,
        tooltip: 'Add prompt',
        child: const Icon(Icons.add),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _query,
            decoration: const InputDecoration(
              labelText: 'Search',
              hintText: 'Title, body, or tags…',
              prefixIcon: Icon(Icons.search),
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => _refresh(),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _tags,
                  decoration: const InputDecoration(
                    labelText: 'Tags (comma-separated)',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (_) => _refresh(),
                ),
              ),
              const SizedBox(width: 12),
              DropdownButton<FeedType?>(
                value: _typeFilter,
                hint: const Text('Type: all'),
                items: const [
                  DropdownMenuItem<FeedType?>(
                    value: null,
                    child: Text('All'),
                  ),
                  DropdownMenuItem<FeedType?>(
                    value: FeedType.prompt,
                    child: Text('Prompt'),
                  ),
                  DropdownMenuItem<FeedType?>(
                    value: FeedType.article,
                    child: Text('Article'),
                  ),
                  DropdownMenuItem<FeedType?>(
                    value: FeedType.other,
                    child: Text('Other'),
                  ),
                ],
                onChanged: (FeedType? v) {
                  _typeFilter = v;
                  _refresh();
                },
              ),
            ],
          ),
          const SizedBox(height: 8),
          ExpansionTile(
            title: Text('Feeds (${widget.controller.feeds.length})'),
            subtitle: const Text('Per-feed type syncs to feeds.yaml'),
            children: [
              if (_savingFeedType) const LinearProgressIndicator(),
              for (final FeedConfigEntry feed in widget.controller.feeds)
                ListTile(
                  dense: true,
                  title: Text(
                    feed.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    feed.url,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: DropdownButton<FeedType>(
                    value: feed.type,
                    items: const [
                      DropdownMenuItem(
                        value: FeedType.prompt,
                        child: Text('Prompt'),
                      ),
                      DropdownMenuItem(
                        value: FeedType.article,
                        child: Text('Article'),
                      ),
                      DropdownMenuItem(
                        value: FeedType.other,
                        child: Text('Other'),
                      ),
                    ],
                    onChanged: (FeedType? v) {
                      if (v != null) _changeFeedType(feed.url, v);
                    },
                  ),
                ),
              if (widget.controller.feeds.isEmpty)
                const ListTile(
                  dense: true,
                  title: Text('No feeds registered yet.'),
                ),
            ],
          ),
          const Divider(),
          FutureBuilder<List<PromptDoc>>(
            future: _results,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              if (snapshot.hasError) {
                return Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text('Failed to load library: ${snapshot.error}'),
                );
              }
              final List<PromptDoc> docs = snapshot.data ?? const [];
              if (docs.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(child: Text('No prompts match.')),
                );
              }
              return Column(
                children: [
                  for (final PromptDoc doc in docs)
                    PromptListTile(
                      doc: doc,
                      onTap: () => _openDetail(doc.id),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}
