import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:origilink/l10n/app_localizations.dart';
import 'package:origilink/screens/global_chat_thread.dart';
import 'package:origilink/screens/login.dart';
import 'package:origilink/src/rust/api/global_chat.dart' as global_chat_api;

/// A joined channel's "profile" — the Global-mode counterpart to
/// `friend_profile.dart`, reached by tapping a channel in Home's Global
/// mode (`_GlobalProfileTab`'s joined-channels list). "Talk" opens the
/// same thread as tapping the channel row in Talk's Global mode; "Leave"
/// removes it from the joined-channels list (see `global_chat.rs`'s
/// `leave_channel`).
class GlobalChannelProfileScreen extends StatefulWidget {
  const GlobalChannelProfileScreen({super.key, required this.channel});

  final global_chat_api.GlobalChannel channel;

  @override
  State<GlobalChannelProfileScreen> createState() => _GlobalChannelProfileScreenState();
}

class _GlobalChannelProfileScreenState extends State<GlobalChannelProfileScreen> {
  Future<void> _openThread(BuildContext context) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => GlobalChatThreadScreen(channel: widget.channel)),
    );
  }

  Future<void> _leaveChannel(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.leaveChannelConfirmTitle),
        content: Text(l10n.leaveChannelConfirmBody(widget.channel.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(MaterialLocalizations.of(dialogContext).cancelButtonLabel),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            child: Text(l10n.leaveChannelButton),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final storageDir = await getApplicationDocumentsDirectory();
    await global_chat_api.leaveChannel(storageDir: storageDir.path, channelId: widget.channel.id);
    if (context.mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final channel = widget.channel;
    return Scaffold(
      backgroundColor: OrigilinkColors.background,
      appBar: AppBar(
        backgroundColor: OrigilinkColors.background,
        elevation: 0,
        foregroundColor: OrigilinkColors.textPrimary,
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        children: [
          const Center(
            child: CircleAvatar(
              radius: 48,
              backgroundColor: OrigilinkColors.surface,
              child: Icon(Icons.tag, size: 44, color: OrigilinkColors.textSecondary),
            ),
          ),
          const SizedBox(height: 16),
          Center(
            child: Text(
              channel.name.isEmpty ? l10n.untitledChannel : channel.name,
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w600,
                color: OrigilinkColors.textPrimary,
              ),
            ),
          ),
          if (channel.about.isNotEmpty) ...[
            const SizedBox(height: 4),
            Center(
              child: Text(
                channel.about,
                textAlign: TextAlign.center,
                style: const TextStyle(color: OrigilinkColors.textSecondary),
              ),
            ),
          ],
          const SizedBox(height: 28),
          ElevatedButton.icon(
            onPressed: () => _openThread(context),
            icon: const Icon(Icons.chat_bubble_outline),
            label: Text(l10n.startChat),
            style: ElevatedButton.styleFrom(
              backgroundColor: OrigilinkColors.primaryDark,
              foregroundColor: Colors.white,
              minimumSize: const Size.fromHeight(48),
            ),
          ),
          const SizedBox(height: 28),
          Container(
            decoration: BoxDecoration(
              color: OrigilinkColors.surface,
              borderRadius: BorderRadius.circular(12),
            ),
            child: ListTile(
              leading: const Icon(Icons.logout, color: Colors.redAccent),
              title: Text(l10n.leaveChannelButton, style: const TextStyle(color: Colors.redAccent)),
              onTap: () => _leaveChannel(context),
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
