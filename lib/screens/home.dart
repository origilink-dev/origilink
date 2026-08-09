import 'dart:async';

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
import 'package:origilink/screens/public_chat_list.dart';
import 'package:origilink/screens/settings.dart';
import 'package:origilink/services/account_sync.dart';
import 'package:origilink/services/ratchet_key.dart';
import 'package:origilink/src/rust/api/account.dart' as account_api;
import 'package:origilink/src/rust/api/chat.dart' as chat_api;
import 'package:origilink/src/rust/api/config.dart' as config_api;
import 'package:origilink/src/rust/api/friends.dart' as friends_api;
import 'package:origilink/src/rust/api/groups.dart' as groups_api;
import 'package:origilink/src/rust/api/sync.dart' as sync_api;

/// Home screen shown after profile setup. Hosts the three main sections of
/// the app behind a bottom navigation bar: Profile & Friends, Talk, and
/// Public Chat.
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
  bool _origilinkOnlyChannels = true;
  final _publicChatKey = GlobalKey<PublicChatListTabState>();
  late account_api.Account _profile = widget.profile;

  List<friends_api.Friend> _friends = [];
  List<groups_api.Group> _groups = [];
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
    _loadActiveChatPubkeys();
    _refreshPendingRequestCount();
    _subscribeFriendEvents();
    friendEventsRefreshSignal.addListener(_subscribeFriendEvents);
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

  Future<void> _deleteFriend(friends_api.Friend friend) async {
    final storageDir = await getApplicationDocumentsDirectory();
    await friends_api.removeFriend(storageDir: storageDir.path, pubkey: friend.pubkey);
    await _loadFriends();
    unawaited(publishAccountFriendsBackup());
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
          onDeleteFriend: _deleteFriend,
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

  void _openSettings() {
    Navigator.of(context).push(
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
  }

  @override
  Widget build(BuildContext context) {
    final tabs = [
      AccountFriendsTab(
        profile: _profile,
        friends: _friends,
        onEditProfile: _editProfile,
        onAddFriend: _openAddFriend,
        onRefreshFriends: _refreshFriends,
        onToggleFavorite: _toggleFavorite,
        onBlockFriend: _blockFriend,
        onUnblockFriend: _unblockFriend,
        onDeleteFriend: _deleteFriend,
        onClearChat: _clearChat,
        onFriendProfileClosed: () {
          _loadFriends();
          _loadActiveChatPubkeys();
        },
        messageEvents: _friendEventsStream,
      ),
      ChatListTab(
        // Only friends with a started (or already-in-progress) chat show
        // up here — tapping "Talk" on a friend's profile is what starts
        // one, rather than every friend appearing by default.
        friends: _friends.where((f) => _activeChatPubkeys.contains(f.pubkey)).toList(),
        groups: _groups,
        messageEvents: _friendEventsStream,
        onToggleFavorite: _toggleFavorite,
        onBlockFriend: _blockFriend,
        onUnblockFriend: _unblockFriend,
        onDeleteFriend: _deleteFriend,
        onClearChat: _clearChat,
        onGroupsChanged: () async {
          await _loadGroups();
          // A group leave/removal doesn't change *this* device's own group
          // routing identity, but the roster-change convention already
          // established in this codebase (see `_createGroup`) rebuilds the
          // subscription watch list defensively after any roster mutation.
          _subscribeFriendEvents();
        },
        unreadCounts: _unreadCounts,
        onUnreadCountsChanged: _refreshUnreadCounts,
      ),
      PublicChatListTab(key: _publicChatKey, origilinkOnly: _origilinkOnlyChannels),
    ];

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
              isPublicChatTab: _selectedIndex == 2,
              origilinkOnlyChannels: _origilinkOnlyChannels,
              onOrigilinkOnlyChannelsChanged: (value) {
                setState(() => _origilinkOnlyChannels = value);
              },
              onCreateChannel: () => _publicChatKey.currentState?.createChannel(),
            ),
            Expanded(child: tabs[_selectedIndex]),
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
    required this.isPublicChatTab,
    required this.origilinkOnlyChannels,
    required this.onOrigilinkOnlyChannelsChanged,
    required this.onCreateChannel,
  });

  final VoidCallback onSettingsTap;
  final VoidCallback onAddFriendTap;
  final Future<void> Function(BuildContext context) onCreateTalkRoom;
  final Future<void> Function(BuildContext context) onCreateGroup;
  final int pendingRequestCount;

  /// On the Talk tab, the usual "add friend" icon becomes a plain "+" that
  /// opens a menu with talk room / group / friend creation instead of
  /// jumping straight to add-friend.
  final bool isTalkTab;

  /// On the Public Chat tab, this bar also shows the origilink-only/all-channels
  /// toggle (left side, alongside settings) and the "add friend" icon becomes
  /// a "new channel" icon instead.
  final bool isPublicChatTab;
  final bool origilinkOnlyChannels;
  final ValueChanged<bool> onOrigilinkOnlyChannelsChanged;
  final VoidCallback onCreateChannel;

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
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          if (isPublicChatTab)
            Tooltip(
              message: origilinkOnlyChannels
                  ? l10n.showAllChannelsTooltip
                  : l10n.showOrigilinkChannelsTooltip,
              child: InkWell(
                borderRadius: BorderRadius.circular(20),
                onTap: () => onOrigilinkOnlyChannelsChanged(!origilinkOnlyChannels),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Transform.scale(
                      scale: 0.75,
                      alignment: Alignment.centerLeft,
                      child: Switch.adaptive(
                        value: origilinkOnlyChannels,
                        activeThumbColor: OrigilinkColors.primaryDark,
                        onChanged: onOrigilinkOnlyChannelsChanged,
                      ),
                    ),
                    Text(
                      origilinkOnlyChannels ? l10n.origilinkChannelsTitle : l10n.allChannelsTitle,
                      style: const TextStyle(fontSize: 12, color: OrigilinkColors.textSecondary),
                    ),
                  ],
                ),
              ),
            )
          else
            const SizedBox.shrink(),
          Row(
            children: [
              // TODO: wire up announcements.
              _topBarIcon(Icons.notifications_outlined, () {}),
              const SizedBox(width: 12),
              if (isTalkTab)
                _topBarIcon(
                  Icons.add,
                  () => _showTalkAddMenu(context),
                  badgeCount: pendingRequestCount,
                )
              else if (isPublicChatTab)
                _topBarIcon(Icons.add_comment_outlined, onCreateChannel)
              else
                _topBarIcon(
                  Icons.person_add_alt_outlined,
                  onAddFriendTap,
                  badgeCount: pendingRequestCount,
                ),
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
