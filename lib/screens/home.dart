import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:origilink/l10n/app_localizations.dart';
import 'package:origilink/nav_bar.dart';
import 'package:origilink/screens/add_friend.dart';
import 'package:origilink/screens/chat_list.dart';
import 'package:origilink/screens/chat_thread.dart';
import 'package:origilink/screens/create_group.dart';
import 'package:origilink/screens/create_talk_room.dart';
import 'package:origilink/screens/edit_profile.dart';
import 'package:origilink/screens/group_thread.dart';
import 'package:origilink/screens/login.dart';
import 'package:origilink/screens/logout.dart' show seedStorageKey;
import 'package:origilink/screens/account_friends.dart';
import 'package:origilink/screens/global_channel_profile.dart';
import 'package:origilink/screens/global_chat_list.dart';
import 'package:origilink/screens/global_profile_setup.dart';
import 'package:origilink/screens/settings.dart';
import 'package:origilink/services/account_sync.dart';
import 'package:origilink/services/ratchet_key.dart';
import 'package:origilink/src/rust/api/account.dart' as account_api;
import 'package:origilink/src/rust/api/chat.dart' as chat_api;
import 'package:origilink/src/rust/api/config.dart' as config_api;
import 'package:origilink/src/rust/api/friends.dart' as friends_api;
import 'package:origilink/src/rust/api/global_chat.dart' as global_chat_api;
import 'package:origilink/src/rust/api/groups.dart' as groups_api;
import 'package:origilink/src/rust/api/keys.dart' as keys_api;
import 'package:origilink/src/rust/api/sync.dart' as sync_api;
import 'package:origilink/widgets/private_global_toggle.dart';

/// Home screen shown after profile setup. Hosts three sections behind a
/// bottom navigation bar: Profile & Friends, Talk, and Timeline (a
/// placeholder for a future feature). The [PrivateGlobalToggle] in the top
/// bar only applies to Profile & Friends — it picks which *posting
/// identity* (private account vs. Global Chat identity) you're managing,
/// since those two profiles/friend-lists genuinely can't share a screen.
/// Talk is deliberately NOT behind the toggle: friends, groups, and joined
/// Global channels are private/public in the *protocol* sense (still
/// unlinkable identities, see `keys.rs`), but there's no reason a user
/// should have to remember which mode they're in just to find a
/// conversation, so `chat_list.dart` merges all three into one list.
class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.profile,
    required this.onSelectLanguage,
    required this.onLogout,
    required this.onLocaleSynced,
  });

  final account_api.Account profile;
  final ValueChanged<Locale> onSelectLanguage;
  final VoidCallback onLogout;

  /// Called when a config backup with a different language arrives from
  /// another device — updates the displayed locale immediately, without
  /// re-persisting or re-publishing (that already happened on the device
  /// that made the change; this is purely a display refresh).
  final ValueChanged<Locale> onLocaleSynced;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  int _selectedIndex = 1;
  final _globalProfileTabKey = GlobalKey<_GlobalProfileTabState>();
  late account_api.Account _profile = widget.profile;

  /// Shared between the Home and Talk tabs (index 0 and 1) — switching to
  /// Global in one carries over to the other, since it's one mental mode
  /// ("which world am I looking at") rather than a per-tab setting.
  bool _globalMode = false;
  String? _globalPubkey;
  String? _uid;

  List<friends_api.Friend> _friends = [];
  List<groups_api.Group> _groups = [];

  /// Joined Global channels, lifted up here (rather than owned by
  /// [ChatListTab] itself) for the same reason [_friends]/[_groups] are:
  /// `IndexedStack` keeps every tab mounted simultaneously, so a `setState`
  /// here rebuilds [ChatListTab] with fresh `channels` regardless of which
  /// tab is currently selected — the same "just works, no tab-switch or
  /// explicit poke required" behavior 1:1/group updates already get. A
  /// channel can now be joined from *either* Home's or Talk's "+" menu (see
  /// `_searchGlobalChannel`/`_createGlobalChannel`), so Talk's list needs
  /// to reflect that instantly no matter which tab the join happened from
  /// or which tab is showing afterward.
  List<global_chat_api.GlobalChannel> _channels = [];
  Set<String> _activeChatPubkeys = {};
  int _pendingRequestCount = 0;

  /// Per-friend unread counts for the Talk tab — the single source of
  /// truth, computed here (not in [ChatListTab]) so it stays correct even
  /// while Talk isn't the visible tab (`BottomNavigationBar` doesn't mount
  /// the tabs it isn't showing, so anything computed inside `ChatListTab`
  /// itself would silently stop updating whenever another tab is active).
  /// [ChatListTab] reads this directly for its per-row badges instead of
  /// fetching its own copy.
  Map<String, int> _unreadCounts = {};
  int get _talkUnreadTotal => _unreadCounts.values.fold(0, (a, b) => a + b);

  StreamSubscription<sync_api.FriendEvent>? _friendEventsSub;

  /// A stable broadcast stream that outlives individual relay
  /// (re)subscriptions — [_subscribeFriendEvents] tears down and rebuilds
  /// the underlying raw subscription often (new invite, accepted friend,
  /// app resume, ...), but this controller and the `Stream` object its
  /// `.stream` getter returns never change identity. Screens pushed via
  /// `Navigator` (e.g. `AddFriendScreen`) capture this stream once as a
  /// constructor parameter and are never rebuilt afterwards, so if the
  /// exposed stream were swapped for a new object on every resubscribe (as
  /// it used to be), any such screen still open at resubscribe time would
  /// silently stop receiving events — e.g. sitting on "Add friend" while
  /// generating a fresh QR (which itself triggers a resubscribe) used to
  /// mean incoming requests stopped updating the badge until the screen
  /// was closed and reopened.
  final _friendEventsController = StreamController<sync_api.FriendEvent>.broadcast();
  Stream<sync_api.FriendEvent> get _friendEventsStream => _friendEventsController.stream;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadFriends();
    _loadGroups();
    _loadChannels();
    _loadActiveChatPubkeys();
    _refreshPendingRequestCount();
    _subscribeFriendEvents();
    friendEventsRefreshSignal.addListener(_subscribeFriendEvents);
    _loadGlobalPubkey();
    _loadUid();
  }

  Future<void> _loadGlobalPubkey() async {
    const secureStorage = FlutterSecureStorage();
    final mnemonic = await secureStorage.read(key: seedStorageKey);
    if (mnemonic == null) return;
    final pubkey = await global_chat_api.globalChatIdentityPubkey(mnemonic: mnemonic);
    if (!mounted) return;
    setState(() => _globalPubkey = pubkey);
  }

  Future<void> _loadUid() async {
    const secureStorage = FlutterSecureStorage();
    final mnemonic = await secureStorage.read(key: seedStorageKey);
    if (mnemonic == null) return;
    final uid = await keys_api.getAccountUid(mnemonic: mnemonic);
    if (!mounted) return;
    setState(() => _uid = uid);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    friendEventsRefreshSignal.removeListener(_subscribeFriendEvents);
    _friendEventsSub?.cancel();
    _friendEventsController.close();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The OS suspends the relay connection while backgrounded, so pick it
    // back up (and catch anything missed) when the app is foregrounded again.
    if (state == AppLifecycleState.resumed) {
      _refreshPendingRequestCount();
      _refreshFriends();
      _loadActiveChatPubkeys();
      _subscribeFriendEvents();
    }
  }

  /// Opens a live connection to this account's relays so incoming friend
  /// requests and acceptances show up immediately, without polling.
  /// Cancels and reopens any existing subscription — call again after the
  /// set of invites/outgoing requests may have changed.
  Future<void> _subscribeFriendEvents() async {
    await _friendEventsSub?.cancel();
    const secureStorage = FlutterSecureStorage();
    final mnemonic = await secureStorage.read(key: seedStorageKey);
    if (mnemonic == null || !mounted) return;
    final storageDir = await getApplicationDocumentsDirectory();
    final ratchetKey = await getOrCreateRatchetKey();
    if (!mounted) return;
    final stream = sync_api
        .subscribeFriendEvents(
          mnemonic: mnemonic,
          storageDir: storageDir.path,
          ratchetKey: ratchetKey,
        )
        .asBroadcastStream();
    _friendEventsSub = stream.listen((event) {
      _friendEventsController.add(event);
      if (event.kind == 'accepted' || event.kind == 'already_friend') {
        _loadFriends();
        unawaited(publishAccountFriendsBackup());
        unawaited(announceRatchetDeviceTo(event.pubkey));
        // The live subscription's watch list was built from the friends
        // list as it stood when this subscription started — a friend
        // gained just now via acceptance isn't in it yet, so their gift
        // wraps would silently fail to match until we rebuild it.
        _subscribeFriendEvents();
        if (event.kind == 'already_friend' && mounted) {
          final l10n = AppLocalizations.of(context)!;
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(l10n.friendAlreadyAddedMessage)));
        }
      } else if (event.kind == 'profile_updated') {
        _loadFriends();
      } else if (event.kind == 'request') {
        _refreshPendingRequestCount();
      } else if (event.kind == 'message' || event.kind == 'ratchet_message') {
        // A friend messaging us first means their thread should show up in
        // the Talk tab even though nobody tapped "Talk" yet — the Rust side
        // has already durably marked the thread started before emitting
        // this event, so this re-query reliably includes them.
        _loadActiveChatPubkeys();
      } else if (event.kind == 'group_invite') {
        // A new group, or an updated member list for one we already know —
        // either way, reload so it shows up (or its member count updates).
        _loadGroups();
        // Receiving/merging a roster is exactly when this device's own
        // per-group routing identity (`group_ratchet.rs`) can get minted
        // for the first time, or when a self-announce round-trip
        // completes — either way the live subscription's watch list
        // (built once, at `_subscribeFriendEvents` call time) is now
        // stale: it doesn't include that pubkey yet, so this device would
        // never actually receive anything addressed to it until the next
        // resubscribe. Rebuild now so that pubkey starts being watched
        // immediately instead of only after the app happens to restart.
        _subscribeFriendEvents();
      } else if (event.kind == 'account_synced') {
        // Another device published a newer text/avatar/relays/friends/
        // config/chat-started backup and this device applied it locally —
        // refresh everything shown from that local state.
        _reloadProfile();
        _loadFriends();
        _loadActiveChatPubkeys();
        _applySyncedLocale();
      }
    });
  }

  Future<void> _loadActiveChatPubkeys() async {
    const secureStorage = FlutterSecureStorage();
    final mnemonic = await secureStorage.read(key: seedStorageKey);
    if (mnemonic == null) return;
    final storageDir = await getApplicationDocumentsDirectory();
    final pubkeys = await chat_api.listActiveChatPubkeys(
      mnemonic: mnemonic,
      storageDir: storageDir.path,
    );
    if (!mounted) return;
    setState(() => _activeChatPubkeys = pubkeys.toSet());
    unawaited(_refreshUnreadCounts());
  }

  Future<void> _refreshPendingRequestCount() async {
    final count = await pendingFriendRequestCount();
    if (!mounted) return;
    setState(() => _pendingRequestCount = count);
  }

  /// The single fetch behind [_unreadCounts]/[_talkUnreadTotal] — kept here
  /// rather than in [ChatListTab] so it stays correct even while Talk isn't
  /// the visible tab (see [_unreadCounts]'s doc comment). Passed down to
  /// [ChatListTab] as `onUnreadCountsChanged` so it can trigger a refresh
  /// after the same events that used to make it re-fetch on its own
  /// (opening/reading a thread, clearing one) without duplicating the fetch
  /// itself.
  Future<void> _refreshUnreadCounts() async {
    if (_activeChatPubkeys.isEmpty) {
      if (mounted) setState(() => _unreadCounts = {});
      return;
    }
    const secureStorage = FlutterSecureStorage();
    final mnemonic = await secureStorage.read(key: seedStorageKey);
    if (mnemonic == null) return;
    final storageDir = await getApplicationDocumentsDirectory();
    final ratchetKey = await getOrCreateRatchetKey();
    if (!mounted) return;
    final counts = await chat_api.loadUnreadCounts(
      mnemonic: mnemonic,
      storageDir: storageDir.path,
      friendPubkeys: _activeChatPubkeys.toList(),
      ratchetLocalKey: ratchetKey,
    );
    if (!mounted) return;
    setState(() {
      _unreadCounts = {for (final c in counts) c.friendPubkey: c.count.toInt()};
    });
  }

  Future<void> _reloadProfile() async {
    final storageDir = await getApplicationDocumentsDirectory();
    final profile = await account_api.loadAccount(storageDir: storageDir.path);
    if (!mounted || profile == null) return;
    setState(() => _profile = profile);
  }

  Future<void> _applySyncedLocale() async {
    final storageDir = await getApplicationDocumentsDirectory();
    final config = await config_api.loadConfig(storageDir: storageDir.path);
    final language = config.language;
    if (language == null || !mounted) return;
    widget.onLocaleSynced(Locale(language));
  }

  Future<void> _loadFriends() async {
    final storageDir = await getApplicationDocumentsDirectory();
    final friends = await friends_api.loadFriends(storageDir: storageDir.path);
    if (!mounted) return;
    // Catches friends that appeared without a live 'accepted' FriendEvent
    // ever reaching this listener (e.g. the requester side's subscription
    // missing the accept event, or friends.json being populated via the
    // account-backup self-sync echo instead) — every call site of
    // `_loadFriends` (initState, resume, any FriendEvent) ends up here, so
    // the ratchet announce self-heals on the next successful load instead
    // of depending on that one transient stream event.
    final oldPubkeys = _friends.map((f) => f.pubkey).toSet();
    final newFriends = friends.where((f) => !oldPubkeys.contains(f.pubkey));
    for (final friend in newFriends) {
      unawaited(announceRatchetDeviceTo(friend.pubkey));
    }
    setState(() => _friends = friends);
  }

  Future<void> _loadGroups() async {
    final storageDir = await getApplicationDocumentsDirectory();
    final groups = await groups_api.loadGroups(storageDir: storageDir.path);
    if (!mounted) return;
    setState(() => _groups = groups);
  }

  Future<void> _loadChannels() async {
    final storageDir = await getApplicationDocumentsDirectory();
    final channels = await global_chat_api.listJoinedChannels(storageDir: storageDir.path);
    if (!mounted) return;
    setState(() => _channels = channels);
  }

  /// "Create group" from the Talk tab's "+" menu: pick a name and members
  /// (from friends), then open the newly-created group's thread.
  Future<void> _createGroup(BuildContext context) async {
    final result = await Navigator.of(context).push<(String, List<String>)>(
      MaterialPageRoute(builder: (_) => CreateGroupScreen(friends: _friends)),
    );
    if (result == null || !context.mounted) return;
    final (name, memberPubkeys) = result;

    const secureStorage = FlutterSecureStorage();
    final mnemonic = await secureStorage.read(key: seedStorageKey);
    if (mnemonic == null) return;
    final storageDir = await getApplicationDocumentsDirectory();
    final ratchetKey = await getOrCreateRatchetKey();
    final group = await groups_api.createGroup(
      mnemonic: mnemonic,
      storageDir: storageDir.path,
      name: name,
      memberPubkeys: memberPubkeys,
      ratchetKey: ratchetKey,
    );
    await _loadGroups();
    // This device just minted its own per-group routing identity for this
    // brand-new group (see `groups.rs::own_member_entry`) — the running
    // subscription's watch list doesn't include it yet (built before this
    // group existed), so rebuild it now, same reasoning as the
    // `group_invite` handler below.
    _subscribeFriendEvents();
    if (!context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => GroupThreadScreen(group: group, messageEvents: _friendEventsStream),
      ),
    );
    // Sending a message inside the thread just opened doesn't emit a live
    // sink event for the sender's own device (see `groups.rs`'s module
    // doc — a self-sent message is appended locally, not received over
    // the subscription), so nothing else would otherwise tell the Talk
    // tab to refresh this group's preview after returning here.
    await _loadGroups();
  }

  /// Pull-to-refresh: just re-reads the local friends list. The live
  /// subscription (started in [_subscribeFriendEvents]) keeps it current —
  /// on reconnect, relays replay any events missed while the app was
  /// closed, so no separate relay round-trip is needed here.
  Future<void> _refreshFriends() async {
    await _loadFriends();
  }

  Future<void> _toggleFavorite(friends_api.Friend friend) async {
    final storageDir = await getApplicationDocumentsDirectory();
    await friends_api.setFavoriteFriend(
      storageDir: storageDir.path,
      pubkey: friend.pubkey,
      isFavorite: !friend.isFavorite,
    );
    await _loadFriends();
    unawaited(publishAccountFriendsBackup());
  }

  Future<void> _blockFriend(friends_api.Friend friend) async {
    final storageDir = await getApplicationDocumentsDirectory();
    // Blocking silences a friend (their messages/profile updates stop
    // being applied — see the live subscription's blocked check) but
    // deliberately doesn't remove them from friends.json, so it stays
    // reversible via unblock.
    await friends_api.blockPubkey(storageDir: storageDir.path, pubkey: friend.pubkey);
    await _loadFriends();
    unawaited(publishAccountBlockedBackup());
  }

  Future<void> _unblockFriend(friends_api.Friend friend) async {
    final storageDir = await getApplicationDocumentsDirectory();
    await friends_api.unblockPubkey(storageDir: storageDir.path, pubkey: friend.pubkey);
    await _loadFriends();
    unawaited(publishAccountBlockedBackup());
  }

  /// Wipes local message history with a friend and drops the thread out of
  /// the Talk tab (until either side messages again) — purely local, so it
  /// doesn't affect the friendship or notify them.
  Future<void> _clearChat(friends_api.Friend friend) async {
    const secureStorage = FlutterSecureStorage();
    final mnemonic = await secureStorage.read(key: seedStorageKey);
    if (mnemonic == null) return;
    final storageDir = await getApplicationDocumentsDirectory();
    await chat_api.clearChatHistory(
      mnemonic: mnemonic,
      storageDir: storageDir.path,
      friendPubkey: friend.pubkey,
    );
    await _loadActiveChatPubkeys();
  }

  /// "Create talk room" from the Talk tab's "+" menu: pick a friend and
  /// open their thread, marking it started if it wasn't already. If a
  /// thread already exists (with this friend or otherwise), this just
  /// opens it — [chat_api.markChatStarted] is idempotent and
  /// [ChatThreadScreen] always loads whatever history is already there,
  /// so there's no separate "room" entity being created underneath.
  Future<void> _createTalkRoom(BuildContext context) async {
    final friend = await Navigator.of(context).push<friends_api.Friend>(
      MaterialPageRoute(builder: (_) => CreateTalkRoomScreen(friends: _friends)),
    );
    if (friend == null || !context.mounted) return;

    final storageDir = await getApplicationDocumentsDirectory();
    await chat_api.markChatStarted(storageDir: storageDir.path, friendPubkey: friend.pubkey);
    unawaited(publishAccountChatStartedBackup());
    await _loadActiveChatPubkeys();
    if (!context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChatThreadScreen(
          friend: friend,
          messageEvents: _friendEventsStream,
          onToggleFavorite: _toggleFavorite,
          onBlockFriend: _blockFriend,
          onUnblockFriend: _unblockFriend,
          onClearChat: _clearChat,
        ),
      ),
    );
    _loadActiveChatPubkeys();
  }

  Future<void> _editProfile() async {
    final updated = await Navigator.of(context).push<account_api.Account>(
      MaterialPageRoute(builder: (_) => EditProfileScreen(profile: _profile)),
    );
    if (updated == null) return;
    setState(() => _profile = updated);
  }

  Future<void> _openAddFriend() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AddFriendScreen(messageEvents: _friendEventsStream),
      ),
    );
    _refreshFriends();
    _refreshPendingRequestCount();
    unawaited(publishAccountFriendsBackup());
    // A new invite or outgoing request may have been created — resubscribe
    // so the live connection watches for it too.
    _subscribeFriendEvents();
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SettingsScreen(
          profile: _profile,
          onProfileUpdated: (updated) => setState(() => _profile = updated),
          onSelectLanguage: widget.onSelectLanguage,
          onLogout: widget.onLogout,
          messageEvents: _friendEventsStream,
        ),
      ),
    );
    // Settings > Blocked accounts can unblock someone from in there, which
    // should bring them back to the friends list / Talk the same way
    // unblocking from their own profile already does (see
    // `_unblockFriend`) — reload once control returns here rather than
    // threading a dedicated callback all the way through
    // `SettingsScreen` -> `BlockedAccountsScreen`.
    await _loadFriends();
  }

  /// Opens Global Profile setup/edit. When a profile already exists, loads
  /// it first so the form is pre-filled (edit rather than create). Used
  /// both by the pencil icon on an existing profile and — via
  /// [_openGlobalModeGuarded] — as the redirect target when switching into
  /// Global mode without one yet.
  Future<void> _openGlobalProfileSetup() async {
    final storageDir = await getApplicationDocumentsDirectory();
    final existing = await global_chat_api.loadGlobalProfile(storageDir: storageDir.path);
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => GlobalProfileSetupScreen(
          existingProfile: existing,
          onDone: () => Navigator.of(context).pop(),
        ),
      ),
    );
    _globalProfileTabKey.currentState?.reload();
  }

  /// The Private/Global toggle's callback: switching to Private never needs
  /// gating, but switching to Global does — without a Global Profile yet,
  /// jump to setup instead of just flipping the mode, since Home/Talk's
  /// Global content (posting a channel, appearing under a name) all assumes
  /// one exists. Staying on Private after a skip is deliberate; completing
  /// setup switches to Global immediately since that's clearly what was
  /// wanted.
  Future<void> _onGlobalModeChanged(bool value) async {
    if (!value) {
      setState(() => _globalMode = false);
      return;
    }
    final storageDir = await getApplicationDocumentsDirectory();
    final hasProfile = await global_chat_api.hasGlobalProfile(storageDir: storageDir.path);
    if (hasProfile) {
      setState(() => _globalMode = true);
      return;
    }
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => GlobalProfileSetupScreen(onDone: () => Navigator.of(context).pop()),
      ),
    );
    if (!mounted) return;
    final createdProfile = await global_chat_api.hasGlobalProfile(storageDir: storageDir.path);
    if (createdProfile) {
      _globalProfileTabKey.currentState?.reload();
      setState(() => _globalMode = true);
    }
  }

  Future<void> _searchGlobalChannel(BuildContext context) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const GlobalChannelSearchScreen()),
    );
    await _loadChannels();
    _globalProfileTabKey.currentState?.reload();
  }

  Future<void> _createGlobalChannel(BuildContext context) async {
    final created = await createGlobalChannel(context);
    if (!created) return;
    await _loadChannels();
    _globalProfileTabKey.currentState?.reload();
  }

  @override
  Widget build(BuildContext context) {
    // Home and Talk each host both their private and Global content
    // permanently (via IndexedStack below) rather than swapping widgets in
    // and out of the tree on every toggle/tab change — that used to
    // dispose+recreate State each time, so the newly-shown tab flashed
    // empty while its async load was still in flight. Keeping every branch
    // mounted means a load only ever happens once, up front.
    final homeStack = IndexedStack(
      index: _globalMode ? 1 : 0,
      children: [
        AccountFriendsTab(
          profile: _profile,
          uid: _uid,
          friends: _friends,
          unreadCounts: _unreadCounts,
          onEditProfile: _editProfile,
          onAddFriend: _openAddFriend,
          onRefreshFriends: _refreshFriends,
          onToggleFavorite: _toggleFavorite,
          onBlockFriend: _blockFriend,
          onUnblockFriend: _unblockFriend,
          onClearChat: _clearChat,
          onFriendProfileClosed: () {
            _loadFriends();
            _loadActiveChatPubkeys();
          },
          messageEvents: _friendEventsStream,
        ),
        _GlobalProfileTab(
          key: _globalProfileTabKey,
          globalPubkey: _globalPubkey,
          onEditProfile: _openGlobalProfileSetup,
        ),
      ],
    );
    // Talk is deliberately NOT behind the Private/Global toggle — see the
    // module doc above. Friends, groups, and joined Global channels all
    // show up in one merged, recency-sorted list (see `chat_list.dart`'s
    // `_buildEntries`), same trust models as before, just not visually
    // split behind a mode switch the user has to remember to flip.
    final talkTab = ChatListTab(
      // Only friends with a started (or already-in-progress) chat show up
      // here — tapping "Talk" on a friend's profile is what starts one,
      // rather than every friend appearing by default. Blocked friends are
      // excluded too (see `friend_profile.dart`'s class doc comment) —
      // Talk is one of the "friends list"-derived surfaces a block hides
      // someone from.
      friends: _friends.where((f) => _activeChatPubkeys.contains(f.pubkey) && !f.isBlocked).toList(),
      groups: _groups,
      channels: _channels,
      messageEvents: _friendEventsStream,
      onToggleFavorite: _toggleFavorite,
      onBlockFriend: _blockFriend,
      onUnblockFriend: _unblockFriend,
      onClearChat: _clearChat,
      onGroupsChanged: () async {
        await _loadGroups();
        // A group leave/removal doesn't change *this* device's own group
        // routing identity, but the roster-change convention already
        // established in this codebase (see `_createGroup`) rebuilds the
        // subscription watch list defensively after any roster mutation.
        _subscribeFriendEvents();
      },
      onChannelsChanged: _loadChannels,
      unreadCounts: _unreadCounts,
      onUnreadCountsChanged: _refreshUnreadCounts,
    );
    final tabs = [homeStack, talkTab, const _TimelinePlaceholder()];

    return Scaffold(
      backgroundColor: OrigilinkColors.background,
      body: SafeArea(
        child: Column(
          children: [
            _HomeTopBar(
              onSettingsTap: _openSettings,
              onAddFriendTap: _openAddFriend,
              onCreateTalkRoom: _createTalkRoom,
              onCreateGroup: _createGroup,
              pendingRequestCount: _pendingRequestCount,
              isTalkTab: _selectedIndex == 1,
              onSearchChannel: _searchGlobalChannel,
              onCreateChannel: _createGlobalChannel,
              // The mode toggle now only affects Home (which posting
              // identity/profile you're managing) — Talk always shows
              // everything, so the toggle would be a no-op there.
              showModeToggle: _selectedIndex == 0,
              isGlobalMode: _globalMode,
              onGlobalModeChanged: _onGlobalModeChanged,
              privateBadgeCount: _pendingRequestCount + _talkUnreadTotal,
            ),
            Expanded(child: IndexedStack(index: _selectedIndex, children: tabs)),
          ],
        ),
      ),
      bottomNavigationBar: OrigilinkNavBar(
        selectedIndex: _selectedIndex,
        onTap: (index) => setState(() => _selectedIndex = index),
        talkUnreadCount: _talkUnreadTotal,
        pendingRequestCount: _pendingRequestCount,
      ),
    );
  }
}

/// Right-aligned bar of icon actions shown above the tab content, regardless
/// of which tab is selected: announcements (not wired up yet), add friend,
/// settings.
class _HomeTopBar extends StatelessWidget {
  const _HomeTopBar({
    required this.onSettingsTap,
    required this.onAddFriendTap,
    required this.onCreateTalkRoom,
    required this.onCreateGroup,
    required this.pendingRequestCount,
    required this.isTalkTab,
    required this.onSearchChannel,
    required this.onCreateChannel,
    required this.showModeToggle,
    required this.isGlobalMode,
    required this.onGlobalModeChanged,
    required this.privateBadgeCount,
  });

  final VoidCallback onSettingsTap;
  final VoidCallback onAddFriendTap;
  final Future<void> Function(BuildContext context) onCreateTalkRoom;
  final Future<void> Function(BuildContext context) onCreateGroup;
  final int pendingRequestCount;

  /// On the Talk tab, the usual "add friend" icon becomes a plain "+" that
  /// opens a menu with talk room / group / friend creation *and* Global
  /// channel search/create — Talk shows both worlds merged (see
  /// `chat_list.dart`), so its "+" menu offers every way to add a row to it
  /// rather than being gated by the Private/Global toggle.
  final bool isTalkTab;
  final Future<void> Function(BuildContext context) onSearchChannel;
  final Future<void> Function(BuildContext context) onCreateChannel;

  /// Whether the Private/Global segmented toggle applies to the currently
  /// visible tab (Home or Talk) — false on the Timeline placeholder tab.
  final bool showModeToggle;
  final bool isGlobalMode;
  final Future<void> Function(bool) onGlobalModeChanged;

  /// Combined pending-friend-request + unread-message count, shown as the
  /// toggle's Private-side badge.
  final int privateBadgeCount;

  Future<void> _showTalkAddMenu(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: OrigilinkColors.background,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.chat_bubble_outline),
              title: Text(l10n.createTalkRoom),
              onTap: () => Navigator.of(sheetContext).pop('room'),
            ),
            ListTile(
              leading: const Icon(Icons.groups_outlined),
              title: Text(l10n.createGroup),
              onTap: () => Navigator.of(sheetContext).pop('group'),
            ),
            ListTile(
              leading: Badge(
                isLabelVisible: pendingRequestCount > 0,
                label: Text('$pendingRequestCount'),
                child: const Icon(Icons.person_add_alt_outlined),
              ),
              title: Text(l10n.addFriendTitle),
              onTap: () => Navigator.of(sheetContext).pop('friend'),
            ),
            ListTile(
              leading: const Icon(Icons.tag),
              title: Text(l10n.talkAddSearchGlobalChannel),
              onTap: () => Navigator.of(sheetContext).pop('search-channel'),
            ),
            ListTile(
              leading: const Icon(Icons.add_comment_outlined),
              title: Text(l10n.talkAddCreateGlobalChannel),
              onTap: () => Navigator.of(sheetContext).pop('create-channel'),
            ),
          ],
        ),
      ),
    );
    if (choice == 'friend') {
      onAddFriendTap();
    } else if (choice == 'room' && context.mounted) {
      onCreateTalkRoom(context);
    } else if (choice == 'group' && context.mounted) {
      onCreateGroup(context);
    } else if (choice == 'search-channel' && context.mounted) {
      await onSearchChannel(context);
    } else if (choice == 'create-channel' && context.mounted) {
      await onCreateChannel(context);
    }
  }

  /// Home tab's Global-mode counterpart to [_showTalkAddMenu] — only the
  /// channel search/create choices apply here (no friend/room/group: those
  /// are Private-mode/Talk-tab concepts), same shape as the Private Home
  /// tab's plain "add friend" icon just gated to what Global Home actually
  /// lists (see [_GlobalProfileTab]'s doc comment).
  Future<void> _showGlobalAddMenu(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: OrigilinkColors.background,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.tag),
              title: Text(l10n.talkAddSearchGlobalChannel),
              onTap: () => Navigator.of(sheetContext).pop('search-channel'),
            ),
            ListTile(
              leading: const Icon(Icons.add_comment_outlined),
              title: Text(l10n.talkAddCreateGlobalChannel),
              onTap: () => Navigator.of(sheetContext).pop('create-channel'),
            ),
          ],
        ),
      ),
    );
    if (choice == 'search-channel' && context.mounted) {
      await onSearchChannel(context);
    } else if (choice == 'create-channel' && context.mounted) {
      await onCreateChannel(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          if (showModeToggle)
            PrivateGlobalToggle(
              isGlobal: isGlobalMode,
              onChanged: onGlobalModeChanged,
              privateBadgeCount: privateBadgeCount,
            )
          else
            const SizedBox.shrink(),
          Row(
            children: [
              if (isTalkTab)
                _topBarIcon(
                  Icons.add,
                  () => _showTalkAddMenu(context),
                  badgeCount: pendingRequestCount,
                )
              else if (!isGlobalMode)
                _topBarIcon(
                  Icons.person_add_alt_outlined,
                  onAddFriendTap,
                  badgeCount: pendingRequestCount,
                )
              else
                _topBarIcon(Icons.add, () => _showGlobalAddMenu(context)),
              const SizedBox(width: 12),
              _topBarIcon(Icons.settings_outlined, onSettingsTap),
            ],
          ),
        ],
      ),
    );
  }

  Widget _topBarIcon(
    IconData icon,
    VoidCallback onPressed, {
    int badgeCount = 0,
  }) {
    return InkResponse(
      onTap: onPressed,
      radius: 20,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Badge(
          isLabelVisible: badgeCount > 0,
          label: Text('$badgeCount'),
          child: Icon(icon, color: OrigilinkColors.textSecondary),
        ),
      ),
    );
  }
}

/// Home tab's Global-mode content: this device's Global Chat identity
/// (separate from the private account identity — see `global_chat.rs`)
/// plus the channels it's joined, styled and behaving like
/// `account_friends.dart`'s friends list (tap → a profile-style screen with
/// a "Talk" button) — the Global-mode counterpart of the Private Home tab.
/// Shares its data with `chat_list.dart`'s merged Talk list via
/// `global_chat.rs`'s joined-channels store, just presented as a directory
/// here instead of a message-preview list.
class _GlobalProfileTab extends StatefulWidget {
  const _GlobalProfileTab({required this.globalPubkey, required this.onEditProfile, super.key});

  final String? globalPubkey;
  final VoidCallback onEditProfile;

  @override
  State<_GlobalProfileTab> createState() => _GlobalProfileTabState();
}

class _GlobalProfileTabState extends State<_GlobalProfileTab> {
  List<global_chat_api.GlobalChannel> _channels = [];
  global_chat_api.GlobalOwnProfile? _profile;

  @override
  void initState() {
    super.initState();
    reload();
  }

  Future<void> reload() async {
    final storageDir = await getApplicationDocumentsDirectory();
    final channels = await global_chat_api.listJoinedChannels(storageDir: storageDir.path);
    final profile = await global_chat_api.loadGlobalProfile(storageDir: storageDir.path);
    if (!mounted) return;
    setState(() {
      _channels = channels;
      _profile = profile;
    });
  }

  Future<void> _openChannelProfile(global_chat_api.GlobalChannel channel) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => GlobalChannelProfileScreen(channel: channel)),
    );
    reload();
  }

  Future<void> _addChannel(BuildContext context) async {
    final changed = await showGlobalChannelAddMenu(context);
    if (changed) reload();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: OrigilinkColors.surface,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              children: [
                Container(
                  width: 64,
                  height: 64,
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    color: OrigilinkColors.background,
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: _profile?.avatarPath != null
                      ? Image.file(
                          File(_profile!.avatarPath!),
                          width: 64,
                          height: 64,
                          fit: BoxFit.cover,
                        )
                      : const Icon(
                          Icons.public,
                          size: 32,
                          color: OrigilinkColors.textSecondary,
                        ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        (_profile?.name.isNotEmpty ?? false)
                            ? _profile!.name
                            : l10n.globalProfileSetupTitle,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                          color: OrigilinkColors.textPrimary,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        (_profile?.about.isNotEmpty ?? false) ? _profile!.about : l10n.noStatusMessage,
                        style: TextStyle(
                          fontSize: 13,
                          color: (_profile?.about.isNotEmpty ?? false)
                              ? OrigilinkColors.textSecondary
                              : OrigilinkColors.textSecondary.withValues(alpha: 0.6),
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (widget.globalPubkey != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          'key:${widget.globalPubkey!.substring(0, 16)}…',
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 11,
                            color: OrigilinkColors.textSecondary,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ],
                  ),
                ),
                IconButton(
                  onPressed: widget.onEditProfile,
                  tooltip: l10n.editProfile,
                  icon: const Icon(
                    Icons.edit_outlined,
                    size: 20,
                    color: OrigilinkColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          if (_channels.isEmpty) ...[
            SizedBox(
              height: 48,
              child: OutlinedButton.icon(
                onPressed: () => _addChannel(context),
                icon: const Icon(Icons.search, size: 22),
                label: Text(
                  l10n.searchChannelsTitle,
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
                ),
                style: OutlinedButton.styleFrom(
                  foregroundColor: OrigilinkColors.primaryDark,
                  side: const BorderSide(color: OrigilinkColors.primary, width: 1.2),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ),
            const SizedBox(height: 24),
          ],
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                l10n.joinedChannelsSectionTitle,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: OrigilinkColors.textSecondary,
                ),
              ),
              if (_channels.isNotEmpty)
                IconButton(
                  onPressed: () => _addChannel(context),
                  icon: const Icon(
                    Icons.add_comment_outlined,
                    size: 20,
                    color: OrigilinkColors.textSecondary,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Expanded(
            child: RefreshIndicator(
              onRefresh: reload,
              child: _channels.isEmpty
                  ? LayoutBuilder(
                      builder: (context, constraints) => ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        children: [
                          ConstrainedBox(
                            constraints: BoxConstraints(minHeight: constraints.maxHeight),
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
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w500,
                                      color: OrigilinkColors.textSecondary,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    l10n.noJoinedChannelsHint,
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: OrigilinkColors.textSecondary.withValues(alpha: 0.7),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    )
                  : ListView.separated(
                      itemCount: _channels.length,
                      separatorBuilder: (context, index) => const Divider(
                        height: 1,
                        indent: 82,
                        color: Color(0x14000000),
                      ),
                      itemBuilder: (context, index) {
                        final channel = _channels[index];
                        return InkWell(
                          onTap: () => _openChannelProfile(channel),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 10),
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
                                        channel.about.isNotEmpty ? channel.about : l10n.noChannelAbout,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(color: OrigilinkColors.textSecondary),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Standalone placeholder for the third bottom-nav destination — a future
/// feature not yet designed, occupying the tab slot that used to host the
/// now-toggle-integrated Global Chat channel list.
class _TimelinePlaceholder extends StatelessWidget {
  const _TimelinePlaceholder();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Center(
      child: Text(
        l10n.comingSoon,
        style: const TextStyle(color: OrigilinkColors.textSecondary, fontSize: 16),
      ),
    );
  }
}
