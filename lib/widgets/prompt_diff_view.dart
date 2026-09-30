/// WP4 UI: line/word diff viewer (old vs new text).
///
/// Self-contained LCS diff over lines, with word-level highlighting inside
/// paired change blocks. No third-party diff import: `pretty_diff_text` /
/// `diff_match_patch` are approved but NOT in `pubspec.yaml` (WP4 may not run
/// `flutter pub` or edit the pubspec), so this widget ships its own minimal
/// engine with the same render contract (removed = red, added = green) and
/// can be swapped for the package implementation later without changing
/// callers — [PromptDiffView] keeps the `oldText`/`newText` boundary.
library;

import 'package:flutter/material.dart';

enum _Kind { same, removed, added }

class _Op {
  final _Kind kind;
  final String text;
  const _Op(this.kind, this.text);
}

/// Computes a line diff via LCS on the two line lists.
List<_Op> computeLineDiff(String oldText, String newText) {
  final List<String> a = oldText.split('\n');
  final List<String> b = newText.split('\n');
  final int n = a.length;
  final int m = b.length;
  final List<List<int>> dp =
      List<List<int>>.generate(n + 1, (_) => List<int>.filled(m + 1, 0));
  for (int i = n - 1; i >= 0; i--) {
    for (int j = m - 1; j >= 0; j--) {
      dp[i][j] = a[i] == b[j]
          ? dp[i + 1][j + 1] + 1
          : (dp[i + 1][j] >= dp[i][j + 1] ? dp[i + 1][j] : dp[i][j + 1]);
    }
  }
  final List<_Op> ops = <_Op>[];
  int i = 0;
  int j = 0;
  while (i < n && j < m) {
    if (a[i] == b[j]) {
      ops.add(_Op(_Kind.same, a[i]));
      i++;
      j++;
    } else if (dp[i + 1][j] >= dp[i][j + 1]) {
      ops.add(_Op(_Kind.removed, a[i]));
      i++;
    } else {
      ops.add(_Op(_Kind.added, b[j]));
      j++;
    }
  }
  while (i < n) {
    ops.add(_Op(_Kind.removed, a[i]));
    i++;
  }
  while (j < m) {
    ops.add(_Op(_Kind.added, b[j]));
    j++;
  }
  return ops;
}

/// Word-level LCS returning per-word flags (true = changed) for a
/// removed/added line pair.
({List<bool> oldChanged, List<bool> newChanged}) wordFlags(
  String oldLine,
  String newLine,
) {
  final List<String> a = oldLine.split(' ');
  final List<String> b = newLine.split(' ');
  final int n = a.length;
  final int m = b.length;
  final List<List<int>> dp =
      List<List<int>>.generate(n + 1, (_) => List<int>.filled(m + 1, 0));
  for (int i = n - 1; i >= 0; i--) {
    for (int j = m - 1; j >= 0; j--) {
      dp[i][j] = a[i] == b[j]
          ? dp[i + 1][j + 1] + 1
          : (dp[i + 1][j] >= dp[i][j + 1] ? dp[i + 1][j] : dp[i][j + 1]);
    }
  }
  final List<bool> oldChanged = List<bool>.filled(n, true);
  final List<bool> newChanged = List<bool>.filled(m, true);
  int i = 0;
  int j = 0;
  while (i < n && j < m) {
    if (a[i] == b[j]) {
      oldChanged[i] = false;
      newChanged[j] = false;
      i++;
      j++;
    } else if (dp[i + 1][j] >= dp[i][j + 1]) {
      i++;
    } else {
      j++;
    }
  }
  return (oldChanged: oldChanged, newChanged: newChanged);
}

/// Renders [oldText] vs [newText]: context lines plain, removed lines red
/// with `-` prefix, added lines green with `+` prefix. Adjacent
/// removed+added pairs additionally highlight the changed words.
class PromptDiffView extends StatelessWidget {
  final String oldText;
  final String newText;

  const PromptDiffView({
    super.key,
    required this.oldText,
    required this.newText,
  });

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final List<_Op> ops = computeLineDiff(oldText, newText);
    final List<Widget> rows = <Widget>[];
    int k = 0;
    while (k < ops.length) {
      final _Op op = ops[k];
      if (op.kind == _Kind.same) {
        rows.add(_line(context, '  ${op.text}', null));
        k++;
      } else {
        // Collect one change block: removed lines then added lines.
        final List<String> removed = <String>[];
        final List<String> added = <String>[];
        while (k < ops.length && ops[k].kind == _Kind.removed) {
          removed.add(ops[k].text);
          k++;
        }
        while (k < ops.length && ops[k].kind == _Kind.added) {
          added.add(ops[k].text);
          k++;
        }
        final int pairs =
            removed.length < added.length ? removed.length : added.length;
        for (int p = 0; p < pairs; p++) {
          final flags = wordFlags(removed[p], added[p]);
          rows.add(_wordLine(
            context,
            removed[p].split(' '),
            flags.oldChanged,
            cs.errorContainer,
            cs.onErrorContainer,
            '- ',
          ));
          rows.add(_wordLine(
            context,
            added[p].split(' '),
            flags.newChanged,
            cs.tertiaryContainer,
            cs.onTertiaryContainer,
            '+ ',
          ));
        }
        for (int p = pairs; p < removed.length; p++) {
          rows.add(_line(
            context,
            '- ${removed[p]}',
            cs.errorContainer,
          ));
        }
        for (int p = pairs; p < added.length; p++) {
          rows.add(_line(
            context,
            '+ ${added[p]}',
            cs.tertiaryContainer,
          ));
        }
      }
    }
    if (rows.isEmpty) {
      rows.add(_line(context, '(no content)', null));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: rows,
    );
  }

  Widget _line(BuildContext context, String text, Color? background) {
    return Container(
      color: background,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      child: SelectableText(
        text.isEmpty ? ' ' : text,
        style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
      ),
    );
  }

  Widget _wordLine(
    BuildContext context,
    List<String> words,
    List<bool> changed,
    Color background,
    Color changedBackground,
    String prefix,
  ) {
    return Container(
      color: background,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      child: SelectableText.rich(
        TextSpan(
          style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
          children: [
            TextSpan(text: prefix),
            for (int w = 0; w < words.length; w++)
              TextSpan(
                text: words[w] + (w + 1 < words.length ? ' ' : ''),
                style: changed[w]
                    ? TextStyle(
                        backgroundColor: changedBackground.withValues(
                          alpha: 0.35,
                        ),
                        fontWeight: FontWeight.bold,
                      )
                    : null,
              ),
          ],
        ),
      ),
    );
  }
}
