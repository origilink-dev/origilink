import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:origilink/screens/logout.dart' show seedStorageKey;
import 'package:origilink/src/rust/api/account.dart' as account_api;
import 'package:origilink/src/rust/api/relay.dart' as relay_api;
import 'package:origilink/src/rust/api/sync.dart' as sync_api;

/// Bumped whenever the set of invites/outgoing requests a device should be
/// watching for may have changed (e.g. a fresh "My QR" invite created) —
/// `HomeScreen` listens and resubscribes its live friend-events connection.
/// Without this, a freshly generated invite is invisible to the live
/// subscription (which only reflects the watch list as of its last
/// (re)subscribe) until some unrelated event happens to trigger one, so a
/// friend request against it can arrive on the relay but never surface in
/// the UI until the next resubscribe.
final ValueNotifier<int> friendEventsRefreshSignal = ValueNotifier<int>(0);

/// Publishes the given account to the relay-hosted encrypted backup, if a
/// seed phrase has been generated yet. Silently does nothing (no seed) or
/// fails silently (relays unreachable) — publishing is best-effort and
/// shouldn't block or fail the caller's own flow.
Future<void> publishAccountBackup(account_api.Account profile) async {
  const secureStorage = FlutterSecureStorage();
  final mnemonic = await secureStorage.read(key: seedStorageKey);
  if (mnemonic == null) return;

  final storageDir = await getApplicationDocumentsDirectory();
  final relayList = await relay_api.loadRelayList(storageDir: storageDir.path);
  try {
    await sync_api.publishAccountBackup(
      mnemonic: mnemonic,
      relayUrls: relayList.urls,
      displayName: profile.displayName,
      statusMessage: profile.statusMessage,
      updatedAt: profile.updatedAt,
    );
  } catch (_) {
    // Offline or every relay unreachable — the next publish attempt
    // (next edit, or next app startup) will retry.
  }
}

/// Reconciles the local account with its relay-hosted backup: whichever
/// side has the newer `updatedAt` wins. If the relay copy is newer, the
/// local `account.json` is overwritten and the updated [account_api.Account]
/// is returned; otherwise (local is newer, or there's no backup yet) the
/// local copy is pushed to relays and `localProfile` is returned unchanged.
///
/// Returns `localProfile` unchanged if there's no seed yet or relays are
/// unreachable — sync is best-effort, never blocks being able to use the app.
Future<account_api.Account> reconcileAccountBackup(
  account_api.Account localProfile,
) async {
  const secureStorage = FlutterSecureStorage();
  final mnemonic = await secureStorage.read(key: seedStorageKey);
  if (mnemonic == null) return localProfile;

  final storageDir = await getApplicationDocumentsDirectory();
  final relayList = await relay_api.loadRelayList(storageDir: storageDir.path);

  try {
    final remote = await sync_api.fetchAccountBackup(mnemonic: mnemonic, relayUrls: relayList.urls);
    if (remote != null && remote.updatedAt > localProfile.updatedAt) {
      await account_api.saveAccountWithTimestamp(
        storageDir: storageDir.path,
        displayName: remote.displayName,
        statusMessage: remote.statusMessage,
        avatarPath: localProfile.avatarPath,
        updatedAt: remote.updatedAt,
      );
      return account_api.Account(
        displayName: remote.displayName,
        statusMessage: remote.statusMessage,
        avatarPath: localProfile.avatarPath,
        updatedAt: remote.updatedAt,
      );
    }
    if (remote == null || localProfile.updatedAt > remote.updatedAt) {
      await sync_api.publishAccountBackup(
        mnemonic: mnemonic,
        relayUrls: relayList.urls,
        displayName: localProfile.displayName,
        statusMessage: localProfile.statusMessage,
        updatedAt: localProfile.updatedAt,
      );
    }
  } catch (_) {
    // Offline or every relay unreachable — proceed with the local copy.
  }
  return localProfile;
}

/// Publishes the given profile info to every existing friend, so their
/// copy of our display name/status stays in sync. Best-effort: silently
/// does nothing (no seed) or fails silently (relays unreachable).
///
/// Pass `avatarChanged: false` (the default) when only the text fields
/// changed, so the (much larger) avatar payload isn't re-sent on every
/// edit — the friend's cached avatar is left as-is.
Future<void> publishProfileUpdateToFriends(
  account_api.Account profile, {
  bool avatarChanged = false,
}) async {
  const secureStorage = FlutterSecureStorage();
  final mnemonic = await secureStorage.read(key: seedStorageKey);
  if (mnemonic == null) return;

  final storageDir = await getApplicationDocumentsDirectory();
  try {
    await sync_api.publishProfileUpdateToFriends(
      mnemonic: mnemonic,
      storageDir: storageDir.path,
      displayName: profile.displayName,
      statusMessage: profile.statusMessage,
      avatarLink: avatarChanged ? profile.avatarLink : null,
    );
  } catch (_) {
    // Offline or every relay unreachable — friends just won't see the
    // update until we successfully publish again.
  }
}

/// Counts pending incoming friend requests, for showing a badge on the
/// "Add friend" entry point. Reads the local cache the live subscription
/// keeps up to date — no relay round-trip needed.
Future<int> pendingFriendRequestCount() async {
  final storageDir = await getApplicationDocumentsDirectory();
  final requests = await sync_api.loadPendingFriendRequests(storageDir: storageDir.path);
  return requests.length;
}

/// Publishes the account avatar to its own relay-hosted backup slot —
/// call only when the avatar actually changed, so other devices don't
/// re-download it on every unrelated profile edit. Silently does nothing
/// (no seed, no avatar, or relays unreachable).
Future<void> publishAccountAvatarBackup(account_api.Account profile) async {
  final avatarLink = profile.avatarLink;
  if (avatarLink == null) return;
  const secureStorage = FlutterSecureStorage();
  final mnemonic = await secureStorage.read(key: seedStorageKey);
  if (mnemonic == null) return;

  final storageDir = await getApplicationDocumentsDirectory();
  final relayList = await relay_api.loadRelayList(storageDir: storageDir.path);
  try {
    await sync_api.publishAccountAvatarBackup(
      mnemonic: mnemonic,
      relayUrls: relayList.urls,
      avatarLink: avatarLink,
      updatedAt: profile.updatedAt,
    );
  } catch (_) {
    // Offline or every relay unreachable — retried on the next avatar edit.
  }
}

/// Publishes the account's current relay list to its own backup slot, so
/// restoring on another device can pick it up instead of requiring it to
/// be re-entered by hand. Silently does nothing (no seed, or relays
/// unreachable).
///
/// Sent to the union of [relays] and [previousRelays] (the list this device
/// was using right before this change), not just the new list: another
/// device that hasn't heard about the change yet is still watching the old
/// relays, and if the new list shares none of them, it would otherwise have
/// no way to ever discover where the account moved to.
Future<void> publishAccountRelaysBackup(
  List<String> relays, {
  List<String> previousRelays = const [],
}) async {
  const secureStorage = FlutterSecureStorage();
  final mnemonic = await secureStorage.read(key: seedStorageKey);
  if (mnemonic == null) return;

  final destinations = {...relays, ...previousRelays}.toList();
  try {
    await sync_api.publishAccountRelaysBackup(
      mnemonic: mnemonic,
      relayUrls: destinations,
      relays: relays,
      updatedAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    );
  } catch (_) {
    // Offline or every relay unreachable — retried on the next relay edit.
  }
}

/// Publishes the local friends list (pubkey/account-index/display info,
/// no avatars) to its own backup slot — call after any change to the
/// friends list, so another device can reconstruct the same
/// per-relationship keys and pick up existing conversations too.
Future<void> publishAccountFriendsBackup() async {
  const secureStorage = FlutterSecureStorage();
  final mnemonic = await secureStorage.read(key: seedStorageKey);
  if (mnemonic == null) return;

  final storageDir = await getApplicationDocumentsDirectory();
  final relayList = await relay_api.loadRelayList(storageDir: storageDir.path);
  try {
    await sync_api.publishAccountFriendsBackup(
      mnemonic: mnemonic,
      storageDir: storageDir.path,
      relayUrls: relayList.urls,
      updatedAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    );
  } catch (_) {
    // Offline or every relay unreachable — retried on the next friend change.
  }
}

/// Publishes the blocked-pubkey list to its own backup slot — call after
/// blocking or unblocking a friend, so it takes effect on every device
/// signed into this account.
Future<void> publishAccountBlockedBackup() async {
  const secureStorage = FlutterSecureStorage();
  final mnemonic = await secureStorage.read(key: seedStorageKey);
  if (mnemonic == null) return;

  final storageDir = await getApplicationDocumentsDirectory();
  final relayList = await relay_api.loadRelayList(storageDir: storageDir.path);
  try {
    await sync_api.publishAccountBlockedBackup(
      mnemonic: mnemonic,
      storageDir: storageDir.path,
      relayUrls: relayList.urls,
      updatedAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    );
  } catch (_) {
    // Offline or every relay unreachable — retried on the next block change.
  }
}

/// Publishes the invite list (and shared account-index counter) to its
/// own backup slot — call after creating or revoking an invite, so a QR
/// code shown from any device is recognized (and use-count/revocation
/// tracked) from every device.
Future<void> publishAccountInvitesBackup() async {
  const secureStorage = FlutterSecureStorage();
  final mnemonic = await secureStorage.read(key: seedStorageKey);
  if (mnemonic == null) return;

  final storageDir = await getApplicationDocumentsDirectory();
  final relayList = await relay_api.loadRelayList(storageDir: storageDir.path);
  try {
    await sync_api.publishAccountInvitesBackup(
      mnemonic: mnemonic,
      storageDir: storageDir.path,
      relayUrls: relayList.urls,
      updatedAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    );
  } catch (_) {
    // Offline or every relay unreachable — retried on the next invite change.
  }
}

/// Publishes the chat read-state map to its own backup slot — call after
/// marking a thread read, so unread counts stay consistent across devices.
Future<void> publishAccountReadStateBackup() async {
  const secureStorage = FlutterSecureStorage();
  final mnemonic = await secureStorage.read(key: seedStorageKey);
  if (mnemonic == null) return;

  final storageDir = await getApplicationDocumentsDirectory();
  final relayList = await relay_api.loadRelayList(storageDir: storageDir.path);
  try {
    await sync_api.publishAccountReadstateBackup(
      mnemonic: mnemonic,
      storageDir: storageDir.path,
      relayUrls: relayList.urls,
      updatedAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    );
  } catch (_) {
    // Offline or every relay unreachable — retried on the next thread read.
  }
}

/// Publishes personal app preferences (currently just language) to their
/// own backup slot — call after changing them, so the choice follows this
/// account to every device instead of resetting on each one. Never sent
/// to friends, unlike relays.json.
Future<void> publishAccountConfigBackup() async {
  const secureStorage = FlutterSecureStorage();
  final mnemonic = await secureStorage.read(key: seedStorageKey);
  if (mnemonic == null) return;

  final storageDir = await getApplicationDocumentsDirectory();
  final relayList = await relay_api.loadRelayList(storageDir: storageDir.path);
  try {
    await sync_api.publishAccountConfigBackup(
      mnemonic: mnemonic,
      storageDir: storageDir.path,
      relayUrls: relayList.urls,
      updatedAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    );
  } catch (_) {
    // Offline or every relay unreachable — retried on the next config change.
  }
}

/// Publishes the set of friends whose chat thread has been explicitly
/// started to its own backup slot — call after [chat_api.markChatStarted],
/// so a thread started on one device shows up in the Talk tab on every
/// device signed into this account.
Future<void> publishAccountChatStartedBackup() async {
  const secureStorage = FlutterSecureStorage();
  final mnemonic = await secureStorage.read(key: seedStorageKey);
  if (mnemonic == null) return;

  final storageDir = await getApplicationDocumentsDirectory();
  final relayList = await relay_api.loadRelayList(storageDir: storageDir.path);
  try {
    await sync_api.publishAccountChatstartedBackup(
      mnemonic: mnemonic,
      storageDir: storageDir.path,
      relayUrls: relayList.urls,
      updatedAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    );
  } catch (_) {
    // Offline or every relay unreachable — retried on the next chat start.
  }
}

