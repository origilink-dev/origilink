import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:origilink/l10n/app_localizations.dart';
import 'package:origilink/screens/chat_thread.dart';
import 'package:origilink/screens/login.dart';
import 'package:origilink/services/account_sync.dart';
import 'package:origilink/src/rust/api/chat.dart' as chat_api;
import 'package:origilink/src/rust/api/friends.dart' as friends_api;
import 'package:origilink/src/rust/api/sync.dart' as sync_api;

/// A friend's profile and the relays they publish to, with actions to
/// favorite/block them. Shared between the friends list (tapping a row)
/// and a chat thread (tapping the friend's name/avatar in the app bar), so
/// both entry points stay in sync on one implementation.
///
/// Blocking is the only way to remove a friend from the main friends list,
/// and is always reversible: a blocked friend's messages/profile updates
/// are silently dropped and they disappear from [AccountFriendsTab]'s
/// list, but the friend record itself isn't deleted — they can be found
/// and unblocked again from Settings > Blocked accounts
/// (`blocked_accounts.dart`) at any time. There used to be a separate,
/// irreversible "delete" action; it was removed in favor of this single
/// reversible one, since deleting a *blocked* friend (the only state
/// delete was offered from) left no way to undo the block itself.
///
/// Pops with `true` when the friend was blocked — callers still showing
/// that friend (e.g. an open chat thread) should pop themselves too, since
/// the friend is no longer visible from the main list. Unblocking updates
/// this screen in place instead, since nothing needs to close.
class FriendProfileScreen extends StatefulWidget {
  const FriendProfileScreen({
    super.key,
    required this.friend,
    required this.onToggleFavorite,
    required this.onBlockFriend,
    required this.onUnblockFriend,
    required this.onClearChat,
    this.messageEvents,
  });

  final friends_api.Friend friend;
  final Future<void> Function(friends_api.Friend friend) onToggleFavorite;
  final Future<void> Function(friends_api.Friend friend) onBlockFriend;
  final Future<void> Function(friends_api.Friend friend) onUnblockFriend;
  final Future<void> Function(friends_api.Friend friend) onClearChat;

  /// Live friend-protocol events, passed through to the chat thread opened
  /// by the "Talk" button — used there to append incoming messages without
  /// polling.
  final Stream<sync_api.FriendEvent>? messageEvents;

  @override
  State<FriendProfileScreen> createState() => _FriendProfileScreenState();
}

class _FriendProfileScreenState extends State<FriendProfileScreen> {
  late bool _isFavorite = widget.friend.isFavorite;
  late bool _isBlocked = widget.friend.isBlocked;

  /// Mirrors [widget.friend], refreshed on a `profile_updated` event — see
  /// `chat_thread.dart`'s identical `_friend`/`_refreshFriend` for why:
  /// [widget.friend] is a fixed snapshot from when this route was pushed,
  /// so without this a friend changing their name/avatar/relays while this
  /// screen is open wouldn't show here until it's closed and reopened.
  late friends_api.Friend _friend = widget.friend;
  StreamSubscription<sync_api.FriendEvent>? _sub;

  friends_api.Friend get friend => _friend;

  @override
  void initState() {
    super.initState();
    _sub = widget.messageEvents?.listen((event) {
      if (event.kind != 'profile_updated' || event.pubkey != widget.friend.pubkey) return;
      _refreshFriend();
    });
  }

  Future<void> _refreshFriend() async {
    final storageDir = await getApplicationDocumentsDirectory();
    final friends = await friends_api.loadFriends(storageDir: storageDir.path);
    if (!mounted) return;
    final updated = friends.where((f) => f.pubkey == widget.friend.pubkey).firstOrNull;
    if (updated != null) setState(() => _friend = updated);
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _toggleFavorite() async {
    setState(() => _isFavorite = !_isFavorite);
    await widget.onToggleFavorite(friend);
  }

  Future<bool?> _confirm(
    BuildContext context, {
    required String title,
    required String body,
    required String confirmLabel,
  }) {
    final l10n = AppLocalizations.of(context)!;
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.rejectButton),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(confirmLabel, style: const TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
  }

  Future<void> _handleStartChat(BuildContext context) async {
    final storageDir = await getApplicationDocumentsDirectory();
    await chat_api.markChatStarted(storageDir: storageDir.path, friendPubkey: friend.pubkey);
    unawaited(publishAccountChatStartedBackup());
    if (!context.mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChatThreadScreen(
          friend: friend,
          messageEvents: widget.messageEvents,
          onToggleFavorite: widget.onToggleFavorite,
          onBlockFriend: widget.onBlockFriend,
          onUnblockFriend: widget.onUnblockFriend,
          onClearChat: widget.onClearChat,
        ),
      ),
    );
  }

  Future<void> _handleBlock(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await _confirm(
      context,
      title: l10n.blockFriendConfirmTitle(friend.displayName),
      body: l10n.blockFriendConfirmBody,
      confirmLabel: l10n.blockFriend,
    );
    if (confirmed != true) return;
    setState(() => _isBlocked = true);
    await widget.onBlockFriend(friend);
    // Blocked friends no longer show in the main friends list (see the
    // class doc comment), so this profile is now a dead end — pop back
    // the same way deleting used to.
    if (context.mounted) Navigator.of(context).pop(true);
  }

  Future<void> _copyUid(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    await Clipboard.setData(ClipboardData(text: friend.uid));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.uidCopiedMessage)));
  }

  Future<void> _handleUnblock() async {
    setState(() => _isBlocked = false);
    await widget.onUnblockFriend(friend);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final hasAvatar = friend.avatarPath != null && File(friend.avatarPath!).existsSync();
    return Scaffold(
      backgroundColor: OrigilinkColors.background,
      appBar: AppBar(
        backgroundColor: OrigilinkColors.background,
        elevation: 0,
        foregroundColor: OrigilinkColors.textPrimary,
        actions: [
          IconButton(
            tooltip: _isFavorite ? l10n.removeFromFavorites : l10n.addToFavorites,
            onPressed: _toggleFavorite,
            icon: Icon(
              _isFavorite ? Icons.star : Icons.star_border,
              color: OrigilinkColors.primaryDark,
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        children: [
          Center(
            child: CircleAvatar(
              radius: 48,
              backgroundColor: OrigilinkColors.surface,
              backgroundImage: hasAvatar ? FileImage(File(friend.avatarPath!)) : null,
              child: hasAvatar
                  ? null
                  : const Icon(Icons.person_outline, size: 44, color: OrigilinkColors.textSecondary),
            ),
          ),
          const SizedBox(height: 16),
          Center(
            child: Text(
              friend.displayName,
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w600,
                color: OrigilinkColors.textPrimary,
              ),
            ),
          ),
          const SizedBox(height: 4),
          Center(
            child: Text(
              friend.statusMessage.isEmpty ? l10n.noStatusMessage : friend.statusMessage,
              textAlign: TextAlign.center,
              style: const TextStyle(color: OrigilinkColors.textSecondary),
            ),
          ),
          if (friend.uid.isNotEmpty) ...[
            const SizedBox(height: 8),
            Center(
              child: InkWell(
                onTap: () => _copyUid(context),
                child: Text(
                  '${l10n.uidLabel}: ${friend.uid.substring(0, friend.uid.length > 16 ? 16 : friend.uid.length)}...',
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    color: OrigilinkColors.textSecondary,
                  ),
                ),
              ),
            ),
          ],
          const SizedBox(height: 28),
          ElevatedButton.icon(
            onPressed: () => _handleStartChat(context),
            icon: const Icon(Icons.chat_bubble_outline),
            label: Text(l10n.startChat),
            style: ElevatedButton.styleFrom(
              backgroundColor: OrigilinkColors.primaryDark,
              foregroundColor: Colors.white,
              minimumSize: const Size.fromHeight(48),
            ),
          ),
          const SizedBox(height: 28),
          Text(
            l10n.relaySettingsTitle,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: OrigilinkColors.textSecondary,
            ),
          ),
          const SizedBox(height: 8),
          if (friend.relays.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                l10n.noRelaysYet,
                style: const TextStyle(color: OrigilinkColors.textSecondary),
              ),
            )
          else
            Container(
              decoration: BoxDecoration(
                color: OrigilinkColors.surface,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                children: [
                  for (var i = 0; i < friend.relays.length; i++) ...[
                    if (i > 0) const Divider(height: 1, color: Color(0x14000000)),
                    ListTile(
                      leading: const Icon(Icons.dns_outlined, color: OrigilinkColors.textSecondary),
                      title: Text(
                        friend.relays[i],
                        style: const TextStyle(color: OrigilinkColors.textPrimary),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          const SizedBox(height: 28),
          Container(
            decoration: BoxDecoration(
              color: OrigilinkColors.surface,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              children: _isBlocked
                  ? [
                      ListTile(
                        leading: const Icon(Icons.lock_open_outlined, color: OrigilinkColors.primaryDark),
                        title: Text(
                          l10n.unblockFriend,
                          style: const TextStyle(color: OrigilinkColors.primaryDark),
                        ),
                        onTap: _handleUnblock,
                      ),
                    ]
                  : [
                      ListTile(
                        leading: const Icon(Icons.block, color: Colors.redAccent),
                        title: Text(l10n.blockFriend, style: const TextStyle(color: Colors.redAccent)),
                        onTap: () => _handleBlock(context),
                      ),
                    ],
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
