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
import 'package:origilink/src/rust/api/attachment.dart' as attachment_api;
import 'package:origilink/src/rust/api/chat.dart' as chat_api;
import 'package:origilink/src/rust/api/friends.dart' as friends_api;
import 'package:origilink/src/rust/api/ratchet.dart' as ratchet_api;
import 'package:origilink/src/rust/api/sync.dart' as sync_api;
import 'package:origilink/widgets/link_preview_card.dart';

/// WhatsApp-style chat wallpaper and bubble colors, layered on top of the
/// app's greige palette rather than replacing it elsewhere.
class _WaColors {
  static const wallpaper = Color(0xFFE9DFCF);
  static const bubbleMine = Color(0xFFD9C9AC);
  static const bubbleTheirs = Color(0xFFFFFFFF);
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
    required this.onDeleteFriend,
    required this.onClearChat,
  });

  final friends_api.Friend friend;

  /// Live friend-protocol events shared with [HomeScreen]'s subscription —
  /// used to append incoming messages for this friend without polling.
  final Stream<sync_api.FriendEvent>? messageEvents;

  final Future<void> Function(friends_api.Friend friend) onToggleFavorite;
  final Future<void> Function(friends_api.Friend friend) onBlockFriend;
  final Future<void> Function(friends_api.Friend friend) onUnblockFriend;
  final Future<void> Function(friends_api.Friend friend) onDeleteFriend;
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
  static const _initialHistoryLimit = 20;

  /// How many older messages [_loadOlderMessages] fetches per page once the
  /// user scrolls up past what's already loaded.
  static const _olderPageLimit = 20;

  final _messageController = TextEditingController();
  final _scrollController = ScrollController();
  List<chat_api.ChatMessage> _messages = [];
  bool _sending = false;
  bool _loadingOlder = false;
  bool _hasMoreOlder = true;
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

  @override
  void initState() {
    super.initState();
    _loadInitialHistory();
    _subscribe();
    _initForwardSecrecy();
    _scrollController.addListener(_onScroll);
    chat_api.maxMessageChars().then((max) {
      if (mounted) setState(() => _maxMessageChars = max);
    });
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
  Future<void> _loadInitialHistory() async {
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
    if (!mounted) return;
    setState(() {
      _messages = mergedLocal;
      _hasMoreOlder = hasMore;
    });
    _scrollToBottom();

    final synced = await chat_api.fetchChatHistoryPage(
      mnemonic: mnemonic,
      storageDir: storageDir.path,
      friendPubkey: widget.friend.pubkey,
      before: null,
      limit: _initialHistoryLimit,
    );
    if (!mounted) return;
    final mergedSynced = await _mergeWithRatchetHistory(synced);
    if (!mounted) return;
    setState(() => _messages = mergedSynced);
    _scrollToBottom();
    await chat_api.markThreadRead(
      storageDir: storageDir.path,
      friendPubkey: widget.friend.pubkey,
    );
    unawaited(publishAccountReadStateBackup());
  }

  /// Fetches another page of older messages once the user scrolls up past
  /// what's already loaded — same EOSE-gated relay fetch as
  /// [_loadInitialHistory]'s background reconcile, just anchored `before`
  /// the oldest message currently shown instead of the newest overall.
  /// [chat_api.fetchChatHistoryPage] already returns the full merged local
  /// history (not just the new page), so the result can replace
  /// `_messages` outright — no manual prepend/dedupe needed.
  Future<void> _loadOlderMessages() async {
    if (_messages.isEmpty) return;
    setState(() => _loadingOlder = true);
    const secureStorage = FlutterSecureStorage();
    final mnemonic = await secureStorage.read(key: seedStorageKey);
    if (mnemonic == null || !mounted) {
      if (mounted) setState(() => _loadingOlder = false);
      return;
    }
    final storageDir = await getApplicationDocumentsDirectory();
    final oldestBefore = _messages.first.createdAt;
    final merged = await chat_api.fetchChatHistoryPage(
      mnemonic: mnemonic,
      storageDir: storageDir.path,
      friendPubkey: widget.friend.pubkey,
      before: oldestBefore,
      limit: _olderPageLimit,
    );
    if (!mounted) return;
    final gotOlder = merged.isNotEmpty && merged.first.createdAt < oldestBefore;
    setState(() {
      _messages = merged;
      _hasMoreOlder = gotOlder;
      _loadingOlder = false;
    });
  }

  /// Reload from local storage only — used once the thread is already
  /// open and a live event comes in. The live subscription has already
  /// saved that event to `chat.lmdb` by the time it notifies us, so no
  /// relay round-trip is needed here (and re-fetching from relays on every
  /// single incoming message would be wasteful).
  Future<void> _loadHistory() async {
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
    if (!mounted) return;
    setState(() => _messages = merged);
    _scrollToBottom();
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
          onDeleteFriend: widget.onDeleteFriend,
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
                          final message = _messages[reversedIndex];
                          final previous = reversedIndex > 0
                              ? _messages[reversedIndex - 1]
                              : null;
                          final startOfGroup =
                              previous == null ||
                              previous.isMine != message.isMine;
                          // The avatar (and the bubble's pointed "tail"
                          // corner) belongs on the *last* message of a
                          // consecutive run from the same sender — the one
                          // closest to the next group/the composer — not the
                          // first, matching the WhatsApp-style convention
                          // this UI otherwise follows. `startOfGroup` is kept
                          // separately since it still governs the extra gap
                          // above a new group.
                          final next = reversedIndex < _messages.length - 1
                              ? _messages[reversedIndex + 1]
                              : null;
                          final endOfGroup =
                              next == null || next.isMine != message.isMine;
                          return _MessageBubble(
                            message: message,
                            showTail: endOfGroup,
                            topGap: startOfGroup,
                            repliedMessage: message.replyTo != null
                                ? messagesById[message.replyTo]
                                : null,
                            friendAvatarPath: _friend.avatarPath,
                            friendDisplayName: _friend.displayName,
                            friendPubkey: widget.friend.pubkey,
                            onAvatarTap: () => _openProfile(context),
                            onLongPress: () => _showMessageMenu(message),
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
              // Matches the AppBar's background instead of inheriting the
              // chat wallpaper color behind it, so the bar framing the
              // message list top and bottom is visually consistent — must
              // be the outer widget so its color fills the SafeArea's
              // bottom inset padding too (see the outer SafeArea's
              // `bottom: false`), not just the padded content inside it.
              color: OrigilinkColors.background,
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

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.message,
    required this.showTail,
    required this.topGap,
    required this.repliedMessage,
    required this.friendAvatarPath,
    required this.friendDisplayName,
    required this.friendPubkey,
    required this.onAvatarTap,
    required this.onLongPress,
  });

  final chat_api.ChatMessage message;
  final bool showTail;
  final bool topGap;

  /// The message [message.replyTo] points to, already resolved from the
  /// currently-loaded history — null both when there's no reply and when
  /// the original fell outside what's loaded (e.g. hidden, or an older
  /// page that hasn't been paginated in yet).
  final chat_api.ChatMessage? repliedMessage;
  final String? friendAvatarPath;
  final String friendDisplayName;
  final String friendPubkey;
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
    final bubbleColor = isMine ? _WaColors.bubbleMine : _WaColors.bubbleTheirs;
    final radius = const Radius.circular(12);
    final tailRadius = const Radius.circular(2);

    final bubbleContent = message.isDeleted
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
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    // Row defaults to MainAxisSize.max (always fills
                    // available width) and Expanded always claims all
                    // remaining space regardless of content — either alone
                    // would force every reply-quoting bubble to the full
                    // maxWidth even for a one-word message. `min` + a
                    // loose-fit Flexible below let the row (and so the
                    // bubble) shrink to whatever the quoted text actually
                    // needs, only growing up to maxWidth when it must wrap.
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

    final bubble = GestureDetector(
      onLongPress: onLongPress,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.7,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: bubbleColor,
          borderRadius: BorderRadius.only(
            topLeft: radius,
            topRight: radius,
            bottomLeft: !isMine && showTail ? tailRadius : radius,
            bottomRight: isMine && showTail ? tailRadius : radius,
          ),
          boxShadow: const [
            BoxShadow(
              color: Color(0x14000000),
              blurRadius: 1,
              offset: Offset(0, 1),
            ),
          ],
        ),
        child: bubbleContent,
      ),
    );

    final time = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Text(
        _formatTime(message.createdAt.toInt()),
        style: TextStyle(
          fontSize: 11,
          color: OrigilinkColors.textSecondary.withValues(alpha: 0.8),
        ),
      ),
    );

    final hasAvatar =
        friendAvatarPath != null && File(friendAvatarPath!).existsSync();
    final avatar = SizedBox(
      width: 28,
      height: 28,
      child: showTail
          ? GestureDetector(
              onTap: onAvatarTap,
              child: CircleAvatar(
                radius: 14,
                backgroundColor: OrigilinkColors.surface,
                backgroundImage: hasAvatar
                    ? FileImage(File(friendAvatarPath!))
                    : null,
                child: hasAvatar
                    ? null
                    : const Icon(
                        Icons.person_outline,
                        size: 14,
                        color: OrigilinkColors.textSecondary,
                      ),
              ),
            )
          : null,
    );

    return Container(
      margin: EdgeInsets.only(
        top: topGap ? 6 : 2,
        bottom: 2,
        left: isMine ? 40 : 4,
        right: isMine ? 4 : 40,
      ),
      child: Row(
        mainAxisAlignment: isMine
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.max,
        // The bubble's `maxWidth` constraint (70% of screen width) is only
        // an upper bound — without wrapping it in Flexible, the Row treats
        // it as wanting exactly that width regardless of the avatar/time
        // siblings also taking up space, which overflows on narrower
        // screens once the bubble padding/font grew. Flexible lets it
        // shrink below its max and wrap its text into more lines instead.
        children: isMine
            ? [time, Flexible(child: bubble)]
            : [avatar, const SizedBox(width: 4), Flexible(child: bubble), time],
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
              IconButton(
                icon: const Icon(
                  Icons.attach_file,
                  color: OrigilinkColors.textSecondary,
                ),
                onPressed: sending ? null : onAttach,
              ),
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
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 11,
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
