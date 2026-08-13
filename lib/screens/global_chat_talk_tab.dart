import 'dart:async';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:origilink/l10n/app_localizations.dart';
import 'package:origilink/screens/global_chat_thread.dart';
import 'package:origilink/screens/login.dart';
import 'package:origilink/src/rust/api/global_chat.dart' as global_chat_api;
import 'package:origilink/src/rust/api/relay.dart' as relay_api;

/// Talk tab's Global-mode content: channels this account has joined (see
/// `global_chat.rs`'s `list_joined_channels`), styled identically to
/// `chat_list.dart`'s private rows (avatar, name, last-message preview,
/// timestamp) — deliberately not the browse-everything list shown by
/// `GlobalChannelSearchScreen`, so Talk only ever shows conversations this
/// account is actually part of, same as the Private side.
class GlobalChatTalkTab extends StatefulWidget {
  const GlobalChatTalkTab({super.key});

  @override
  State<GlobalChatTalkTab> createState() => GlobalChatTalkTabState();
}

class GlobalChatTalkTabState extends State<GlobalChatTalkTab> {
  List<global_chat_api.GlobalChannel> _channels = [];
  final Map<String, global_chat_api.GlobalChannelMessage?> _previews = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    reload();
  }

  Future<List<String>> _relayUrls() async {
    final storageDir = await getApplicationDocumentsDirectory();
    final relayList = await relay_api.loadRelayList(storageDir: storageDir.path);
    return relayList.urls;
  }

  Future<void> reload() async {
    setState(() => _loading = true);
    final storageDir = await getApplicationDocumentsDirectory();
    final channels = await global_chat_api.listJoinedChannels(storageDir: storageDir.path);
    if (!mounted) return;
    setState(() {
      _channels = channels;
      _loading = false;
    });
    for (final channel in channels) {
      unawaited(_loadPreviewFor(channel.id));
    }
  }

  Future<void> _loadPreviewFor(String channelId) async {
    final messages = await global_chat_api.loadChannelMessages(
      relayUrls: await _relayUrls(),
      channelId: channelId,
      before: null,
    );
    if (!mounted) return;
    setState(() => _previews[channelId] = messages.isEmpty ? null : messages.last);
  }

  Future<void> _openChannel(global_chat_api.GlobalChannel channel) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => GlobalChatThreadScreen(channel: channel)),
    );
    _loadPreviewFor(channel.id);
  }

  Future<void> _leaveChannel(global_chat_api.GlobalChannel channel) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.leaveChannelConfirmTitle),
        content: Text(l10n.leaveChannelConfirmBody(channel.name)),
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
    await global_chat_api.leaveChannel(storageDir: storageDir.path, channelId: channel.id);
    await reload();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_channels.isEmpty) {
      return RefreshIndicator(
        onRefresh: reload,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            SizedBox(
              height: 320,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.tag,
                      size: 48,
                      color: OrigilinkColors.textSecondary.withValues(alpha: 0.5),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      l10n.noJoinedChannelsYet,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                        color: OrigilinkColors.textSecondary,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: reload,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: 4),
        itemCount: _channels.length,
        separatorBuilder: (context, index) => const Divider(
          height: 1,
          indent: 82,
          color: Color(0x14000000),
        ),
        itemBuilder: (context, index) {
          final channel = _channels[index];
          final preview = _previews[channel.id];
          return InkWell(
            onTap: () => _openChannel(channel),
            onLongPress: () => _leaveChannel(channel),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  const CircleAvatar(
                    radius: 28,
                    backgroundColor: OrigilinkColors.surface,
                    child: Icon(Icons.tag, color: OrigilinkColors.textSecondary),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          channel.name.isEmpty ? l10n.untitledChannel : channel.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: OrigilinkColors.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          preview == null ? l10n.noChannelMessagesYet : preview.content,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: OrigilinkColors.textSecondary),
                        ),
                      ],
                    ),
                  ),
                  if (preview != null) ...[
                    const SizedBox(width: 8),
                    Text(
                      _formatPreviewTime(preview.createdAt.toInt()),
                      style: const TextStyle(fontSize: 12, color: OrigilinkColors.textSecondary),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  String _formatPreviewTime(int epochSeconds) {
    final dt = DateTime.fromMillisecondsSinceEpoch(epochSeconds * 1000);
    final now = DateTime.now();
    final isToday = dt.year == now.year && dt.month == now.month && dt.day == now.day;
    if (isToday) {
      return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    }
    return '${dt.month}/${dt.day}';
  }
}
