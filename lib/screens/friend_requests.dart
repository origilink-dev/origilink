import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:origilink/l10n/app_localizations.dart';
import 'package:origilink/screens/login.dart';
import 'package:origilink/screens/logout.dart' show seedStorageKey;
import 'package:origilink/services/account_sync.dart' show friendEventsRefreshSignal;
import 'package:origilink/services/ratchet_key.dart';
import 'package:origilink/src/rust/api/relay.dart' as relay_api;
import 'package:origilink/src/rust/api/sync.dart' as sync_api;

/// Shows pending incoming friend requests (sent to any of our still-active
/// invites) and lets the user accept or reject each one.
class FriendRequestsScreen extends StatefulWidget {
  const FriendRequestsScreen({super.key, this.messageEvents});

  /// Live friend-protocol events (shared with `home.dart`'s subscription)
  /// — a request arriving while this screen is already open otherwise
  /// wouldn't show up until it's closed and reopened.
  final Stream<sync_api.FriendEvent>? messageEvents;

  @override
  State<FriendRequestsScreen> createState() => _FriendRequestsScreenState();
}

class _FriendRequestsScreenState extends State<FriendRequestsScreen> {
  List<sync_api.PendingFriendRequest> _requests = [];
  bool _loading = true;
  final _busy = <String>{};
  StreamSubscription<sync_api.FriendEvent>? _sub;

  @override
  void initState() {
    super.initState();
    _load();
    _sub = widget.messageEvents?.listen((event) {
      if (event.kind == 'request') _load();
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final storageDir = await getApplicationDocumentsDirectory();
    final requests = await sync_api.loadPendingFriendRequests(storageDir: storageDir.path);
    if (!mounted) return;
    setState(() {
      _requests = requests;
      _loading = false;
    });
  }

  Future<void> _accept(sync_api.PendingFriendRequest request) async {
    setState(() => _busy.add(request.pubkey));
    const secureStorage = FlutterSecureStorage();
    final mnemonic = await secureStorage.read(key: seedStorageKey);
    final storageDir = await getApplicationDocumentsDirectory();
    if (mnemonic != null) {
      final alreadyFriend = await sync_api.acceptFriendRequest(
        mnemonic: mnemonic,
        storageDir: storageDir.path,
        inviteAccountIndex: request.inviteAccountIndex,
        requesterPubkey: request.pubkey,
        requesterUid: request.uid,
        requesterDisplayName: request.displayName,
        requesterStatusMessage: request.statusMessage,
        requesterRelays: request.relays,
        requesterAvatarBase64: request.avatarBase64,
      );
      if (alreadyFriend && mounted) {
        final l10n = AppLocalizations.of(context)!;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l10n.friendAlreadyAddedMessage)));
      }
      unawaited(announceRatchetDeviceTo(request.pubkey));
      // Accepting adds this pubkey to friends.json, but the live
      // subscription's watch list (home.dart's `_subscribeFriendEvents`)
      // was built before this friend existed — without this, our own
      // acceptance never rebuilds it (that only happens on the *other*
      // side, when its 'accepted' event arrives), so this device would
      // silently fail to receive anything from the new friend until the
      // next unrelated resubscribe.
      friendEventsRefreshSignal.value++;
    }
    if (!mounted) return;
    setState(() {
      _requests = _requests.where((r) => r.pubkey != request.pubkey).toList();
      _busy.remove(request.pubkey);
    });
  }

  Future<void> _reject(sync_api.PendingFriendRequest request) async {
    setState(() => _busy.add(request.pubkey));
    const secureStorage = FlutterSecureStorage();
    final mnemonic = await secureStorage.read(key: seedStorageKey);
    final storageDir = await getApplicationDocumentsDirectory();
    if (mnemonic != null) {
      final relayList = await relay_api.loadRelayList(storageDir: storageDir.path);
      await sync_api.rejectFriendRequest(
        mnemonic: mnemonic,
        storageDir: storageDir.path,
        relayUrls: relayList.urls,
        requesterPubkey: request.pubkey,
      );
    }
    if (!mounted) return;
    setState(() {
      _requests = _requests.where((r) => r.pubkey != request.pubkey).toList();
      _busy.remove(request.pubkey);
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      backgroundColor: OrigilinkColors.background,
      appBar: AppBar(
        backgroundColor: OrigilinkColors.background,
        elevation: 0,
        foregroundColor: OrigilinkColors.textPrimary,
        title: Text(l10n.friendRequestsTitle),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: _requests.isEmpty
                  ? ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: [
                        SizedBox(
                          height: 320,
                          child: Center(
                            child: Text(
                              l10n.noFriendRequests,
                              style: const TextStyle(
                                color: OrigilinkColors.textSecondary,
                              ),
                            ),
                          ),
                        ),
                      ],
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.all(16),
                      itemCount: _requests.length,
                      itemBuilder: (context, index) {
                        final request = _requests[index];
                        final busy = _busy.contains(request.pubkey);
                        return Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: OrigilinkColors.surface,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                request.displayName,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 16,
                                ),
                              ),
                              if (request.statusMessage.isNotEmpty) ...[
                                const SizedBox(height: 2),
                                Text(
                                  request.statusMessage,
                                  style: const TextStyle(
                                    color: OrigilinkColors.textSecondary,
                                    fontSize: 13,
                                  ),
                                ),
                              ],
                              const SizedBox(height: 12),
                              Row(
                                children: [
                                  Expanded(
                                    child: OutlinedButton(
                                      onPressed: busy
                                          ? null
                                          : () => _reject(request),
                                      style: OutlinedButton.styleFrom(
                                        foregroundColor: Colors.red,
                                      ),
                                      child: Text(l10n.rejectButton),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: ElevatedButton(
                                      onPressed: busy
                                          ? null
                                          : () => _accept(request),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor:
                                            OrigilinkColors.primaryDark,
                                        foregroundColor: Colors.white,
                                      ),
                                      child: Text(l10n.acceptButton),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
    );
  }
}
