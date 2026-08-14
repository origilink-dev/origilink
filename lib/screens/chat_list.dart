import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:origilink/l10n/app_localizations.dart';
import 'package:origilink/screens/chat_thread.dart';
import 'package:origilink/screens/global_chat_thread.dart';
import 'package:origilink/screens/group_thread.dart';
import 'package:origilink/screens/login.dart';
import 'package:origilink/screens/logout.dart' show seedStorageKey;
import 'package:origilink/services/ratchet_key.dart';
import 'package:origilink/src/rust/api/chat.dart' as chat_api;
import 'package:origilink/src/rust/api/friends.dart' as friends_api;
import 'package:origilink/src/rust/api/global_chat.dart' as global_chat_api;
import 'package:origilink/src/rust/api/groups.dart' as groups_api;
import 'package:origilink/src/rust/api/ratchet.dart' as ratchet_api;
import 'package:origilink/src/rust/api/relay.dart' as relay_api;
import 'package:origilink/src/rust/api/sync.dart' as sync_api;
import 'package:origilink/widgets/relative_date.dart';

/// Talk tab body shown inside the home screen's bottom navigation: one row
/// per friend, group, and joined Global channel — merged into a single
/// list sorted by most recent activity (see [_TalkEntry]) rather than split
/// behind the Private/Global toggle, since the toggle only needs to gate
/// *posting identity* (Home tab), not *which conversations are visible*.
/// Channels are loaded internally (like a self-contained
/// `GlobalChatTalkTab` used to be) since, unlike friends/groups, nothing
/// else on Home needs to share that state.
class ChatListTab extends StatefulWidget {
  const ChatListTab({
    super.key,
    required this.friends,
    required this.groups,
    required this.messageEvents,
    required this.onToggleFavorite,
    required this.onBlockFriend,
    required this.onUnblockFriend,
    required this.onDeleteFriend,
    required this.onClearChat,
    required this.onGroupsChanged,
    required this.unreadCounts,
    required this.onUnreadCountsChanged,
  });

  final List<friends_api.Friend> friends;
  final List<groups_api.Group> groups;

  /// Live friend-protocol events (shared with [HomeScreen]'s subscription)
  /// — used to refresh previews when a new message arrives for a friend
  /// not currently open in a thread.
  final Stream<sync_api.FriendEvent>? messageEvents;

  final Future<void> Function(friends_api.Friend friend) onToggleFavorite;
  final Future<void> Function(friends_api.Friend friend) onBlockFriend;
  final Future<void> Function(friends_api.Friend friend) onUnblockFriend;
  final Future<void> Function(friends_api.Friend friend) onDeleteFriend;
  final Future<void> Function(friends_api.Friend friend) onClearChat;

  /// Called after returning from a group thread — reloads `home.dart`'s
  /// group list, so a roster change made inside the thread (e.g. leaving
  /// the group, which deletes it locally) is reflected here immediately.
  final Future<void> Function() onGroupsChanged;

  /// Per-friend unread counts, computed and owned by `home.dart` (not here)
  /// so they stay correct even while this tab isn't mounted — see that
  /// field's doc comment for why. Read directly for each row's badge.
  final Map<String, int> unreadCounts;

  /// Triggers `home.dart`'s fetch behind [unreadCounts] — call after
  /// anything here that could change read state (opening or clearing a
  /// thread) instead of computing a local copy.
  final Future<void> Function() onUnreadCountsChanged;

  @override
  State<ChatListTab> createState() => ChatListTabState();
}

class ChatListTabState extends State<ChatListTab> {
  final Map<String, chat_api.ChatMessage?> _previews = {};
  final Map<String, groups_api.GroupChatMessage?> _groupPreviews = {};
  List<global_chat_api.GlobalChannel> _channels = [];
  final Map<String, global_chat_api.GlobalChannelMessage?> _channelPreviews = {};
  StreamSubscription<sync_api.FriendEvent>? _sub;

  @override
  void initState() {
    super.initState();
    _loadPreviews();
    _loadGroupPreviews();
    reloadChannels();
    _subscribe();
  }

  void _subscribe() {
    _sub = widget.messageEvents?.listen((event) {
      if (event.kind == 'message' || event.kind == 'ratchet_message') {
        _loadPreviewFor(event.pubkey);
      } else if (event.kind == 'group_message' || event.kind == 'group_invite') {
        _loadGroupPreviewFor(event.pubkey);
      }
    });
  }

  @override
  void didUpdateWidget(covariant ChatListTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.friends != widget.friends) {
      _loadPreviews();
    }
    if (oldWidget.groups != widget.groups) {
      _loadGroupPreviews();
    }
    if (oldWidget.messageEvents != widget.messageEvents) {
      _sub?.cancel();
      _subscribe();
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _loadPreviews() async {
    for (final friend in widget.friends) {
      unawaited(_loadPreviewFor(friend.pubkey));
    }
  }

  Future<void> _loadPreviewFor(String friendPubkey) async {
    const secureStorage = FlutterSecureStorage();
    final mnemonic = await secureStorage.read(key: seedStorageKey);
    if (mnemonic == null) return;
    final storageDir = await getApplicationDocumentsDirectory();
    final history = await chat_api.loadChatHistory(
      mnemonic: mnemonic,
      storageDir: storageDir.path,
      friendPubkey: friendPubkey,
    );
    if (!mounted) return;
    // Forward-secret (ratchet) messages live outside `chat.lmdb` (see
    // `ratchet.rs`'s module doc — same reason `chat_thread.dart`'s
    // `_mergeWithRatchetHistory` merges it in), so the newest message for
    // this friend may only exist there, not in `history`.
    final ratchetKey = await getOrCreateRatchetKey();
    if (!mounted) return;
    final ratchetMessages = await ratchet_api.loadRatchetHistory(
      storageDir: storageDir.path,
      localKey: ratchetKey,
      friendPubkey: friendPubkey,
    );
    if (!mounted) return;
    chat_api.ChatMessage? latest = history.isEmpty ? null : history.last;
    if (ratchetMessages.isNotEmpty) {
      final latestRatchet = ratchetMessages.last;
      if (latest == null || latestRatchet.createdAt.toInt() > latest.createdAt.toInt()) {
        latest = chat_api.ChatMessage(
          id: latestRatchet.id,
          senderPubkey: latestRatchet.isMine ? '' : friendPubkey,
          content: latestRatchet.content,
          createdAt: latestRatchet.createdAt,
          isMine: latestRatchet.isMine,
          isEdited: false,
          isDeleted: latestRatchet.isDeleted,
          replyTo: null,
          attachment: null,
        );
      }
    }
    if (!mounted) return;
    setState(() => _previews[friendPubkey] = latest);
  }

  Future<void> _loadGroupPreviews() async {
    for (final group in widget.groups) {
      unawaited(_loadGroupPreviewFor(group.id));
    }
  }

  Future<void> _loadGroupPreviewFor(String groupId) async {
    const secureStorage = FlutterSecureStorage();
    final mnemonic = await secureStorage.read(key: seedStorageKey);
    if (mnemonic == null) return;
    final storageDir = await getApplicationDocumentsDirectory();
    final history = await groups_api.loadGroupMessages(
      mnemonic: mnemonic,
      storageDir: storageDir.path,
      groupId: groupId,
    );
    if (!mounted) return;
    setState(() => _groupPreviews[groupId] = history.isEmpty ? null : history.last);
  }

  /// Reloads joined Global channels — public so `home.dart` can trigger a
  /// refresh after joining/creating/leaving one from elsewhere (mirrors the
  /// old `GlobalChatTalkTabState.reload`).
  Future<void> reloadChannels() async {
    final storageDir = await getApplicationDocumentsDirectory();
    final channels = await global_chat_api.listJoinedChannels(storageDir: storageDir.path);
    if (!mounted) return;
    setState(() => _channels = channels);
    for (final channel in channels) {
      unawaited(_loadChannelPreviewFor(channel.id));
    }
  }

  Future<void> _loadChannelPreviewFor(String channelId) async {
    final storageDir = await getApplicationDocumentsDirectory();
    final relayList = await relay_api.loadRelayList(storageDir: storageDir.path);
    final messages = await global_chat_api.loadChannelMessages(
      relayUrls: relayList.urls,
      channelId: channelId,
      before: null,
    );
    if (!mounted) return;
    setState(() => _channelPreviews[channelId] = messages.isEmpty ? null : messages.last);
  }

  Future<void> _openChannel(global_chat_api.GlobalChannel channel) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => GlobalChatThreadScreen(channel: channel)),
    );
    _loadChannelPreviewFor(channel.id);
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
    await reloadChannels();
  }

  Future<void> _openGroupThread(groups_api.Group group) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => GroupThreadScreen(group: group, messageEvents: widget.messageEvents),
      ),
    );
    await widget.onGroupsChanged();
    _loadGroupPreviewFor(group.id);
  }

  Future<void> _openThread(friends_api.Friend friend) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChatThreadScreen(
          friend: friend,
          messageEvents: widget.messageEvents,
          onToggleFavorite: widget.onToggleFavorite,
          onBlockFriend: widget.onBlockFriend,
          onUnblockFriend: widget.onUnblockFriend,
          onDeleteFriend: widget.onDeleteFriend,
          onClearChat: widget.onClearChat,
        ),
      ),
    );
    unawaited(widget.onUnreadCountsChanged());
  }

  /// Long-press on a row: shows a small menu with "Clear chat", which then
  /// asks for confirmation before actually wiping the local history.
  Future<void> _showChatMenu(friends_api.Friend friend) async {
    final l10n = AppLocalizations.of(context)!;
    final action = await showDialog<String>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: Text(friend.displayName),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.of(dialogContext).pop('clear'),
            child: Row(
              children: [
                const Icon(Icons.delete_outline, color: Colors.redAccent),
                const SizedBox(width: 12),
                Text(l10n.clearChatButton, style: const TextStyle(color: Colors.redAccent)),
              ],
            ),
          ),
        ],
      ),
    );
    if (action != 'clear' || !mounted) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.clearChatConfirmTitle),
        content: Text(l10n.clearChatConfirmBody(friend.displayName)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(MaterialLocalizations.of(dialogContext).cancelButtonLabel),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            child: Text(l10n.clearChatButton),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await widget.onClearChat(friend);
    if (!mounted) return;
    setState(() => _previews.remove(friend.pubkey));
    unawaited(widget.onUnreadCountsChanged());
  }

  /// Builds one row per group/friend/channel and sorts them by most recent
  /// activity (no-preview entries sink to the bottom, in their original
  /// order) — this is what actually merges Private and Global content into
  /// one list instead of relying on index arithmetic across three sources.
  List<_TalkEntry> _buildEntries(AppLocalizations l10n) {
    final entries = <_TalkEntry>[];
    for (final group in widget.groups) {
      final preview = _groupPreviews[group.id];
      entries.add(
        _TalkEntry(
          previewTime: preview?.createdAt.toInt(),
          avatar: const CircleAvatar(
            radius: 28,
            backgroundColor: OrigilinkColors.surface,
            child: Icon(Icons.groups_outlined, color: OrigilinkColors.textSecondary),
          ),
          title: group.name,
          previewText: preview == null
              ? l10n.noMessagesYet
              : (preview.isMine ? '${l10n.youLabel}: ' : '${preview.senderName}: ') + preview.content,
          onTap: () => _openGroupThread(group),
        ),
      );
    }
    for (final friend in widget.friends) {
      final preview = _previews[friend.pubkey];
      final unread = widget.unreadCounts[friend.pubkey] ?? 0;
      final hasAvatar = friend.avatarPath != null && File(friend.avatarPath!).existsSync();
      entries.add(
        _TalkEntry(
          previewTime: preview?.createdAt.toInt(),
          avatar: CircleAvatar(
            radius: 28,
            backgroundColor: OrigilinkColors.surface,
            backgroundImage: hasAvatar ? FileImage(File(friend.avatarPath!)) : null,
            child: hasAvatar
                ? null
                : const Icon(Icons.person_outline, color: OrigilinkColors.textSecondary),
          ),
          title: friend.displayName,
          previewText: preview == null
              ? l10n.noMessagesYet
              : (preview.isDeleted ? l10n.messageUnsentLabel : preview.content),
          unreadCount: unread,
          onTap: () => _openThread(friend),
          onLongPress: () => _showChatMenu(friend),
        ),
      );
    }
    for (final channel in _channels) {
      final preview = _channelPreviews[channel.id];
      entries.add(
        _TalkEntry(
          previewTime: preview?.createdAt.toInt(),
          avatar: const CircleAvatar(
            radius: 28,
            backgroundColor: OrigilinkColors.surface,
            child: Icon(Icons.tag, color: OrigilinkColors.textSecondary),
          ),
          title: channel.name.isEmpty ? l10n.untitledChannel : channel.name,
          previewText: preview == null ? l10n.noChannelMessagesYet : preview.content,
          isGlobal: true,
          onTap: () => _openChannel(channel),
          onLongPress: () => _leaveChannel(channel),
        ),
      );
    }
    entries.sort((a, b) {
      if (a.previewTime == null && b.previewTime == null) return 0;
      if (a.previewTime == null) return 1;
      if (b.previewTime == null) return -1;
      return b.previewTime!.compareTo(a.previewTime!);
    });
    return entries;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final entries = _buildEntries(l10n);
    if (entries.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.chat_bubble_outline,
              size: 48,
              color: OrigilinkColors.textSecondary.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 12),
            Text(
              l10n.noChatsYet,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w500,
                color: OrigilinkColors.textSecondary,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              l10n.noChatsHint,
              style: TextStyle(
                fontSize: 13,
                color: OrigilinkColors.textSecondary.withValues(alpha: 0.7),
              ),
            ),
          ],
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: entries.length,
      separatorBuilder: (context, index) => const Divider(
        height: 1,
        indent: 82,
        color: Color(0x14000000),
      ),
      itemBuilder: (context, index) {
        final entry = entries[index];
        return InkWell(
          onTap: entry.onTap,
          onLongPress: entry.onLongPress,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              children: [
                entry.avatar,
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              entry.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                                color: OrigilinkColors.textPrimary,
                              ),
                            ),
                          ),
                          if (entry.isGlobal) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                              decoration: BoxDecoration(
                                color: OrigilinkColors.primary.withValues(alpha: 0.25),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                l10n.globalChannelBadge,
                                style: const TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600,
                                  color: OrigilinkColors.primaryDark,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        entry.previewText,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: entry.unreadCount > 0
                              ? OrigilinkColors.textPrimary
                              : OrigilinkColors.textSecondary,
                          fontWeight: entry.unreadCount > 0 ? FontWeight.w600 : FontWeight.normal,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    if (entry.previewTime != null)
                      Text(
                        _formatPreviewTime(l10n, entry.previewTime!),
                        style: TextStyle(
                          fontSize: 12,
                          color: entry.unreadCount > 0
                              ? OrigilinkColors.primaryDark
                              : OrigilinkColors.textSecondary.withValues(alpha: 0.8),
                          fontWeight: entry.unreadCount > 0 ? FontWeight.w600 : FontWeight.normal,
                        ),
                      ),
                    const SizedBox(height: 6),
                    if (entry.unreadCount > 0)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        constraints: const BoxConstraints(minWidth: 20),
                        decoration: BoxDecoration(
                          color: OrigilinkColors.primaryDark,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          entry.unreadCount >= 99 ? '99+' : '${entry.unreadCount}',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Today shows a clock time; anything older defers to [relativeDayLabel]
  /// — a bare "3/15" forces the reader to work out how long ago that
  /// actually was, which defeats the point of a preview.
  String _formatPreviewTime(AppLocalizations l10n, int epochSeconds) {
    final dt = DateTime.fromMillisecondsSinceEpoch(epochSeconds * 1000);
    final now = DateTime.now();
    final isToday = dt.year == now.year && dt.month == now.month && dt.day == now.day;
    if (isToday) {
      return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    }
    return relativeDayLabel(l10n, dt, now: now);
  }
}

/// One row's worth of display data, computed uniformly from a friend,
/// group, or Global channel so [ChatListTabState._buildEntries] can sort
/// and render all three the same way.
class _TalkEntry {
  const _TalkEntry({
    required this.previewTime,
    required this.avatar,
    required this.title,
    required this.previewText,
    required this.onTap,
    this.unreadCount = 0,
    this.isGlobal = false,
    this.onLongPress,
  });

  final int? previewTime;
  final Widget avatar;
  final String title;
  final String previewText;
  final int unreadCount;

  /// True for Global channel rows — shown with a small "Global" tag next
  /// to the title so a merged Private+Global list stays legible without
  /// the old Private/Global toggle to tell them apart implicitly.
  final bool isGlobal;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
}
