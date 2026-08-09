import 'package:flutter/material.dart';
import 'package:origilink/l10n/app_localizations.dart';
import 'package:origilink/screens/login.dart';

/// Bottom navigation bar for the home screen: Profile & Friends, Talk, and
/// Timeline. Private/Global Chat are no longer separate tabs — each lives
/// as a toggle inside the Profile & Friends and Talk tabs themselves (see
/// `home.dart`).
class OrigilinkNavBar extends StatelessWidget {
  const OrigilinkNavBar({
    super.key,
    required this.selectedIndex,
    required this.onTap,
    this.talkUnreadCount = 0,
    this.pendingRequestCount = 0,
  });

  final int selectedIndex;
  final ValueChanged<int> onTap;

  /// Total unread message count across every Talk-tab conversation (friends
  /// and groups combined) — shown as a badge on the Talk icon itself, so
  /// unread messages stay visible even while looking at another tab, the
  /// same way the per-row badges in `chat_list.dart` work while already on
  /// the Talk tab.
  final int talkUnreadCount;

  /// Pending incoming friend requests — shown as a badge on the Home icon
  /// (Profile & Friends tab), so a new request stays visible from other
  /// tabs too, the same way [talkUnreadCount] does for Talk.
  final int pendingRequestCount;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Theme(
      // BottomNavigationBar always shows a Material splash/ripple on tap.
      // Suppress it so tapping only changes the icon/label color.
      data: Theme.of(context).copyWith(
        splashFactory: NoSplash.splashFactory,
        highlightColor: Colors.transparent,
        splashColor: Colors.transparent,
      ),
      child: BottomNavigationBar(
        currentIndex: selectedIndex,
        onTap: onTap,
        backgroundColor: OrigilinkColors.surface,
        selectedItemColor: OrigilinkColors.primaryDark,
        unselectedItemColor: OrigilinkColors.textSecondary,
        items: [
          _navItem(
            Icons.person_outline,
            Icons.person,
            l10n.navProfileFriends,
            0,
            badgeCount: pendingRequestCount,
          ),
          _navItem(
            Icons.chat_bubble_outline,
            Icons.chat_bubble,
            l10n.navTalk,
            1,
            badgeCount: talkUnreadCount,
          ),
          _navItem(Icons.dynamic_feed_outlined, Icons.dynamic_feed, l10n.navTimeline, 2),
        ],
      ),
    );
  }

  BottomNavigationBarItem _navItem(
    IconData outlinedIcon,
    IconData filledIcon,
    String label,
    int index, {
    int badgeCount = 0,
  }) {
    final selected = selectedIndex == index;
    final color = selected ? OrigilinkColors.primaryDark : OrigilinkColors.textSecondary;
    return BottomNavigationBarItem(
      icon: Badge(
        isLabelVisible: badgeCount > 0,
        label: Text(badgeCount > 99 ? '99+' : '$badgeCount'),
        child: Icon(selected ? filledIcon : outlinedIcon, color: color),
      ),
      label: label,
    );
  }
}
