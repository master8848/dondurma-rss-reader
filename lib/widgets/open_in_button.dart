import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../providers/settings_provider.dart';
import '../services/open_in_service.dart';
import '../utils/app_toast.dart';

/// Icon per [OpenInTarget] for the split button and its menu.
IconData openInIcon(OpenInTarget target) {
  switch (target) {
    case OpenInTarget.reveal:
      return Icons.folder_open_rounded;
    case OpenInTarget.zed:
      return Icons.flash_on_outlined;
    case OpenInTarget.sublime:
      return Icons.text_snippet_outlined;
    case OpenInTarget.vscode:
      return Icons.code_rounded;
    case OpenInTarget.copyPath:
      return Icons.content_copy_rounded;
  }
}

/// ONE "Open In" split button for any row that has a real file on disk.
///
/// - Main tap opens [path] with the remembered default
///   (`SettingsProvider.openInDefault`, Hive key `'openInDefault'`).
/// - Chevron opens the dropdown menu (Finder/Explorer, Zed, Sublime Text,
///   VS Code, Copy path). Picking from the menu BOTH executes AND saves the
///   pick as the new default, so the main button updates on the next render.
/// - Hidden entirely ([SizedBox.shrink]) when [path] is null/blank or does
///   not exist on disk (`File`/`Directory.existsSync`).
/// - [compact] renders AppBar-cluster-sized circles (matches
///   `CircleActionButton`); otherwise a labeled outlined split button.
class OpenInButton extends StatelessWidget {
  final String? path;
  final bool compact;

  const OpenInButton({super.key, required this.path, this.compact = false});

  @override
  Widget build(BuildContext context) {
    final p = path;
    if (p == null || p.trim().isEmpty || !existsOnDisk(p)) {
      return const SizedBox.shrink();
    }
    final current = context.watch<SettingsProvider>().openInDefault;
    if (compact) return _compact(context, p, current);
    return _full(context, p, current);
  }

  // -------------------------------------------------------------------------
  // Activation: execute (+ remember when picked from the menu)
  // -------------------------------------------------------------------------

  Future<void> _activate(
    BuildContext context,
    String path,
    OpenInTarget target, {
    required bool remember,
  }) async {
    if (remember) {
      await context.read<SettingsProvider>().setOpenInDefault(target);
    }
    if (!context.mounted) return;
    if (target == OpenInTarget.copyPath) {
      await Clipboard.setData(ClipboardData(text: path));
      if (context.mounted) {
        showAppToast('Path copied to clipboard', type: AppToastType.success);
      }
      return;
    }
    final ok = await openWith(target, path);
    if (!ok && context.mounted) {
      showAppToast(
        'Could not open with ${labelFor(target)}',
        type: AppToastType.error,
      );
    }
  }

  List<PopupMenuEntry<OpenInTarget>> _menuItems(
    OpenInTarget current,
  ) {
    return [
      for (final target in OpenInTarget.values)
        PopupMenuItem(
          value: target,
          child: Row(
            children: [
              Icon(openInIcon(target), size: 18),
              const SizedBox(width: 10),
              Expanded(child: Text(labelFor(target))),
              if (target == current)
                const Icon(Icons.check_rounded, size: 18),
            ],
          ),
        ),
    ];
  }

  void _pick(BuildContext context, String path, OpenInTarget target) {
    // Remember first so the main button reflects the pick on next render,
    // then execute — menu picks do both.
    _activate(context, path, target, remember: true);
  }

  // -------------------------------------------------------------------------
  // Full split button (rows, sheets)
  // -------------------------------------------------------------------------

  Widget _full(BuildContext context, String path, OpenInTarget current) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(color: cs.outlineVariant),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            InkWell(
              borderRadius: const BorderRadius.horizontal(
                left: Radius.circular(20),
              ),
              onTap: () => _activate(
                context,
                path,
                current,
                remember: false,
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(openInIcon(current), size: 16, color: cs.primary),
                    const SizedBox(width: 6),
                    Text(
                      labelFor(current),
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: cs.primary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Container(width: 1, height: 20, color: cs.outlineVariant),
            PopupMenuButton<OpenInTarget>(
              padding: EdgeInsets.zero,
              iconSize: 16,
              icon: Icon(Icons.expand_more_rounded, color: cs.primary),
              tooltip: 'Choose open target',
              onSelected: (t) => _pick(context, path, t),
              itemBuilder: (_) => _menuItems(current),
            ),
          ],
        ),
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Compact circles (AppBar clusters, matches CircleActionButton sizing)
  // -------------------------------------------------------------------------

  Widget _compact(BuildContext context, String path, OpenInTarget current) {
    final cs = Theme.of(context).colorScheme;
    Widget circle(Widget child, {VoidCallback? onTap, String tooltip = ''}) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Tooltip(
          message: tooltip,
          child: Material(
            color: cs.surface.withValues(alpha: 0.7),
            shape: const CircleBorder(),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onTap,
              child: SizedBox(width: 36, height: 36, child: child),
            ),
          ),
        ),
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        circle(
          Icon(openInIcon(current), size: 18, color: cs.onSurface),
          tooltip: labelFor(current),
          onTap: () => _activate(context, path, current, remember: false),
        ),
        PopupMenuButton<OpenInTarget>(
          padding: EdgeInsets.zero,
          iconSize: 14,
          icon: Icon(Icons.expand_more_rounded, color: cs.onSurface),
          tooltip: 'Choose open target',
          onSelected: (t) => _pick(context, path, t),
          itemBuilder: (_) => _menuItems(current),
        ),
      ],
    );
  }
}
