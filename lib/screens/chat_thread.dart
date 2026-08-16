import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MaxLengthEnforcement;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:mime/mime.dart';
import 'package:path_provider/path_provider.dart';
import 'package:origilink/l10n/app_localizations.dart';
import 'package:origilink/screens/friend_profile.dart';
import 'package:origilink/screens/login.dart';
import 'package:origilink/screens/logout.dart' show seedStorageKey;
import 'package:origilink/services/account_sync.dart';
import 'package:origilink/services/ratchet_key.dart';
import 'package:origilink/src/rust/api/account.dart' as account_api;
import 'package:origilink/src/rust/api/attachment.dart' as attachment_api;
import 'package:origilink/src/rust/api/chat.dart' as chat_api;
import 'package:origilink/src/rust/api/friends.dart' as friends_api;
import 'package:origilink/src/rust/api/ratchet.dart' as ratchet_api;
import 'package:origilink/src/rust/api/sync.dart' as sync_api;
import 'package:origilink/widgets/link_preview_card.dart';
import 'package:origilink/widgets/relative_date.dart';

/// Chat wallpaper background and the reply-preview accent bar color,
/// layered on top of the app's greige palette rather than replacing it
/// elsewhere. Near-white rather than the app's usual tan — the flat
/// Discord-style rows (see `_MessageBubble`) have no bubble box to give
/// message text its own contrasting surface anymore, so the page
/// background itself has to carry that contrast against `textPrimary`.
class _WaColors {
  static const wallpaper = Color(0xFFFAF8F4);
  static const bubbleMine = Color(0xFFD9C9AC);
}

/// One-to-one chat thread with [friend]: message history plus an input bar.
/// Sending re-reads the full history from local storage afterward (it's a
/// small per-friend dataset) rather than optimistically patching state, so
/// what's shown always matches what [chat_api.sendChatMessage] persisted.
class ChatThreadScreen extends StatefulWidget {
  const ChatThreadScreen({
    super.key,
    required this.friend,
    required this.messageEvents,
    required this.onToggleFavorite,
    required this.onBlockFriend,
    required this.onUnblockFriend,
    required this.onClearChat,
  });

  final friends_api.Friend friend;

  /// Live friend-protocol events shared with [HomeScreen]'s subscription —
  /// used to append incoming messages for this friend without polling.
  final Stream<sync_api.FriendEvent>? messageEvents;

  final Future<void> Function(friends_api.Friend friend) onToggleFavorite;
  final Future<void> Function(friends_api.Friend friend) onBlockFriend;
  final Future<void> Function(friends_api.Friend friend) onUnblockFriend;
  final Future<void> Function(friends_api.Friend friend) onClearChat;

  @override
  State<ChatThreadScreen> createState() => _ChatThreadScreenState();
}

class _ChatThreadScreenState extends State<ChatThreadScreen> {
  /// How many of the newest messages [_loadInitialHistory]'s background
  /// relay reconcile fetches (EOSE-gated) — see that method's doc comment.
  /// Kept modest since this now runs after the screen has already opened
  /// (against the local cache), so it's just catching up on anything new,
  /// not blocking anyone's first paint. Sized to roughly a couple of
  /// screenfuls at the current (slightly enlarged) bubble/font size rather
  /// than a fixed round number — fewer messages fit per screen now, so
  /// fewer need fetching to cover the same visible scroll range.
  ///
  /// Smaller than it used to be (was 20): [_loadInitialHistory] immediately
  /// primes one extra page beyond this after it loads (see its call to
  /// [_loadOlderMessages] at the end), so there's always a full page of
  /// already-loaded, already-preview-fetched messages sitting just out of
  /// view — the same total buffer as before (15 visible + 15 primed = 30),
  /// just split into two pages so the "next page" prefetch machinery
  /// naturally keeps one page ahead of the scroll position going forward.
  static const _initialHistoryLimit = 15;

  /// How many older messages [_loadOlderMessages] fetches per page once the
  /// user scrolls up past what's already loaded.
  static const _olderPageLimit = 15;

  final _messageController = TextEditingController();
  final _scrollController = ScrollController();
  List<chat_api.ChatMessage> _messages = [];

  /// Ids already handed to [prefetchLinkPreviews]/[_prefetchAttachments] —
  /// [chat_api.fetchChatHistoryPage] returns the *entire* merged local
  /// history on every call (not just the newly-fetched page), so without
  /// this every reload (a scroll-triggered older page, a live incoming
  /// message, ...) would re-extract URLs from and re-issue prefetch calls
  /// for every message ever loaded in this thread, not just the new ones —
  /// harmless (the Rust-side caches make it a no-op) but a growing amount
  /// of wasted FRB round-trips as history grows.
  final _prefetchedMessageIds = <String>{};
  bool _sending = false;
  bool _loadingOlder = false;
  bool _hasMoreOlder = true;

  /// Bumped at the start of every `_messages`-replacing load
  /// (`_loadInitialHistory`, `_loadHistory`, `_loadOlderMessages`). Each of
  /// those methods captures the value right after bumping it and checks it
  /// again before its own `setState` calls — if another load started (and
  /// bumped it again) in the meantime, the stale one skips its `setState`
  /// instead of clobbering newer data with what it fetched. Without this,
  /// sending the very first message of a brand-new chat while
  /// `_loadInitialHistory`'s background relay reconcile was still in
  /// flight could show the message immediately and then have it vanish a
  /// moment later when that older, slower fetch finally resolved and
  /// overwrote `_messages` with its now-stale snapshot.
  int _historyLoadGeneration = 0;

  /// Set while a lookahead check from [itemBuilder]'s index-based trigger
  /// is already queued via `addPostFrameCallback` — `cacheExtent: 3000`
  /// means every row within one page of the top gets rebuilt (and its
  /// lookahead check re-run) on *any* rebuild of this screen, not just
  /// scroll-driven ones, so without this a single frame with several
  /// qualifying rows queues that many redundant callbacks (each a no-op
  /// past the first, thanks to [_loadOlderMessages]'s own guards, but still
  /// wasted allocation/scheduling).
  bool _lookaheadScheduled = false;
  chat_api.ChatMessage? _replyingTo;

  /// Set once a file is picked, cleared once it's sent (or removed) — the
  /// file is only uploaded when the send button is pressed, so a caption
  /// can be typed alongside it first.
  String? _pendingAttachmentPath;
  String? _pendingAttachmentName;
  String? _pendingAttachmentMimeType;

  /// Non-null while an attachment upload is in flight — drives the donut
  /// progress ring on the send button.
  double? _uploadProgress;
  late bool _isBlocked = widget.friend.isBlocked;
  int _maxMessageChars = 4000;
  StreamSubscription<sync_api.FriendEvent>? _sub;

  /// Mirrors [widget.friend], refreshed on a `profile_updated` event — the
  /// widget itself is a fixed snapshot from when this route was pushed, so
  /// without this an avatar/name change made while the thread is open
  /// (rather than picked up on the next visit from the Talk tab, which
  /// rebuilds this screen with a fresh [friends_api.Friend]) would never
  /// show here until the thread is closed and reopened.
  late friends_api.Friend _friend = widget.friend;

  /// Ids of messages in [_messages] that came from [ratchet_api] (forward
  /// secret) rather than the regular NIP-44 history — drives a lock badge
  /// on those bubbles.
  Set<String> _forwardSecretIds = {};

  /// Whether [widget.friend] has announced a forward-secrecy device we can
  /// send ratchet-encrypted messages to — see `ratchet.rs`'s module doc.
  bool _friendHasRatchetDevice = false;

  /// This device's own avatar — shown on the group-header row for
  /// consecutive own messages, Discord-style (see `_MessageBubble`), same
  /// as [_friend]'s avatar is for theirs.
  String? _myAvatarPath;

  @override
  void initState() {
    super.initState();
    _loadInitialHistory();
    _subscribe();
    _initForwardSecrecy();
    _loadMyAvatar();
    _scrollController.addListener(_onScroll);
    chat_api.maxMessageChars().then((max) {
      if (mounted) setState(() => _maxMessageChars = max);
    });
  }

  Future<void> _loadMyAvatar() async {
    final storageDir = await getApplicationDocumentsDirectory();
    final account = await account_api.loadAccount(storageDir: storageDir.path);
    if (!mounted) return;
    setState(() => _myAvatarPath = account?.avatarPath);
  }

  /// Ensures this device has a forward-secrecy identity, announces it to
  /// this friend (idempotent — cheap control message, harmless to repeat
  /// on every thread open), and checks whether they've announced one back
  /// to us yet.
  Future<void> _initForwardSecrecy() async {
    const secureStorage = FlutterSecureStorage();
    final mnemonic = await secureStorage.read(key: seedStorageKey);
    if (mnemonic == null || !mounted) return;
    final storageDir = await getApplicationDocumentsDirectory();
    final ratchetKey = await getOrCreateRatchetKey();
    if (!mounted) return;
    try {
      await ratchet_api.announceDevice(
        mnemonic: mnemonic,
        storageDir: storageDir.path,
        friendPubkey: widget.friend.pubkey,
        localKey: ratchetKey,
      );
    } catch (_) {
      // Offline — the friend just won't learn about this device until the
      // next time this thread is opened with connectivity.
    }
    await _refreshFriendRatchetDevice();
  }

  Future<void> _refreshFriendRatchetDevice() async {
    final storageDir = await getApplicationDocumentsDirectory();
    final devicePubkey = await ratchet_api.friendDevicePubkey(
      storageDir: storageDir.path,
      friendPubkey: widget.friend.pubkey,
    );
    if (!mounted) return;
    setState(() => _friendHasRatchetDevice = devicePubkey != null);
  }

  /// With the list reversed, scrolling "up" toward older messages moves
  /// *away* from offset 0 (the newest, at the bottom) toward
  /// `maxScrollExtent` (the oldest currently-loaded message, at the top) —
  /// so nearing that end is what should trigger loading another page. A
  /// small head start (rather than waiting for the exact edge) avoids
  /// making the user sit through the relay round-trip with their finger
  /// already at the top.
  void _onScroll() {
    if (!_scrollController.hasClients || _loadingOlder || !_hasMoreOlder) {
      return;
    }
    final position = _scrollController.position;
    // A conversation short enough to fit on screen has maxScrollExtent == 0
    // — without this guard, `0 >= 0 - 200` is trivially true and this would
    // fire immediately on every rebuild, even though the user never
    // scrolled at all.
    if (position.maxScrollExtent <= 0) return;
    if (position.pixels >= position.maxScrollExtent - 200) {
      _loadOlderMessages();
    }
  }

  Future<void> _handleBlock(friends_api.Friend friend) async {
    setState(() => _isBlocked = true);
    await widget.onBlockFriend(friend);
  }

  Future<void> _handleUnblock(friends_api.Friend friend) async {
    setState(() => _isBlocked = false);
    await widget.onUnblockFriend(friend);
  }

  void _subscribe() {
    _sub = widget.messageEvents?.listen((event) {
      if (event.pubkey != widget.friend.pubkey) return;
      if (event.kind == 'message' || event.kind == 'ratchet_message') {
        _loadHistory();
      } else if (event.kind == 'ratchet_device_announced') {
        _refreshFriendRatchetDevice();
      } else if (event.kind == 'profile_updated') {
        _refreshFriend();
      }
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
  void didUpdateWidget(covariant ChatThreadScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.messageEvents != widget.messageEvents) {
      _sub?.cancel();
      _subscribe();
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    _messageController.dispose();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  /// First load for this thread: shows whatever's already in local
  /// storage instantly (no relay wait — a thread that's already synced
  /// opens exactly as fast as before `fetch_chat_history_page` existed),
  /// then reconciles with relays in the background via an EOSE-gated
  /// one-shot fetch (see that function's doc comment) to catch up on
  /// anything sent since the last sync.
  ///
  /// Doing the relay fetch in the background rather than up front avoids
  /// the flash the EOSE gating was originally added to prevent: the live
  /// subscription replays historical backlog with no ordering boundary,
  /// streaming events in one at a time, so reading local storage the
  /// instant the *first* one of those arrives could show a message that
  /// gets edited/unsent a moment later when its retraction (published in
  /// the same batch) shows up right after — but by the time this runs,
  /// the local copy is already the fully-resolved result of the *previous*
  /// sync, so there's nothing left mid-resolution to flash.
  /// Same idea as [prefetchLinkPreviews]: fires off (and ignores the
  /// result of) a download for every image attachment across [messages],
  /// so `attachment.rs`'s on-disk cache (keyed by message id) is already
  /// warm by the time `_AttachmentPreview` actually builds for one of
  /// these messages and starts its own download — which then just hits
  /// that cache and returns instantly instead of re-downloading. Non-image
  /// attachments are skipped, matching `_AttachmentPreviewState.initState`
  /// only eagerly downloading images (other file types stay tap-to-download
  /// so a chat full of arbitrary files never triggers a wall of background
  /// downloads).
  /// [messages] should be newest-first — see [_prefetchNewMessages]'s doc
  /// comment on why iteration order here determines
  /// [_fetchSemaphore] priority.
  void _prefetchAttachments(List<chat_api.ChatMessage> messages, String mnemonic, String storageDir) {
    final imageMessages = messages.where((m) => m.attachment?.mimeType.startsWith('image/') ?? false);
    for (final message in imageMessages) {
      final attachment = message.attachment!;
      unawaited(
        withPrefetchLimit(() async {
          try {
            await attachment_api.downloadChatAttachment(
              mnemonic: mnemonic,
              storageDir: storageDir,
              friendPubkey: widget.friend.pubkey,
              messageId: message.id,
              url: attachment.url,
              encKey: attachment.encKey,
            );
          } catch (_) {
            // Swallowed — the real widget's own download attempts (and can
            // report failure for) the same attachment later.
          }
        }),
      );
    }
  }

  /// Filters [messages] down to ones not already handed to the prefetch
  /// functions (see [_prefetchedMessageIds]'s doc comment) before firing
  /// them off, instead of reprocessing the whole (ever-growing) history on
  /// every call site that reloads `_messages`.
  ///
  /// Processed newest-first (`messages` itself is oldest-first, so this
  /// reverses): [prefetchLinkPreviews]/[_prefetchAttachments] fire every
  /// URL/image at once but [_fetchSemaphore] still bounds how many run
  /// concurrently, so call order decides which ones claim a slot first —
  /// the newest messages are the ones on/near screen right now, so their
  /// previews/images should win that race over older, likely still
  /// off-screen ones.
  void _prefetchNewMessages(List<chat_api.ChatMessage> messages, String mnemonic, String storageDir) {
    final newOnes = messages.reversed.where((m) => _prefetchedMessageIds.add(m.id)).toList();
    if (newOnes.isEmpty) return;
    prefetchLinkPreviews(newOnes.map((m) => m.content));
    _prefetchAttachments(newOnes, mnemonic, storageDir);
  }

  Future<void> _loadInitialHistory() async {
    final gen = ++_historyLoadGeneration;
    const secureStorage = FlutterSecureStorage();
    final mnemonic = await secureStorage.read(key: seedStorageKey);
    if (mnemonic == null || !mounted) return;
    final storageDir = await getApplicationDocumentsDirectory();

    final hasMore = await chat_api.hasMoreChatHistory(
      storageDir: storageDir.path,
      friendPubkey: widget.friend.pubkey,
    );
    final local = await chat_api.loadChatHistory(
      mnemonic: mnemonic,
      storageDir: storageDir.path,
      friendPubkey: widget.friend.pubkey,
    );
    if (!mounted) return;
    final mergedLocal = await _mergeWithRatchetHistory(local);
    if (!mounted || gen != _historyLoadGeneration) return;
    setState(() {
      _messages = mergedLocal;
      _hasMoreOlder = hasMore;
    });
    _scrollToBottom();
    _prefetchNewMessages(_messages, mnemonic, storageDir.path);

    final synced = await chat_api.fetchChatHistoryPage(
      mnemonic: mnemonic,
      storageDir: storageDir.path,
      friendPubkey: widget.friend.pubkey,
      before: null,
      limit: _initialHistoryLimit,
    );
    if (!mounted) return;
    final mergedSynced = await _mergeWithRatchetHistory(synced);
    if (!mounted || gen != _historyLoadGeneration) return;
    setState(() => _messages = mergedSynced);
    _scrollToBottom();
    _prefetchNewMessages(_messages, mnemonic, storageDir.path);
    await chat_api.markThreadRead(
      storageDir: storageDir.path,
      friendPubkey: widget.friend.pubkey,
    );
    unawaited(publishAccountReadStateBackup());
    // Prime one page of older messages (and their previews) immediately,
    // before the user has scrolled at all — see [_initialHistoryLimit]'s
    // doc comment. `_loadOlderMessages` itself already no-ops if there's
    // nothing more to load.
    if (gen == _historyLoadGeneration) unawaited(_loadOlderMessages());
  }

  /// Fetches another page of older messages once the user scrolls up past
  /// what's already loaded — same EOSE-gated relay fetch as
  /// [_loadInitialHistory]'s background reconcile, just anchored `before`
  /// the oldest message currently shown instead of the newest overall.
  /// [chat_api.fetchChatHistoryPage] already returns the full merged local
  /// history (not just the new page), so the result can replace
  /// `_messages` outright — no manual prepend/dedupe needed.
  /// [prime] loads are the one-page lookahead this fires on itself once a
  /// real (scroll-triggered) page finishes — so there's always a second
  /// page already sitting in `_messages` by the time the user scrolls into
  /// what was just the first one, instead of only ever keeping exactly one
  /// page of buffer above the viewport (which meant a relay round-trip was
  /// on the critical path of every single scroll near the top). Priming
  /// calls don't themselves prime further — that would chain into loading
  /// the entire thread history up front, defeating pagination entirely.
  Future<void> _loadOlderMessages({bool prime = false}) async {
    if (_messages.isEmpty || _loadingOlder || !_hasMoreOlder) return;
    final gen = ++_historyLoadGeneration;
    setState(() => _loadingOlder = true);
    const secureStorage = FlutterSecureStorage();
    final mnemonic = await secureStorage.read(key: seedStorageKey);
    if (mnemonic == null || !mounted) {
      if (mounted) setState(() => _loadingOlder = false);
      return;
    }
    final storageDir = await getApplicationDocumentsDirectory();
    final oldestBefore = _messages.first.createdAt;
    final page = await chat_api.fetchChatHistoryPage(
      mnemonic: mnemonic,
      storageDir: storageDir.path,
      friendPubkey: widget.friend.pubkey,
      before: oldestBefore,
      limit: _olderPageLimit,
    );
    if (!mounted) return;
    // [fetchChatHistoryPage] only reads `chat.lmdb` (the NIP-17 baseline
    // channel) — forward-secret messages live client-side only, in a
    // separate encrypted file (see `ratchet.rs`'s module doc), so without
    // re-merging them here every ratchet message currently in `_messages`
    // would be wiped from view the moment this runs (e.g. the very next
    // frame after sending the first ratchet message to a friend, via
    // `itemBuilder`'s lookahead trigger).
    final merged = await _mergeWithRatchetHistory(page);
    if (!mounted) return;
    if (gen != _historyLoadGeneration) {
      setState(() => _loadingOlder = false);
      return;
    }
    final gotOlder = page.isNotEmpty && page.first.createdAt < oldestBefore;
    setState(() {
      _messages = merged;
      _hasMoreOlder = gotOlder;
      _loadingOlder = false;
    });
    _prefetchNewMessages(_messages, mnemonic, storageDir.path);
    if (!prime && _hasMoreOlder) {
      unawaited(_loadOlderMessages(prime: true));
    }
    // While this page was loading, the user may have kept scrolling and
    // already be back within the trigger threshold of the new (still not
    // far enough ahead) edge — a `ListView` content change alone doesn't
    // re-fire the scroll-position listener that normally starts the next
    // load, so without this a fast scroll (or one that stops right at the
    // stale edge) could stall until the user nudges the list again.
    // Calling `_onScroll` synchronously here would read `maxScrollExtent`
    // from *before* this frame's newly-inserted messages are laid out
    // (`setState` only schedules the rebuild, it hasn't run yet), so the
    // check would always see the old, still-too-close edge and could
    // trigger nothing — deferring to the post-frame callback lets it read
    // the real, grown `maxScrollExtent`.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _onScroll();
    });
  }

  /// Reload from local storage only — used once the thread is already
  /// open and a live event comes in. The live subscription has already
  /// saved that event to `chat.lmdb` by the time it notifies us, so no
  /// relay round-trip is needed here (and re-fetching from relays on every
  /// single incoming message would be wasteful).
  Future<void> _loadHistory() async {
    final gen = ++_historyLoadGeneration;
    const secureStorage = FlutterSecureStorage();
    final mnemonic = await secureStorage.read(key: seedStorageKey);
    if (mnemonic == null || !mounted) return;
    final storageDir = await getApplicationDocumentsDirectory();
    final history = await chat_api.loadChatHistory(
      mnemonic: mnemonic,
      storageDir: storageDir.path,
      friendPubkey: widget.friend.pubkey,
    );
    if (!mounted) return;
    final merged = await _mergeWithRatchetHistory(history);
    if (!mounted || gen != _historyLoadGeneration) return;
    setState(() => _messages = merged);
    _scrollToBottom();
    _prefetchNewMessages(_messages, mnemonic, storageDir.path);
    await chat_api.markThreadRead(
      storageDir: storageDir.path,
      friendPubkey: widget.friend.pubkey,
    );
    unawaited(publishAccountReadStateBackup());
  }

  /// Merges this device's forward-secret history (see `ratchet.rs`'s
  /// module doc — it can't be re-derived from `chat.lmdb`/mnemonic like
  /// everything else, so it's stored and loaded separately) into `base`,
  /// oldest first, and records which ids are forward-secret for the lock
  /// badge.
  Future<List<chat_api.ChatMessage>> _mergeWithRatchetHistory(
    List<chat_api.ChatMessage> base,
  ) async {
    final ratchetKey = await getOrCreateRatchetKey();
    final storageDir = await getApplicationDocumentsDirectory();
    if (!mounted) return base;
    final ratchetMessages = await ratchet_api.loadRatchetHistory(
      storageDir: storageDir.path,
      localKey: ratchetKey,
      friendPubkey: widget.friend.pubkey,
    );
    if (ratchetMessages.isEmpty) return base;
    final converted = ratchetMessages
        .map(
          (m) => chat_api.ChatMessage(
            id: m.id,
            senderPubkey: m.isMine ? '' : widget.friend.pubkey,
            content: m.content,
            createdAt: m.createdAt,
            isMine: m.isMine,
            isEdited: m.isEdited,
            isDeleted: m.isDeleted,
            replyTo: m.replyTo,
            attachment: null,
          ),
        )
        .toList();
    if (mounted) {
      setState(() => _forwardSecretIds = {..._forwardSecretIds, ...converted.map((m) => m.id)});
    }
    final merged = [...base, ...converted];
    merged.sort((a, b) => a.createdAt.toInt().compareTo(b.createdAt.toInt()));
    return merged;
  }

  Future<void> _openProfile(BuildContext context) async {
    final removed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => FriendProfileScreen(
          friend: widget.friend,
          onToggleFavorite: widget.onToggleFavorite,
          onBlockFriend: _handleBlock,
          onUnblockFriend: _handleUnblock,
          onClearChat: widget.onClearChat,
          messageEvents: widget.messageEvents,
        ),
      ),
    );
    if (removed == true && context.mounted) Navigator.of(context).pop();
  }

  Future<void> _clearChat(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.clearChatConfirmTitle),
        content: Text(l10n.clearChatConfirmBody(_friend.displayName)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(
              MaterialLocalizations.of(dialogContext).cancelButtonLabel,
            ),
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
    await widget.onClearChat(widget.friend);
    if (!context.mounted) return;
    // Invalidates any reconcile fetch already in flight from before the
    // clear, the same way sending a message does — otherwise a stale
    // fetchChatHistoryPage/loadChatHistory result that started before the
    // clear could still land afterward and repopulate `_messages` with
    // messages the user just cleared.
    ++_historyLoadGeneration;
    setState(() => _messages = []);
    Navigator.of(context).pop();
  }

  void _scrollToBottom() {
    // With the list reversed, offset 0 *is* the bottom (newest message) —
    // no need to wait for a layout pass to know maxScrollExtent.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.jumpTo(0);
    });
  }

  /// Asks whether to unblock so the pending message can go out — shown
  /// when the user tries to send while [_isBlocked] is true, rather than
  /// silently failing (the Rust side also rejects the send either way).
  Future<bool> _confirmUnblockToSend() async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.blockedSendConfirmTitle),
        content: Text(l10n.blockedSendConfirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(
              MaterialLocalizations.of(dialogContext).cancelButtonLabel,
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.unblockFriend),
          ),
        ],
      ),
    );
    if (confirmed != true) return false;
    await _handleUnblock(widget.friend);
    return true;
  }

  Future<void> _send() async {
    if (_sending) return;
    final text = _messageController.text.trim();
    final hasAttachment = _pendingAttachmentPath != null;
    if (!hasAttachment && (text.isEmpty || text.runes.length > _maxMessageChars)) {
      return;
    }
    if (hasAttachment && text.runes.length > _maxMessageChars) return;
    if (_isBlocked) {
      final unblocked = await _confirmUnblockToSend();
      if (!unblocked || !mounted) return;
    }
    FocusScope.of(context).unfocus();
    setState(() => _sending = true);
    const secureStorage = FlutterSecureStorage();
    final mnemonic = await secureStorage.read(key: seedStorageKey);
    if (mnemonic == null) {
      if (mounted) setState(() => _sending = false);
      return;
    }
    final storageDir = await getApplicationDocumentsDirectory();
    if (hasAttachment) {
      await _sendPendingAttachment(mnemonic, storageDir.path, text);
    } else if (_friendHasRatchetDevice) {
      // Forward secrecy is used automatically whenever the friend has an
      // announced device — no self-echo, so this device is the only one
      // that will ever see it (see `ratchet.rs`'s module doc).
      try {
        final ratchetKey = await getOrCreateRatchetKey();
        await ratchet_api.sendRatchetMessage(
          mnemonic: mnemonic,
          storageDir: storageDir.path,
          friendPubkey: widget.friend.pubkey,
          localKey: ratchetKey,
          content: text,
          replyTo: _replyingTo?.id,
        );
        _messageController.clear();
        setState(() => _replyingTo = null);
        await _loadHistory();
      } catch (_) {
        // Offline or every relay unreachable — leave the draft in the
        // field so the user can retry.
      }
    } else {
      try {
        await chat_api.sendChatMessage(
          mnemonic: mnemonic,
          storageDir: storageDir.path,
          friendPubkey: widget.friend.pubkey,
          message: text,
          replyTo: _replyingTo?.id,
        );
        _messageController.clear();
        setState(() => _replyingTo = null);
        await _loadHistory();
      } catch (_) {
        // Offline or every relay unreachable — leave the draft in the
        // field so the user can retry.
      }
    }
    if (!mounted) return;
    setState(() => _sending = false);
  }

  /// Uploads [_pendingAttachmentPath] (staged by [_pickAttachment]),
  /// listening to the progress stream to drive the composer's donut
  /// indicator, and sends [caption] alongside it in the same bubble.
  Future<void> _sendPendingAttachment(
    String mnemonic,
    String storageDir,
    String caption,
  ) async {
    final path = _pendingAttachmentPath!;
    final mimeType = _pendingAttachmentMimeType ?? 'application/octet-stream';
    String? serverOverride;
    while (true) {
      setState(() => _uploadProgress = 0.0);
      final events = attachment_api.sendChatAttachment(
        mnemonic: mnemonic,
        storageDir: storageDir,
        friendPubkey: widget.friend.pubkey,
        filePath: path,
        mimeType: mimeType,
        caption: caption.isEmpty ? null : caption,
        replyTo: _replyingTo?.id,
        serverOverride: serverOverride,
      );
      attachment_api.AttachmentUploadEvent? finalEvent;
      await for (final event in events) {
        if (!mounted) return;
        if (event.done) {
          finalEvent = event;
          break;
        }
        setState(() => _uploadProgress = event.fraction);
      }
      if (!mounted) return;
      setState(() => _uploadProgress = null);
      if (finalEvent?.error == null) {
        _messageController.clear();
        setState(() {
          _replyingTo = null;
          _pendingAttachmentPath = null;
          _pendingAttachmentName = null;
          _pendingAttachmentMimeType = null;
        });
        await _loadHistory();
        return;
      }

      String triedServer;
      if (serverOverride != null) {
        triedServer = serverOverride;
      } else {
        final servers = await attachment_api.loadUploadServers(storageDir: storageDir);
        triedServer = servers.defaultUrl;
      }
      if (!mounted) return;
      final nextServer = await _promptServerSwitch(storageDir, triedServer);
      if (!mounted) return;
      if (nextServer == null) {
        final l10n = AppLocalizations.of(context)!;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${l10n.attachmentUploadFailedLabel}: ${finalEvent!.error}')),
        );
        return;
      }
      serverOverride = nextServer;
      // Loop again and retry the upload against nextServer — if that also
      // fails, the dialog is shown again with the next candidate.
    }
  }

  /// Shown after a failed upload: offers to retry against the next
  /// configured server (cycling past [triedServer]), with a checkbox to
  /// also make that server the new default. Returns the server to retry
  /// with, or null if the user declined / there's nothing else to try.
  Future<String?> _promptServerSwitch(String storageDir, String triedServer) async {
    final list = await attachment_api.loadUploadServers(storageDir: storageDir);
    if (!mounted || list.urls.length < 2) return null;
    final triedIndex = list.urls.indexOf(triedServer);
    final candidate = list.urls[(triedIndex < 0 ? 0 : triedIndex + 1) % list.urls.length];
    if (candidate == triedServer) return null;

    final l10n = AppLocalizations.of(context)!;
    var setDefault = false;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: OrigilinkColors.background,
          title: Text(l10n.attachmentServerSwitchTitle),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.attachmentServerSwitchBody(candidate)),
              CheckboxListTile(
                value: setDefault,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: Text(l10n.attachmentServerSetDefaultCheckbox),
                onChanged: (value) => setDialogState(() => setDefault = value ?? false),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(MaterialLocalizations.of(dialogContext).cancelButtonLabel),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(l10n.attachmentServerSwitchButton),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted) return null;
    if (setDefault) {
      await attachment_api.saveUploadServers(
        storageDir: storageDir,
        urls: list.urls,
        defaultUrl: candidate,
      );
    }
    return candidate;
  }

  /// Opens the OS file picker and stages the choice — the actual upload
  /// happens when the send button is pressed (see [_sendPendingAttachment]),
  /// so a caption can be typed alongside it first.
  Future<void> _pickAttachment() async {
    if (_sending) return;
    final l10n = AppLocalizations.of(context)!;
    final storageDir = await getApplicationDocumentsDirectory();
    final servers = await attachment_api.loadUploadServers(
      storageDir: storageDir.path,
    );
    if (!mounted) return;
    if (servers.urls.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.attachmentServerNotConfigured)));
      return;
    }
    if (_isBlocked) {
      final unblocked = await _confirmUnblockToSend();
      if (!unblocked || !mounted) return;
    }
    FocusScope.of(context).unfocus();
    final result = await FilePicker.platform.pickFiles();
    final file = result?.files.single;
    if (file?.path == null || !mounted) return;
    setState(() {
      _pendingAttachmentPath = file!.path;
      _pendingAttachmentName = file.name;
      _pendingAttachmentMimeType = lookupMimeType(file.path!) ?? 'application/octet-stream';
    });
  }

  void _removePendingAttachment() {
    setState(() {
      _pendingAttachmentPath = null;
      _pendingAttachmentName = null;
      _pendingAttachmentMimeType = null;
    });
  }

  /// Long-press on one of our own bubbles: shows edit/unsend, same
  /// long-press-then-menu pattern as the Talk tab's "clear chat". Edit and
  /// unsend only make sense for our own messages (they publish a signed
  /// instruction the friend's side authenticates against the original
  /// sender); "hide for me" is local-only, so it's offered for either
  /// side's messages.
  Future<void> _showMessageMenu(chat_api.ChatMessage message) async {
    if (message.isDeleted) return;
    final l10n = AppLocalizations.of(context)!;
    final action = await showDialog<String>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.of(dialogContext).pop('reply'),
            child: Row(
              children: [
                const Icon(Icons.reply, color: OrigilinkColors.textSecondary),
                const SizedBox(width: 12),
                Text(l10n.replyToMessage),
              ],
            ),
          ),
          if (message.isMine) ...[
            if (message.attachment == null ||
                (message.attachment!.caption ?? '').isNotEmpty)
              SimpleDialogOption(
                onPressed: () => Navigator.of(dialogContext).pop('edit'),
                child: Row(
                  children: [
                    const Icon(
                      Icons.edit_outlined,
                      color: OrigilinkColors.textSecondary,
                    ),
                    const SizedBox(width: 12),
                    Text(l10n.editMessage),
                  ],
                ),
              ),
            SimpleDialogOption(
              onPressed: () => Navigator.of(dialogContext).pop('unsend'),
              child: Row(
                children: [
                  const Icon(Icons.delete_outline, color: Colors.redAccent),
                  const SizedBox(width: 12),
                  Text(
                    l10n.unsendMessage,
                    style: const TextStyle(color: Colors.redAccent),
                  ),
                ],
              ),
            ),
          ],
          SimpleDialogOption(
            onPressed: () => Navigator.of(dialogContext).pop('hide'),
            child: Row(
              children: [
                const Icon(
                  Icons.visibility_off_outlined,
                  color: OrigilinkColors.textSecondary,
                ),
                const SizedBox(width: 12),
                Text(l10n.hideMessage),
              ],
            ),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (action == 'reply') {
      setState(() => _replyingTo = message);
    } else if (action == 'edit') {
      await _editMessage(message);
    } else if (action == 'unsend') {
      await _unsendMessage(message);
    } else if (action == 'hide') {
      await _hideMessage(message);
    }
  }

  Future<void> _hideMessage(chat_api.ChatMessage message) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.hideMessageConfirmTitle),
        content: Text(l10n.hideMessageConfirmBody(_friend.displayName)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(
              MaterialLocalizations.of(dialogContext).cancelButtonLabel,
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.hideMessage),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final storageDir = await getApplicationDocumentsDirectory();
    if (_forwardSecretIds.contains(message.id)) {
      final ratchetKey = await getOrCreateRatchetKey();
      if (!mounted) return;
      await ratchet_api.hideRatchetMessage(
        storageDir: storageDir.path,
        localKey: ratchetKey,
        messageId: message.id,
      );
      await _loadHistory();
      return;
    }
    const secureStorage = FlutterSecureStorage();
    final mnemonic = await secureStorage.read(key: seedStorageKey);
    if (mnemonic == null) return;
    await chat_api.hideMessage(
      mnemonic: mnemonic,
      storageDir: storageDir.path,
      friendPubkey: widget.friend.pubkey,
      messageId: message.id,
    );
    await _loadHistory();
  }

  Future<void> _editMessage(chat_api.ChatMessage message) async {
    final l10n = AppLocalizations.of(context)!;
    final controller = TextEditingController(
      text: message.attachment?.caption ?? message.content,
    );
    final newContent = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.editMessageTitle),
        content: TextField(
          controller: controller,
          autofocus: true,
          minLines: 1,
          maxLines: 5,
          maxLength: _maxMessageChars,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(
              MaterialLocalizations.of(dialogContext).cancelButtonLabel,
            ),
          ),
          TextButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(controller.text.trim()),
            child: Text(l10n.confirmButton),
          ),
        ],
      ),
    );
    final originalContent = message.attachment?.caption ?? message.content;
    if (newContent == null || newContent.isEmpty || newContent == originalContent) {
      return;
    }
    if (!mounted) return;
    final storageDir = await getApplicationDocumentsDirectory();
    try {
      if (_forwardSecretIds.contains(message.id)) {
        const secureStorage = FlutterSecureStorage();
        final mnemonic = await secureStorage.read(key: seedStorageKey);
        if (mnemonic == null) return;
        final ratchetKey = await getOrCreateRatchetKey();
        if (!mounted) return;
        await ratchet_api.editRatchetMessage(
          mnemonic: mnemonic,
          storageDir: storageDir.path,
          friendPubkey: widget.friend.pubkey,
          localKey: ratchetKey,
          messageId: message.id,
          newContent: newContent,
        );
      } else {
        const secureStorage = FlutterSecureStorage();
        final mnemonic = await secureStorage.read(key: seedStorageKey);
        if (mnemonic == null) return;
        await chat_api.editChatMessage(
          mnemonic: mnemonic,
          storageDir: storageDir.path,
          friendPubkey: widget.friend.pubkey,
          messageId: message.id,
          content: newContent,
        );
      }
      await _loadHistory();
    } catch (_) {
      // Offline or every relay unreachable — the edit just doesn't apply
      // this time; the bubble keeps showing its original content.
    }
  }

  Future<void> _unsendMessage(chat_api.ChatMessage message) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.unsendMessageConfirmTitle),
        content: Text(l10n.unsendMessageConfirmBody(_friend.displayName)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(
              MaterialLocalizations.of(dialogContext).cancelButtonLabel,
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            child: Text(l10n.unsendMessage),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final storageDir = await getApplicationDocumentsDirectory();
    try {
      if (_forwardSecretIds.contains(message.id)) {
        const secureStorage = FlutterSecureStorage();
        final mnemonic = await secureStorage.read(key: seedStorageKey);
        if (mnemonic == null) return;
        final ratchetKey = await getOrCreateRatchetKey();
        if (!mounted) return;
        await ratchet_api.deleteRatchetMessage(
          mnemonic: mnemonic,
          storageDir: storageDir.path,
          friendPubkey: widget.friend.pubkey,
          localKey: ratchetKey,
          messageId: message.id,
        );
      } else {
        const secureStorage = FlutterSecureStorage();
        final mnemonic = await secureStorage.read(key: seedStorageKey);
        if (mnemonic == null) return;
        await chat_api.deleteChatMessage(
          mnemonic: mnemonic,
          storageDir: storageDir.path,
          friendPubkey: widget.friend.pubkey,
          messageId: message.id,
        );
      }
      await _loadHistory();
    } catch (_) {
      // Offline or every relay unreachable — the message stays as-is.
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final hasAvatar =
        _friend.avatarPath != null && File(_friend.avatarPath!).existsSync();
    final messagesById = {for (final m in _messages) m.id: m};
    return Scaffold(
      backgroundColor: _WaColors.wallpaper,
      appBar: AppBar(
        backgroundColor: OrigilinkColors.background,
        elevation: 0,
        // Material 3's AppBar tints itself darker by default once the body
        // scrolls under it — unrelated to `elevation`, which only affects
        // the shadow. Without this, the bar visibly darkens as soon as the
        // message list isn't scrolled all the way to the top.
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        foregroundColor: OrigilinkColors.textPrimary,
        titleSpacing: 0,
        title: InkWell(
          onTap: () => _openProfile(context),
          child: Row(
            children: [
              CircleAvatar(
                radius: 16,
                backgroundColor: OrigilinkColors.surface,
                backgroundImage: hasAvatar
                    ? FileImage(File(_friend.avatarPath!))
                    : null,
                child: hasAvatar
                    ? null
                    : const Icon(
                        Icons.person_outline,
                        size: 18,
                        color: OrigilinkColors.textSecondary,
                      ),
              ),
              const SizedBox(width: 10),
              Text(_friend.displayName),
            ],
          ),
        ),
        actions: [
          IconButton(
            tooltip: l10n.clearChatButton,
            onPressed: () => _clearChat(context),
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
      body: SafeArea(
        // The bottom inset is handled by the composer's own SafeArea below
        // instead — otherwise this outer SafeArea's bottom padding exposes
        // a strip of the Scaffold's wallpaper background (behind
        // everything) rather than the composer bar's background color.
        bottom: false,
        child: Column(
          children: [
            Expanded(
              child: _messages.isEmpty
                  ? Center(
                      child: Text(
                        l10n.noMessagesYet,
                        style: const TextStyle(
                          color: OrigilinkColors.textSecondary,
                        ),
                      ),
                    )
                  : ScrollConfiguration(
                      // Disables Android's default stretch/glow overscroll
                      // indicator at the top/bottom of the list — purely
                      // cosmetic, unrelated to [_onScroll]'s pagination
                      // trigger.
                      behavior: ScrollConfiguration.of(
                        context,
                      ).copyWith(overscroll: false),
                      child: ListView.builder(
                        controller: _scrollController,
                        // Reversed so the list is anchored at the newest
                        // message from its very first frame — index 0 is the
                        // newest and renders at the visual bottom, growing
                        // upward. Without this, the list initially paints
                        // top-down (oldest first) and only jumps to the
                        // bottom on the next frame via [_scrollToBottom],
                        // which briefly shows old messages before snapping
                        // down.
                        reverse: true,
                        // Default cacheExtent (~250px) only lays out rows
                        // just past the viewport edge — so even with data
                        // (images/previews) already prefetched, the row's
                        // own widget/layout is still built for the first
                        // time right as it scrolls into view, reading as a
                        // last-second pop-in. A few screens' worth of
                        // headroom lets rows get laid out well before
                        // they're actually visible.
                        cacheExtent: 3000,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 12,
                        ),
                        // One extra item at the far end (the top, since the
                        // list is reversed) while [_loadOlderMessages] is
                        // running, showing a spinner above the oldest
                        // currently-loaded message.
                        itemCount: _messages.length + (_loadingOlder ? 1 : 0),
                        itemBuilder: (context, index) {
                          if (index >= _messages.length) {
                            return const Padding(
                              padding: EdgeInsets.symmetric(vertical: 16),
                              child: Center(
                                child: SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                ),
                              ),
                            );
                          }
                          final reversedIndex = _messages.length - 1 - index;
                          // Index-based lookahead: `cacheExtent: 3000` makes
                          // `itemBuilder` run for rows well before they're
                          // actually on screen, so this fires (and, via
                          // [_loadOlderMessages]'s own `_loadingOlder`/
                          // `_hasMoreOlder` guards, safely no-ops when
                          // already satisfied) whenever the buffer above the
                          // built row drops under one page — a directly
                          // known remaining-message count, unlike
                          // [_onScroll]'s pixel-distance guess which can't
                          // tell how many messages that distance represents.
                          // Deferred to a post-frame callback: `itemBuilder`
                          // runs during this list's layout pass, and
                          // [_loadOlderMessages] calls `setState`
                          // synchronously on entry — calling it straight
                          // from here would be `setState` during
                          // build/layout, which Flutter disallows and can
                          // abort the frame, which is exactly what made
                          // scrolling get stuck instead of loading more.
                          if (reversedIndex < _olderPageLimit && !_lookaheadScheduled) {
                            _lookaheadScheduled = true;
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              _lookaheadScheduled = false;
                              if (mounted) unawaited(_loadOlderMessages());
                            });
                          }
                          final message = _messages[reversedIndex];
                          final previous = reversedIndex > 0
                              ? _messages[reversedIndex - 1]
                              : null;
                          final messageDate = DateTime.fromMillisecondsSinceEpoch(
                            message.createdAt.toInt() * 1000,
                          );
                          final previousDate = previous == null
                              ? null
                              : DateTime.fromMillisecondsSinceEpoch(
                                  previous.createdAt.toInt() * 1000,
                                );
                          final isNewDay =
                              previousDate == null ||
                              previousDate.year != messageDate.year ||
                              previousDate.month != messageDate.month ||
                              previousDate.day != messageDate.day;
                          // Discord-style grouping: the avatar/name/time
                          // header belongs on the *first* message of a
                          // consecutive run from the same sender — reset by
                          // a sender change, a day boundary, or too long a
                          // gap (5 min) even from the same sender, so a
                          // header reappears if the conversation resumes
                          // after a while.
                          final startOfGroup =
                              previous == null ||
                              previous.isMine != message.isMine ||
                              isNewDay ||
                              messageDate.difference(previousDate).inMinutes.abs() > 5;
                          final bubble = _MessageBubble(
                            message: message,
                            groupStart: startOfGroup,
                            repliedMessage: message.replyTo != null
                                ? messagesById[message.replyTo]
                                : null,
                            friendAvatarPath: _friend.avatarPath,
                            friendDisplayName: _friend.displayName,
                            friendPubkey: widget.friend.pubkey,
                            myAvatarPath: _myAvatarPath,
                            onAvatarTap: () => _openProfile(context),
                            onLongPress: () => _showMessageMenu(message),
                          );
                          if (!isNewDay) return bubble;
                          return Column(
                            children: [
                              DateDividerChip(date: messageDate),
                              bubble,
                            ],
                          );
                        },
                      ),
                    ),
            ),
            if (_replyingTo != null)
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                color: OrigilinkColors.surface,
                child: Row(
                  children: [
                    Container(width: 3, height: 32, color: _WaColors.bubbleMine),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            l10n.replyingToLabel(
                              _replyingTo!.isMine
                                  ? l10n.youLabel
                                  : _friend.displayName,
                            ),
                            style: const TextStyle(
                              color: OrigilinkColors.textPrimary,
                              fontWeight: FontWeight.w600,
                              fontSize: 13,
                            ),
                          ),
                          Text(
                            _replyingTo!.isDeleted
                                ? l10n.messageUnsentLabel
                                : _replyingTo!.content,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: OrigilinkColors.textSecondary,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(
                        Icons.close,
                        size: 18,
                        color: OrigilinkColors.textSecondary,
                      ),
                      onPressed: () => setState(() => _replyingTo = null),
                    ),
                  ],
                ),
              ),
            if (_pendingAttachmentPath != null)
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                color: OrigilinkColors.surface,
                child: Row(
                  children: [
                    const Icon(
                      Icons.insert_drive_file_outlined,
                      size: 20,
                      color: OrigilinkColors.textSecondary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _pendingAttachmentName ?? '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: OrigilinkColors.textPrimary,
                          fontSize: 13,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(
                        Icons.close,
                        size: 18,
                        color: OrigilinkColors.textSecondary,
                      ),
                      onPressed: _sending ? null : _removePendingAttachment,
                    ),
                  ],
                ),
              ),
            Container(
              // Same wallpaper as the message list (not the darker
              // OrigilinkColors.background) so the composer bar doesn't
              // read as a separately-tinted strip — must be the outer
              // widget so its color fills the SafeArea's bottom inset
              // padding too (see the outer SafeArea's `bottom: false`),
              // not just the padded content inside it.
              color: _WaColors.wallpaper,
              child: SafeArea(
                top: false,
                child: _Composer(
                  controller: _messageController,
                  sending: _sending,
                  uploadProgress: _uploadProgress,
                  onSend: _send,
                  onAttach: _pickAttachment,
                  hint: l10n.typeMessageHint,
                  maxLength: _maxMessageChars,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Discord-style flat row (no bubble background, always left-aligned):
/// avatar/name/time only shown on [groupStart] — a sender's consecutive
/// messages (same day, within 5 minutes, see the caller's `startOfGroup`)
/// share one header instead of repeating it — which reads well at both
/// phone width and, eventually, a wide desktop/web layout, unlike a
/// bubble's fixed max-width. Own messages are told apart purely by the
/// sender name ("You" in an accent color), not by side/background color.
class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.message,
    required this.groupStart,
    required this.repliedMessage,
    required this.friendAvatarPath,
    required this.friendDisplayName,
    required this.friendPubkey,
    required this.myAvatarPath,
    required this.onAvatarTap,
    required this.onLongPress,
  });

  final chat_api.ChatMessage message;
  final bool groupStart;

  /// The message [message.replyTo] points to, already resolved from the
  /// currently-loaded history — null both when there's no reply and when
  /// the original fell outside what's loaded (e.g. hidden, or an older
  /// page that hasn't been paginated in yet).
  final chat_api.ChatMessage? repliedMessage;
  final String? friendAvatarPath;
  final String friendDisplayName;
  final String friendPubkey;

  /// This device's own avatar, shown on the header row of a consecutive
  /// run of own messages — null falls back to the generic person icon,
  /// same as [friendAvatarPath].
  final String? myAvatarPath;
  final VoidCallback onAvatarTap;
  final VoidCallback onLongPress;

  String _formatTime(int epochSeconds) {
    final dt = DateTime.fromMillisecondsSinceEpoch(epochSeconds * 1000);
    final hour = dt.hour.toString().padLeft(2, '0');
    final minute = dt.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final isMine = message.isMine;

    final content = message.isDeleted
        ? Text(
            l10n.messageUnsentLabel,
            style: TextStyle(
              color: OrigilinkColors.textSecondary,
              fontStyle: FontStyle.italic,
              fontSize: 15,
            ),
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (message.replyTo != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // A thin rule rather than a filled box — the quoted
                      // message sits above the actual reply text, set off
                      // just by this line and the sender row, LINE-style.
                      Container(
                        width: 2,
                        margin: const EdgeInsets.only(top: 2, bottom: 2),
                        color: OrigilinkColors.textSecondary.withValues(
                          alpha: 0.4,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (repliedMessage != null)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 2),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    CircleAvatar(
                                      radius: 8,
                                      backgroundColor: OrigilinkColors.surface,
                                      backgroundImage:
                                          !repliedMessage!.isMine &&
                                              friendAvatarPath != null &&
                                              File(
                                                friendAvatarPath!,
                                              ).existsSync()
                                          ? FileImage(File(friendAvatarPath!))
                                          : null,
                                      child:
                                          repliedMessage!.isMine ||
                                              friendAvatarPath == null ||
                                              !File(
                                                friendAvatarPath!,
                                              ).existsSync()
                                          ? const Icon(
                                              Icons.person_outline,
                                              size: 10,
                                              color:
                                                  OrigilinkColors.textSecondary,
                                            )
                                          : null,
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      repliedMessage!.isMine
                                          ? l10n.youLabel
                                          : friendDisplayName,
                                      style: const TextStyle(
                                        color: OrigilinkColors.textSecondary,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            Text(
                              repliedMessage == null
                                  ? l10n.originalMessageUnavailable
                                  : (repliedMessage!.isDeleted
                                        ? l10n.messageUnsentLabel
                                        : repliedMessage!.content),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: OrigilinkColors.textSecondary,
                                fontSize: 13,
                                fontStyle: repliedMessage == null
                                    ? FontStyle.italic
                                    : FontStyle.normal,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              if (message.attachment != null) ...[
                _AttachmentPreview(message: message, friendPubkey: friendPubkey),
                if ((message.attachment!.caption ?? '').isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      message.attachment!.caption!,
                      style: const TextStyle(
                        color: OrigilinkColors.textPrimary,
                        fontSize: 16.5,
                        height: 1.35,
                      ),
                    ),
                  ),
              ] else ...[
                Text.rich(
                  linkifiedSpan(
                    message.content,
                    const TextStyle(
                      color: OrigilinkColors.textPrimary,
                      fontSize: 16.5,
                      height: 1.35,
                    ),
                  ),
                ),
                LinkPreviewCard(key: ValueKey(message.id), text: message.content),
              ],
              if (message.isEdited)
                Text(
                  l10n.messageEditedLabel,
                  style: TextStyle(
                    color: OrigilinkColors.textSecondary.withValues(alpha: 0.8),
                    fontSize: 11,
                  ),
                ),
            ],
          );

    final avatarPath = isMine ? myAvatarPath : friendAvatarPath;
    final hasAvatar = avatarPath != null && File(avatarPath).existsSync();
    final avatarColumn = SizedBox(
      width: 36,
      child: groupStart
          ? GestureDetector(
              onTap: isMine ? null : onAvatarTap,
              child: CircleAvatar(
                radius: 16,
                backgroundColor: OrigilinkColors.surface,
                backgroundImage: hasAvatar ? FileImage(File(avatarPath)) : null,
                child: hasAvatar
                    ? null
                    : const Icon(
                        Icons.person_outline,
                        size: 16,
                        color: OrigilinkColors.textSecondary,
                      ),
              ),
            )
          : null,
    );

    return GestureDetector(
      onLongPress: onLongPress,
      child: Container(
        margin: EdgeInsets.only(top: groupStart ? 12 : 1, bottom: 1),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            avatarColumn,
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (groupStart)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: [
                          Text(
                            isMine ? l10n.youLabel : friendDisplayName,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: isMine
                                  ? OrigilinkColors.primaryDark
                                  : OrigilinkColors.textPrimary,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            _formatTime(message.createdAt.toInt()),
                            style: TextStyle(
                              fontSize: 11,
                              color: OrigilinkColors.textSecondary.withValues(alpha: 0.8),
                            ),
                          ),
                        ],
                      ),
                    ),
                  content,
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Renders [message.attachment]: an inline thumbnail once decrypted (for
/// images), or a tappable filename chip that downloads+decrypts on demand
/// (everything else) — see [attachment_api.downloadChatAttachment]'s doc
/// comment for the decrypt-on-open, cache-after-first-view behavior this
/// mirrors.
class _AttachmentPreview extends StatefulWidget {
  const _AttachmentPreview({required this.message, required this.friendPubkey});

  final chat_api.ChatMessage message;
  final String friendPubkey;

  @override
  State<_AttachmentPreview> createState() => _AttachmentPreviewState();
}

class _AttachmentPreviewState extends State<_AttachmentPreview> {
  bool _loading = false;
  bool _failed = false;
  String? _localPath;

  bool get _isImage =>
      widget.message.attachment?.mimeType.startsWith('image/') ?? false;

  @override
  void initState() {
    super.initState();
    // Images download eagerly so they render inline like a normal chat
    // photo; other file types wait for a tap (see [_download]) rather than
    // silently pulling arbitrary files in the background.
    if (_isImage) _download();
  }

  Future<void> _download() async {
    final attachment = widget.message.attachment;
    if (attachment == null || _loading || _localPath != null) return;
    setState(() {
      _loading = true;
      _failed = false;
    });
    const secureStorage = FlutterSecureStorage();
    final mnemonic = await secureStorage.read(key: seedStorageKey);
    if (mnemonic == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    final storageDir = await getApplicationDocumentsDirectory();
    try {
      final path = await attachment_api.downloadChatAttachment(
        mnemonic: mnemonic,
        storageDir: storageDir.path,
        friendPubkey: widget.friendPubkey,
        messageId: widget.message.id,
        url: attachment.url,
        encKey: attachment.encKey,
      );
      if (!mounted) return;
      setState(() {
        _localPath = path;
        _loading = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _failed = true;
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final attachment = widget.message.attachment;
    if (attachment == null) return const SizedBox.shrink();

    if (_isImage) {
      if (_localPath != null) {
        return ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.file(
            File(_localPath!),
            fit: BoxFit.cover,
            width: 220,
            height: 220,
          ),
        );
      }
      return Container(
        width: 220,
        height: 220,
        decoration: BoxDecoration(
          color: Colors.black26,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Center(
          child: _failed
              ? IconButton(
                  icon: const Icon(Icons.refresh, color: OrigilinkColors.textSecondary),
                  onPressed: _download,
                )
              : const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
        ),
      );
    }

    return InkWell(
      onTap: _localPath == null ? _download : null,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_loading)
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            Icon(
              _localPath != null
                  ? Icons.insert_drive_file_outlined
                  : (_failed ? Icons.error_outline : Icons.download),
              color: OrigilinkColors.textSecondary,
            ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              attachment.filename,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: OrigilinkColors.textPrimary, fontSize: 15),
            ),
          ),
        ],
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.sending,
    required this.uploadProgress,
    required this.onSend,
    required this.onAttach,
    required this.hint,
    required this.maxLength,
  });

  final TextEditingController controller;
  final bool sending;

  /// Non-null while an attachment upload is in flight (`0.0..=1.0`) — shows
  /// a donut progress ring on the send button instead of the send icon.
  final double? uploadProgress;
  final VoidCallback onSend;
  final VoidCallback onAttach;
  final String hint;
  final int maxLength;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final length = controller.text.runes.length;
        final overLimit = length > maxLength;
        final nearLimit = !overLimit && length > maxLength * 0.9;
        final warnColor = overLimit ? Colors.redAccent : Colors.orange;
        return Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Container(
                  constraints: const BoxConstraints(minHeight: 44),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(24),
                    border: (overLimit || nearLimit)
                        ? Border.all(color: warnColor, width: 1.5)
                        : null,
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x11000000),
                        blurRadius: 2,
                        offset: Offset(0, 1),
                      ),
                    ],
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      IconButton(
                        icon: const Icon(
                          Icons.attach_file,
                          color: OrigilinkColors.textSecondary,
                        ),
                        onPressed: sending ? null : onAttach,
                      ),
                      Expanded(
                        child: TextField(
                          controller: controller,
                          minLines: 1,
                          maxLines: 5,
                          maxLength: maxLength,
                          maxLengthEnforcement: MaxLengthEnforcement.none,
                          textInputAction: TextInputAction.send,
                          onSubmitted: (_) => onSend(),
                          decoration: InputDecoration(
                            hintText: hint,
                            border: InputBorder.none,
                            contentPadding: const EdgeInsets.only(
                              right: 14,
                              top: 11,
                              bottom: 11,
                            ),
                            counterText: (overLimit || nearLimit)
                                ? '$length/$maxLength'
                                : '',
                            counterStyle: TextStyle(
                              color: warnColor,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Material(
                color: OrigilinkColors.primaryDark,
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: (sending || overLimit) ? null : onSend,
                  child: Padding(
                    padding: const EdgeInsets.all(11),
                    child: uploadProgress != null
                        ? SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              value: uploadProgress,
                              strokeWidth: 2.5,
                              color: Colors.white,
                              backgroundColor: Colors.white24,
                            ),
                          )
                        : const Icon(Icons.send, color: Colors.white, size: 20),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
