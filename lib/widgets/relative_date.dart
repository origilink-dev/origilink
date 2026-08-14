import 'package:flutter/material.dart';
import 'package:origilink/l10n/app_localizations.dart';
import 'package:origilink/screens/login.dart';

/// "Today"/"Yesterday"/"N days ago" for anything within the last week,
/// falling back to a bare date beyond that — shared by `chat_list.dart`'s
/// preview timestamps and the date-divider chips in `chat_thread.dart`/
/// `global_chat_thread.dart`, so a raw "3/15" (which forces the reader to
/// work out how long ago that was) never appears on its own for recent
/// dates.
String relativeDayLabel(AppLocalizations l10n, DateTime dt, {DateTime? now}) {
  final n = now ?? DateTime.now();
  final today = DateTime(n.year, n.month, n.day);
  final thatDay = DateTime(dt.year, dt.month, dt.day);
  final daysAgo = today.difference(thatDay).inDays;
  if (daysAgo <= 0) return l10n.todayLabel;
  if (daysAgo == 1) return l10n.yesterdayLabel;
  if (daysAgo <= 6) return l10n.daysAgoLabel(daysAgo);
  if (dt.year == n.year) return '${dt.month}/${dt.day}';
  return '${dt.year}/${dt.month}/${dt.day}';
}

/// Small centered pill shown between messages sent on different calendar
/// days, so scrolling up through history always makes clear which day
/// you're looking at without needing every single bubble to carry a date.
class DateDividerChip extends StatelessWidget {
  const DateDividerChip({super.key, required this.date});

  final DateTime date;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: OrigilinkColors.surface,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            relativeDayLabel(l10n, date),
            style: const TextStyle(fontSize: 12, color: OrigilinkColors.textSecondary),
          ),
        ),
      ),
    );
  }
}
