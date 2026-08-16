import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:origilink/l10n/app_localizations.dart';
import 'package:origilink/screens/login.dart';
import 'package:origilink/src/rust/api/friends.dart' as friends_api;

/// Blocked accounts, independent of the friends list — blocking (see
/// `friend_profile.dart`'s class doc comment) hides a friend from every
/// friends-list-derived screen but keeps their `friends.json` entry, so
/// this looks up and shows their cached name/avatar where available,
/// falling back to a truncated pubkey for a block that predates the
/// friend (or outlived a since-deleted one). The UID (shown as a subtitle)
/// is always displayed regardless — it's the *account-stable* identifier
/// (unlike pubkey, which is per-relationship, see `keys::derive_uid`), so
/// it's what actually proves a re-request comes from the same blocked
/// account even under a fresh relationship key.
class BlockedAccountsScreen extends StatefulWidget {
  const BlockedAccountsScreen({super.key});

  @override
  State<BlockedAccountsScreen> createState() => _BlockedAccountsScreenState();
}

class _BlockedAccountsScreenState extends State<BlockedAccountsScreen> {
  List<friends_api.BlockedAccount> _blocked = [];
  Map<String, friends_api.Friend> _friendsByPubkey = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final storageDir = await getApplicationDocumentsDirectory();
    final results = await Future.wait([
      friends_api.listBlocked(storageDir: storageDir.path),
      friends_api.loadFriends(storageDir: storageDir.path),
    ]);
    if (!mounted) return;
    final blocked = results[0] as List<friends_api.BlockedAccount>;
    final friends = results[1] as List<friends_api.Friend>;
    setState(() {
      _blocked = blocked;
      _friendsByPubkey = {for (final f in friends) f.pubkey: f};
      _loading = false;
    });
  }

  Future<void> _unblock(String pubkey) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.unblockConfirmTitle),
        content: Text(l10n.unblockConfirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(MaterialLocalizations.of(dialogContext).cancelButtonLabel),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.unblockFriend),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final storageDir = await getApplicationDocumentsDirectory();
    await friends_api.unblockPubkey(storageDir: storageDir.path, pubkey: pubkey);
    if (!mounted) return;
    setState(() => _blocked = _blocked.where((b) => b.pubkey != pubkey).toList());
  }

  String _truncate(String value) =>
      value.length > 16 ? '${value.substring(0, 8)}…${value.substring(value.length - 8)}' : value;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      backgroundColor: OrigilinkColors.background,
      appBar: AppBar(
        backgroundColor: OrigilinkColors.background,
        elevation: 0,
        foregroundColor: OrigilinkColors.textPrimary,
        title: Text(l10n.settingsBlockedAccounts),
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _blocked.isEmpty
            ? Center(
                child: Text(
                  l10n.blockedAccountsEmpty,
                  style: const TextStyle(color: OrigilinkColors.textSecondary),
                ),
              )
            : ListView.builder(
                itemCount: _blocked.length,
                itemBuilder: (context, index) {
                  final entry = _blocked[index];
                  final friend = _friendsByPubkey[entry.pubkey];
                  final avatarPath = friend?.avatarPath;
                  final hasAvatar = avatarPath != null && File(avatarPath).existsSync();
                  final uidLabel = entry.uid.isEmpty ? null : 'UID: ${_truncate(entry.uid)}';
                  return ListTile(
                    leading: CircleAvatar(
                      backgroundColor: OrigilinkColors.surface,
                      backgroundImage: hasAvatar ? FileImage(File(avatarPath)) : null,
                      child: hasAvatar
                          ? null
                          : const Icon(Icons.block, color: OrigilinkColors.textSecondary),
                    ),
                    title: Text(
                      friend?.displayName ?? _truncate(entry.pubkey),
                      style: friend == null ? const TextStyle(fontFamily: 'monospace') : null,
                    ),
                    subtitle: uidLabel == null
                        ? null
                        : Text(
                            uidLabel,
                            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                          ),
                    trailing: TextButton(
                      onPressed: () => _unblock(entry.pubkey),
                      child: Text(l10n.unblockFriend),
                    ),
                  );
                },
              ),
      ),
    );
  }
}
