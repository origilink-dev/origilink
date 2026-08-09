import 'package:flutter/material.dart';
import 'package:origilink/l10n/app_localizations.dart';
import 'package:origilink/screens/login.dart';

/// Rounded-pill segmented control switching between Private (friends/
/// groups — encrypted, invite-only) and Global (NIP-28 channels — open to
/// anyone on the configured relays) content, shown identically in both the
/// Home and Talk tabs' top bars. Kept as one shared widget (rather than
/// duplicated inline) so the two tabs can never drift in appearance.
class PrivateGlobalToggle extends StatelessWidget {
  const PrivateGlobalToggle({
    super.key,
    required this.isGlobal,
    required this.onChanged,
    this.privateBadgeCount = 0,
    this.globalBadgeCount = 0,
  });

  final bool isGlobal;
  final ValueChanged<bool> onChanged;

  /// Pending-notification counts shown as a small red badge on each side —
  /// e.g. unread messages/friend requests on Private, new channel activity
  /// on Global — since there's no longer a separate bottom-nav icon for
  /// either to carry that badge on its own.
  final int privateBadgeCount;
  final int globalBadgeCount;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: OrigilinkColors.surface,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _segment(l10n.privateModeLabel, selected: !isGlobal, badgeCount: privateBadgeCount, onTap: () => onChanged(false)),
          _segment(l10n.globalModeLabel, selected: isGlobal, badgeCount: globalBadgeCount, onTap: () => onChanged(true)),
        ],
      ),
    );
  }

  Widget _segment(
    String label, {
    required bool selected,
    required int badgeCount,
    required VoidCallback onTap,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? OrigilinkColors.textPrimary : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Badge(
          isLabelVisible: badgeCount > 0,
          label: Text(badgeCount > 99 ? '99+' : '$badgeCount'),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: selected ? Colors.white : OrigilinkColors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}
