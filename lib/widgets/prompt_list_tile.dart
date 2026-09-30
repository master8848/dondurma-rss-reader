/// WP4 UI: single prompt row for library/feed lists.
library;

import 'package:flutter/material.dart';

import '../promptlib/prompt_doc.dart';
import 'open_in_button.dart';

/// Compact row showing a [PromptDoc]: title, tag chips, source feed.
/// Reuses the app's Material 3 list styling; navigation is left to the caller
/// via [onTap] (ARCHITECTURE.md section 4 routes `/library/:id` can wrap it).
class PromptListTile extends StatelessWidget {
  final PromptDoc doc;

  /// Absolute on-disk file for this prompt (resolve via
  /// `LibraryController.pathForId(doc.id)`). Saved prompts live in
  /// `library/`, `prompts/<category>/`, or `subscriptions/<feed>/`, so this
  /// resolves for every stored doc; the [OpenInButton] still hides itself
  /// when [filePath] is null or missing on disk.
  final String? filePath;
  final VoidCallback? onTap;

  const PromptListTile({
    super.key,
    required this.doc,
    this.filePath,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return ListTile(
      leading: Icon(
        doc.sourceFeed == null ? Icons.edit_note_outlined : Icons.rss_feed,
        color: cs.primary,
      ),
      title: Text(
        doc.title.isEmpty ? '(untitled)' : doc.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (doc.body.isNotEmpty)
            Text(
              doc.body.split('\n').first,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          if (doc.tags.isNotEmpty || doc.sourceFeed != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Wrap(
                spacing: 4,
                runSpacing: 4,
                children: [
                  for (final String tag in doc.tags)
                    Chip(
                      label: Text(tag),
                      labelStyle: const TextStyle(fontSize: 11),
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                    ),
                  if (doc.sourceFeed != null)
                    Chip(
                      label: Text(
                        doc.sourceFeed!,
                        overflow: TextOverflow.ellipsis,
                      ),
                      labelStyle: const TextStyle(fontSize: 11),
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                    ),
                ],
              ),
            ),
          if (doc.needsReview)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Needs review (recovered id)',
                style: TextStyle(color: cs.error, fontSize: 12),
              ),
            ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // "Open In" split button — every saved prompt maps to a file on
          // disk (library/, prompts/<category>/, subscriptions/<feed>/);
          // hidden by its own visibility rule when filePath is null/missing.
          OpenInButton(path: filePath, compact: true),
          const Icon(Icons.chevron_right),
        ],
      ),
      onTap: onTap,
    );
  }
}
