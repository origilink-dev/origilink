import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MaxLengthEnforcement;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:origilink/l10n/app_localizations.dart';
import 'package:origilink/screens/login.dart';
import 'package:origilink/screens/logout.dart' show seedStorageKey;
import 'package:origilink/src/rust/api/global_chat.dart' as global_chat_api;
import 'package:origilink/src/rust/api/relay.dart' as relay_api;
import 'package:origilink/widgets/relative_date.dart';
import 'package:origilink/widgets/link_preview_card.dart';

/// Same wallpaper background as `chat_thread.dart`'s private `_WaColors` —
/// duplicated rather than shared since it's one color constant, not worth
/// a cross-file dependency for.
class _WaColors {
  static const wallpaper = Color(0xFFFAF8F4);
}

/// A NIP-28 channel's message timeline: an initial page loads on open, a
/// live subscription (`global_chat.rs`'s `subscribeChannelMessages`) then
/// streams anything sent after that point — same shape as 1:1/group chat's
/// `messageEvents`, just scoped to one channel instead of every friend —
/// so there's no manual refresh button needed. Scrolling up past what's
/// loaded fetches another page of history, mirroring `chat_thread.dart`'s
/// `_loadOlderMessages`. Visually matches `chat_thread.dart`'s 1:1 thread
/// (wallpaper, bubble shapes/colors, composer bar) so Public Chat doesn't
/// look like a different app bolted on.
class GlobalChatThreadScreen extends StatefulWidget {
  const GlobalChatThreadScreen({super.key, required this.channel});

  final global_chat_api.GlobalChannel channel;

  @override
  State<GlobalChatThreadScreen> createState() => _GlobalChatThreadScreenState();
}

class _GlobalChatThreadScreenState extends State<GlobalChatThreadScreen> {
  /// Same small-page-plus-primed-next-page pattern as `chat_thread.dart`'s
  /// `_initialHistoryLimit`/`_olderPageLimit` — was a fixed 200 messages
  /// per page, which made even opening a channel for the first time slow
  /// (200 messages' worth of relay round-trips before anything showed).
  static const _pageLimit = 15;

  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  List<global_chat_api.GlobalChannelMessage> _messages = [];
  Map<String, global_chat_api.GlobalChatProfile> _profiles = {};
  final _seenMessageIds = <String>{};
  String? _myPubkey;
  List<String> _relayUrls = [];
  bool _loading = true;
  bool _loadingOlder = false;
  bool _hasMoreOlder = true;
  bool _sending = false;
  StreamSubscription<global_chat_api.GlobalChannelMessage>? _liveSub;

  /// Same coalescing guard as `chat_thread.dart`'s field of the same
  /// name — see its doc comment.
  bool _lookaheadScheduled = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _load();
  }

  @override
  void dispose() {
    _liveSub?.cancel();
    _controller.dispose();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  /// Same "reversed list, nearing maxScrollExtent means nearing the oldest
  /// loaded message" trigger as `chat_thread.dart`'s `_onScroll`.
  void _onScroll() {
    if (!_scrollController.hasClients || _loadingOlder || !_hasMoreOlder) return;
    final position = _scrollController.position;
    if (position.maxScrollExtent <= 0) return;
    if (position.pixels >= position.maxScrollExtent - 200) {
      _loadOlderMessages();
    }
  }

  Future<List<String>> _loadRelayUrls() async {
    final storageDir = await getApplicationDocumentsDirectory();
    final relayList = await relay_api.loadRelayList(storageDir: storageDir.path);
    return relayList.urls;
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    const secureStorage = FlutterSecureStorage();
    final mnemonic = await secureStorage.read(key: seedStorageKey);
    final relayUrls = await _loadRelayUrls();
    final results = await Future.wait([
      global_chat_api.loadChannelMessages(
        relayUrls: relayUrls,
        channelId: widget.channel.id,
        before: null,
        limit: _pageLimit,
      ),
      if (mnemonic != null) global_chat_api.globalChatIdentityPubkey(mnemonic: mnemonic),
    ]);
    if (!mounted) return;
    final messages = results[0] as List<global_chat_api.GlobalChannelMessage>;
    _seenMessageIds
      ..clear()
      ..addAll(messages.map((m) => m.id));
    setState(() {
      _messages = messages;
      _myPubkey = mnemonic != null ? results[1] as String : null;
      _relayUrls = relayUrls;
      // A full page came back, so there's likely more/older history;
      // anything short of that means this is everything there is.
      _hasMoreOlder = messages.length >= _pageLimit;
      _loading = false;
    });
    _loadProfilesFor(messages);
    _subscribeLive();
    // Newest first — see `chat_thread.dart`'s `_prefetchNewMessages` doc
    // comment on why iteration order determines who wins the shared
    // prefetch semaphore's limited concurrent slots.
    prefetchLinkPreviews(messages.reversed.map((m) => m.content), persist: false);
    // Prime one page of older messages immediately, before the user has
    // scrolled at all — see `chat_thread.dart`'s `_initialHistoryLimit` doc
    // comment for why.
    unawaited(_loadOlderMessages());
  }

  /// [prime] loads are the one-page lookahead this fires on itself once a
  /// real (scroll-triggered) page finishes — so there's always a second
  /// page already sitting in `_messages` by the time the user scrolls into
  /// what was just the first one, instead of only ever keeping exactly one
  /// page of buffer above the viewport (which meant a relay round-trip was
  /// on the critical path of every single scroll near the top). Priming
  /// calls don't themselves prime further — that would chain into loading
  /// the entire channel history up front, defeating pagination entirely.
  Future<void> _loadOlderMessages({bool prime = false}) async {
    if (_messages.isEmpty || _loadingOlder || !_hasMoreOlder) return;
    setState(() => _loadingOlder = true);
    final oldest = _messages.first;
    final older = await global_chat_api.loadChannelMessages(
      relayUrls: _relayUrls,
      channelId: widget.channel.id,
      before: oldest.createdAt,
      limit: _pageLimit,
    );
    if (!mounted) return;
    final newOnes = older.where((m) => _seenMessageIds.add(m.id)).toList();
    setState(() {
      _messages = [...newOnes, ..._messages];
      _hasMoreOlder = older.length >= _pageLimit;
      _loadingOlder = false;
    });
    // Newest-of-this-batch first — same reasoning as `_load`'s call.
    prefetchLinkPreviews(newOnes.reversed.map((m) => m.content), persist: false);
    _loadProfilesFor(newOnes);
    if (!prime && _hasMoreOlder) {
      unawaited(_loadOlderMessages(prime: true));
    }
    // A `ListView` content change alone doesn't re-fire the scroll-position
    // listener, so if the user kept scrolling while this page loaded and
    // is already back within the trigger threshold, re-check now instead
    // of stalling until they nudge the list again. Deferred to the
    // post-frame callback since `setState` above only schedules the
    // rebuild — checking synchronously here would still see the old,
    // pre-insert `maxScrollExtent` and could wrongly find nothing to do.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _onScroll();
    });
  }

  /// Sender display names/avatars are a nice-to-have, not blocking —
  /// fetched after the messages themselves render so a slow/unreachable
  /// relay for kind-0 metadata never delays showing the conversation.
  Future<void> _loadProfilesFor(List<global_chat_api.GlobalChannelMessage> messages) async {
    final missing = messages.map((m) => m.senderPubkey).where((pk) => !_profiles.containsKey(pk)).toSet().toList();
    if (missing.isEmpty) return;
    final profiles = await global_chat_api.loadProfiles(relayUrls: _relayUrls, pubkeys: missing);
    if (!mounted || profiles.isEmpty) return;
    setState(() => _profiles = {..._profiles, for (final p in profiles) p.pubkey: p});
    // Same idea as `prefetchLinkPreviews`/`_prefetchAttachments`: without
    // this, each sender's avatar `Image` only starts downloading once its
    // `_ChannelMessageBubble` actually builds, popping in after the fact.
    for (final p in profiles) {
      final picture = p.picture;
      if (picture != null) unawaited(precacheNetworkImageLimited(picture));
    }
  }

  /// Streams anything sent after [_load] ran — replaces the old manual
  /// refresh button. Re-subscribing (rather than reusing one subscription
  /// forever) after every full [_load] keeps the "since" cutoff aligned
  /// with whatever page was just fetched.
  void _subscribeLive() {
    _liveSub?.cancel();
    _liveSub = global_chat_api
        .subscribeChannelMessages(relayUrls: _relayUrls, channelId: widget.channel.id)
        .listen((message) {
          if (!_seenMessageIds.add(message.id)) return;
          setState(() => _messages = [..._messages, message]);
          _loadProfilesFor([message]);
        });
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    const secureStorage = FlutterSecureStorage();
    final mnemonic = await secureStorage.read(key: seedStorageKey);
    if (mnemonic != null) {
      await global_chat_api.sendChannelMessage(
        mnemonic: mnemonic,
        relayUrls: _relayUrls,
        channelId: widget.channel.id,
        content: text,
      );
      _controller.clear();
    }
    if (!mounted) return;
    setState(() => _sending = false);
  }

  String _formatTime(int epochSeconds) {
    final dt = DateTime.fromMillisecondsSinceEpoch(epochSeconds * 1000);
    final hour = dt.hour.toString().padLeft(2, '0');
    final minute = dt.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      backgroundColor: _WaColors.wallpaper,
      appBar: AppBar(
        backgroundColor: OrigilinkColors.background,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        foregroundColor: OrigilinkColors.textPrimary,
        titleSpacing: 0,
        title: Row(
          children: [
            const CircleAvatar(
              radius: 16,
              backgroundColor: OrigilinkColors.surface,
              child: Icon(Icons.tag, size: 18, color: OrigilinkColors.textSecondary),
            ),
            const SizedBox(width: 10),
            Text(widget.channel.name.isEmpty ? l10n.untitledChannel : widget.channel.name),
          ],
        ),
      ),
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _messages.isEmpty
                  ? Center(
                      child: Text(
                        l10n.noChannelMessagesYet,
                        style: const TextStyle(color: OrigilinkColors.textSecondary),
                      ),
                    )
                  : ScrollConfiguration(
                      behavior: ScrollConfiguration.of(context).copyWith(overscroll: false),
                      child: ListView.builder(
                        controller: _scrollController,
                        reverse: true,
                        // See `chat_thread.dart`'s identical `cacheExtent` —
                        // lays rows out well before they scroll into view so
                        // prefetched images/previews don't still pop in late
                        // just because the row itself was only just built.
                        cacheExtent: 3000,
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                        itemCount: _messages.length + (_loadingOlder ? 1 : 0),
                        itemBuilder: (context, index) {
                          if (index >= _messages.length) {
                            return const Padding(
                              padding: EdgeInsets.symmetric(vertical: 16),
                              child: Center(
                                child: SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                ),
                              ),
                            );
                          }
                          // `_messages` is oldest-first; the reversed list
                          // needs newest-first indexing.
                          final reversedIndex = _messages.length - 1 - index;
                          // Index-based lookahead: `cacheExtent: 3000` makes
                          // `itemBuilder` run for rows well before they're
                          // actually on screen, so this fires (and, via
                          // [_loadOlderMessages]'s own guards, safely no-ops
                          // when already satisfied) whenever the buffer
                          // above the built row drops under one page — a
                          // directly known remaining-message count, unlike
                          // [_onScroll]'s pixel-distance guess. Deferred to
                          // a post-frame callback: `itemBuilder` runs during
                          // this list's layout pass, and
                          // [_loadOlderMessages] calls `setState`
                          // synchronously on entry — calling it straight
                          // from here would be `setState` during
                          // build/layout, which Flutter disallows and can
                          // abort the frame, which is exactly what made
                          // scrolling get stuck instead of loading more.
                          if (reversedIndex < _pageLimit && !_lookaheadScheduled) {
                            _lookaheadScheduled = true;
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              _lookaheadScheduled = false;
                              if (mounted) unawaited(_loadOlderMessages());
                            });
                          }
                          final message = _messages[reversedIndex];
                          final isMine = message.senderPubkey == _myPubkey;
                          final messageDate = DateTime.fromMillisecondsSinceEpoch(
                            message.createdAt.toInt() * 1000,
                          );
                          final previous = reversedIndex > 0 ? _messages[reversedIndex - 1] : null;
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
                          // Discord-style grouping (see `chat_thread.dart`'s
                          // `_MessageBubble` doc) — a channel can have many
                          // senders, so grouping matters even more here.
                          final groupStart =
                              previous == null ||
                              previous.senderPubkey != message.senderPubkey ||
                              isNewDay ||
                              messageDate.difference(previousDate).inMinutes.abs() > 5;
                          final bubble = _ChannelMessageBubble(
                            message: message,
                            isMine: isMine,
                            groupStart: groupStart,
                            profile: _profiles[message.senderPubkey],
                            formatTime: _formatTime,
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
            _Composer(
              controller: _controller,
              sending: _sending,
              onSend: _send,
              hint: l10n.typeChannelMessageHint,
            ),
          ],
        ),
      ),
    );
  }
}

/// Discord-style flat row, matching `chat_thread.dart`'s `_MessageBubble` —
/// no bubble background, always left-aligned, avatar/name/time shown only
/// on [groupStart]. A channel can have many distinct senders interleaved
/// (unlike 1:1, which only ever alternates between two), so grouping and
/// clear per-message attribution matter even more here.
class _ChannelMessageBubble extends StatelessWidget {
  const _ChannelMessageBubble({
    required this.message,
    required this.isMine,
    required this.groupStart,
    required this.profile,
    required this.formatTime,
  });

  final global_chat_api.GlobalChannelMessage message;
  final bool isMine;
  final bool groupStart;

  /// This sender's NIP-01 profile, when `load_profiles` found one — null
  /// falls back to a truncated pubkey and a generic person icon, same as
  /// before profile lookup existed.
  final global_chat_api.GlobalChatProfile? profile;
  final String Function(int) formatTime;

  @override
  Widget build(BuildContext context) {
    final senderName = isMine
        ? AppLocalizations.of(context)!.youLabel
        : (profile?.name ?? '${message.senderPubkey.substring(0, 8)}…');

    final avatarColumn = SizedBox(
      width: 36,
      child: groupStart
          ? CircleAvatar(
              radius: 16,
              backgroundColor: OrigilinkColors.surface,
              backgroundImage: profile?.picture != null ? NetworkImage(profile!.picture!) : null,
              onBackgroundImageError: profile?.picture != null ? (_, __) {} : null,
              child: profile?.picture != null
                  ? null
                  : const Icon(Icons.person_outline, size: 16, color: OrigilinkColors.textSecondary),
            )
          : null,
    );

    return Container(
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
                          senderName,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: isMine ? OrigilinkColors.primaryDark : OrigilinkColors.textPrimary,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          formatTime(message.createdAt.toInt()),
                          style: TextStyle(
                            fontSize: 11,
                            color: OrigilinkColors.textSecondary.withValues(alpha: 0.8),
                          ),
                        ),
                      ],
                    ),
                  ),
                Text.rich(
                  linkifiedSpan(
                    message.content,
                    const TextStyle(color: OrigilinkColors.textPrimary, fontSize: 16.5, height: 1.35),
                  ),
                ),
                LinkPreviewCard(key: ValueKey(message.id), text: message.content, persistCache: false),
              ],
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
    required this.onSend,
    required this.hint,
  });

  final TextEditingController controller;
  final bool sending;
  final VoidCallback onSend;
  final String hint;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
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
                  boxShadow: const [
                    BoxShadow(color: Color(0x11000000), blurRadius: 2, offset: Offset(0, 1)),
                  ],
                ),
                child: TextField(
                  controller: controller,
                  minLines: 1,
                  maxLines: 5,
                  maxLengthEnforcement: MaxLengthEnforcement.none,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => onSend(),
                  decoration: InputDecoration(
                    hintText: hint,
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
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
                onTap: sending ? null : onSend,
                child: Padding(
                  padding: const EdgeInsets.all(11),
                  child: sending
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(Icons.send, color: Colors.white, size: 20),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
