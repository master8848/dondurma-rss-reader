/// Version-UX badge: one small chip per sync state, shared by subscribed
/// prompts and saved skills so both surfaces read the same.
library;

import 'package:flutter/material.dart';

import '../promptlib/version_ux.dart';

/// Small badge for an [ItemSyncState] using plain words (no jargon):
/// "Up to date", "Edited here", "Update available".
///
/// Renders nothing for [ItemSyncState.unknown] unless [showUnknown] is set —
/// lists stay quiet when a check has not run (or the device is offline),
/// while detail views can show the "Not checked yet" note explicitly.
class SyncStateChip extends StatelessWidget {
  final ItemSyncState state;
  final bool showUnknown;

  const SyncStateChip({
    super.key,
    required this.state,
    this.showUnknown = false,
  });

  @override
  Widget build(BuildContext context) {
    if (state == ItemSyncState.unknown && !showUnknown) {
      return const SizedBox.shrink();
    }
    final ColorScheme cs = Theme.of(context).colorScheme;
    final (IconData icon, Color bg, Color fg) = switch (state) {
      ItemSyncState.inSync => (
        Icons.check,
        cs.primary.withValues(alpha: 0.10),
        cs.primary,
      ),
      ItemSyncState.localNewer => (
        Icons.edit_outlined,
        Colors.amber.withValues(alpha: 0.18),
        cs.brightness == Brightness.dark
            ? Colors.amber.shade300
            : Colors.amber.shade900,
      ),
      ItemSyncState.remoteNewer => (
        Icons.arrow_downward,
        cs.tertiaryContainer,
        cs.onTertiaryContainer,
      ),
      ItemSyncState.unknown => (
        Icons.cloud_off_outlined,
        cs.onSurface.withValues(alpha: 0.08),
        cs.onSurface.withValues(alpha: 0.55),
      ),
    };
    final String tooltip = state.detail;
    return Tooltip(
      message: tooltip,
      child: Semantics(
        label: '${state.label}. $tooltip',
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 12, color: fg),
              const SizedBox(width: 4),
              Text(
                state.label,
                style: TextStyle(
                  color: fg,
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.4,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
