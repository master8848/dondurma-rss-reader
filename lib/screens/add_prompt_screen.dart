/// WP4 UI: Markdown editor for new prompts and edits.
///
/// [initialText] serves the hotkey add-prompt flow (selection capture first,
/// clipboard fallback — see ARCHITECTURE.md section 8): the capture service
/// result pre-fills the body. Saving goes through [LibraryController.save]
/// (auto-commit happens downstream when the store owns a [GitService]).
///
/// NOTE (editor dependency): `flutter_quill` 11.6 is approved but NOT in
/// `pubspec.yaml` (WP4 may not run `flutter pub` or edit the pubspec), so
/// this screen ships a plain multiline Markdown [TextField] fallback. When
/// the dependency lands, swap [_bodyField] for a QuillEditor without
/// changing this screen's constructor or save path.
library;

import 'package:flutter/material.dart';

import '../promptlib/prompt_doc.dart';
import '../promptlib/ui/library_controller.dart';

/// Creates a new prompt, or edits [existing] (offline `subscriptions/`
/// mirrors save back to the SAME file via [LibraryController.saveInPlace];
/// non-offline docs keep the fork-then-save path so the subscription mirror
/// is never mutated by a library edit).
class AddPromptScreen extends StatefulWidget {
  final LibraryController controller;
  final String initialText;
  final PromptDoc? existing;

  /// True when [existing] lives under `subscriptions/` (resolve via
  /// `LibraryController.isOffline`). Offline edits save in place — no fork,
  /// no duplicate — so git sync picks up the change.
  final bool isOffline;

  const AddPromptScreen({
    super.key,
    required this.controller,
    this.initialText = '',
    this.existing,
    this.isOffline = false,
  });

  @override
  State<AddPromptScreen> createState() => _AddPromptScreenState();
}

class _AddPromptScreenState extends State<AddPromptScreen> {
  late final TextEditingController _title;
  late final TextEditingController _tags;
  late final TextEditingController _body;
  bool _saving = false;
  String? _error;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final PromptDoc? existing = widget.existing;
    _title = TextEditingController(text: existing?.title ?? '');
    _tags = TextEditingController(text: existing?.tags.join(', ') ?? '');
    _body = TextEditingController(text: existing?.body ?? widget.initialText);
  }

  @override
  void dispose() {
    _title.dispose();
    _tags.dispose();
    _body.dispose();
    super.dispose();
  }

  List<String> get _tagList => _tags.text
      .split(',')
      .map((String t) => t.trim())
      .where((String t) => t.isNotEmpty)
      .toList();

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final PromptDoc? existing = widget.existing;
      if (existing == null) {
        await widget.controller.save(PromptDoc(
          id: generateUuidV4(),
          title: _title.text.trim(),
          tags: _tagList,
          body: _body.text,
        ));
      } else {
        // Offline edit: save back to the SAME mirror file (no fork, no
        // duplicate) so git sync picks up the change. Otherwise fork-on-edit
        // for subscribed items; plain save for library items
        // (forkToLibrary is idempotent, so calling it unconditionally for
        // non-offline docs is safe and keeps this screen free of
        // scope-tracking logic).
        if (widget.isOffline) {
          await widget.controller.saveInPlace(existing.copyWith(
            title: _title.text.trim(),
            tags: _tagList,
            body: _body.text,
          ));
        } else {
          final PromptDoc forked =
              await widget.controller.forkToLibrary(existing.id);
          await widget.controller.save(forked.copyWith(
            title: _title.text.trim(),
            tags: _tagList,
            body: _body.text,
          ));
        }
      }
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Save failed: $e';
          _saving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_isEdit ? 'Edit prompt' : 'Add prompt')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _title,
            decoration: const InputDecoration(
              labelText: 'Title',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _tags,
            decoration: const InputDecoration(
              labelText: 'Tags (comma-separated)',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _body,
            decoration: const InputDecoration(
              labelText: 'Body (Markdown)',
              hintText: '# Heading\n\nPrompt text with {{variables}}…',
              border: OutlineInputBorder(),
              alignLabelWithHint: true,
            ),
            maxLines: 16,
            minLines: 8,
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _saving ? null : _save,
            icon: _saving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save),
            label: Text(_isEdit ? 'Save changes' : 'Save prompt'),
          ),
        ],
      ),
    );
  }
}
