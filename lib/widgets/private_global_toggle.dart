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
  final Future<void> Function(bool) onChanged;

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
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: selected ? Colors.white : OrigilinkColors.textSecondary,
              ),
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 150),
              alignment: Alignment.centerLeft,
              child: badgeCount > 0
                  ? Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: Container(
                        height: 18,
                        padding: const EdgeInsets.symmetric(horizontal: 3),
                        constraints: const BoxConstraints(minWidth: 18),
                        decoration: BoxDecoration(
                          color: Colors.red,
                          borderRadius: BorderRadius.circular(9),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.only(top: 1.5),
                          child: Text(
                            badgeCount > 99 ? '99+' : '$badgeCount',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }
}
