import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:mime/mime.dart';
import 'package:path_provider/path_provider.dart';
import 'package:origilink/l10n/app_localizations.dart';
import 'package:origilink/screens/login.dart';
import 'package:origilink/screens/logout.dart' show seedStorageKey;
import 'package:origilink/services/ratchet_key.dart';
import 'package:origilink/src/rust/api/attachment.dart' as attachment_api;
import 'package:origilink/src/rust/api/friends.dart' as friends_api;
import 'package:origilink/src/rust/api/groups.dart' as groups_api;
import 'package:origilink/src/rust/api/keys.dart' as keys_api;
import 'package:origilink/src/rust/api/sync.dart' as sync_api;
import 'package:origilink/widgets/link_preview_card.dart' show withPrefetchLimit;
import 'package:origilink/widgets/relative_date.dart';

/// A group's message thread — a deliberately simpler cousin of
/// [ChatThreadScreen]: no edit/unsend/reply, since group delivery (see
/// `groups.rs`'s module doc) is already its own trade-off on top of the
/// 1:1 transport. Forward secrecy *is* available per-member, automatically,
/// the same way 1:1 chat gets it — see `sendGroupMessage`'s `ratchetKey`
/// argument below. Attachments (images/files) are supported, delivered the
/// same way a text message is — see `groups.rs`'s `send_group_attachment`.
class GroupThreadScreen extends StatefulWidget {
  const GroupThreadScreen({super.key, required this.group, required this.messageEvents});

  final groups_api.Group group;
  final Stream<sync_api.FriendEvent>? messageEvents;

  @override
  State<GroupThreadScreen> createState() => _GroupThreadScreenState();
}

class _GroupThreadScreenState extends State<GroupThreadScreen> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  List<groups_api.GroupChatMessage> _messages = [];
  groups_api.Group _group;
  bool _sending = false;
  StreamSubscription<sync_api.FriendEvent>? _sub;

  /// Unlike `chat_thread.dart`/`global_chat_thread.dart`, group message
  /// history has no relay round-trip to page through — `loadGroupMessages`
  /// already reads everything for this group from local storage in one
  /// (cheap) call, see `groups.rs`'s module doc on group delivery. But
  /// rendering the full list into the `ListView` regardless still meant
  /// building every message in a long-lived group's history up front; this
  /// windows the same already-loaded `_messages` down to just its tail,
  /// widening by [_pageSize] as the user scrolls up toward older messages
  /// — same visible pagination behavior as the other two threads, just
  /// slicing already-in-memory data instead of fetching more of it.
  static const _pageSize = 30;
  int _visibleCount = _pageSize;

  /// Ids already handed to [_prefetchAttachments] — same purpose as
  /// `chat_thread.dart`'s `_prefetchedMessageIds`: [_load] re-reads and
  /// re-sets the entire `_messages` list on every reload (a live event, an
  /// expanded [_visibleCount], ...), so without this every reload would
  /// re-issue a prefetch for every image ever seen in this group, not just
  /// newly-visible ones.
  final _prefetchedMessageIds = <String>{};

  /// Same coalescing guard as `chat_thread.dart`'s field of the same
  /// name — see its doc comment.
  bool _lookaheadScheduled = false;

  String? _pendingAttachmentPath;
  String? _pendingAttachmentName;
  String? _pendingAttachmentMimeType;
  double? _uploadProgress;

  _GroupThreadScreenState() : _group = groups_api.Group(id: '', name: '', members: const [], createdAt: 0);

  @override
  void initState() {
    super.initState();
    _group = widget.group;
    _load();
    _sub = widget.messageEvents?.listen((event) {
      if ((event.kind == 'group_message' || event.kind == 'group_invite') &&
          event.pubkey == widget.group.id) {
        _load();
        _reloadGroup();
      }
    });
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _sub?.cancel();
    _controller.dispose();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  /// Same reversed-list trigger as `chat_thread.dart`'s `_onScroll` — see
  /// its doc comment. The list here is reversed too (see the
  /// `ListView.builder` below) specifically so widening [_visibleCount]
  /// doesn't shift the user's current scroll position: a non-reversed list
  /// has no stable anchor when items are prepended (the newly-visible
  /// older messages would push everything below them down by their height,
  /// making `pixels` point at different content than before), whereas a
  /// reversed list's anchor (offset 0) stays pinned to the newest message
  /// regardless of how much history is now visible above it.
  void _onScroll() {
    if (!_scrollController.hasClients || _visibleCount >= _messages.length) return;
    final position = _scrollController.position;
    if (position.maxScrollExtent <= 0) return;
    if (position.pixels >= position.maxScrollExtent - 200) {
      _expandVisibleWindow();
    }
  }

  void _expandVisibleWindow() {
    if (!mounted || _visibleCount >= _messages.length) return;
    setState(() => _visibleCount = (_visibleCount + _pageSize).clamp(0, _messages.length));
    _prefetchVisibleAttachments();
  }

  /// Same idea as `chat_thread.dart`'s `_prefetchAttachments`: fires off
  /// (and ignores the result of) a download for every image attachment
  /// currently within [_visibleCount], so `_GroupAttachmentPreview`'s own
  /// eager download (see its `initState`) just hits an already-warm cache
  /// instead of starting cold once its row actually builds. Newest-first
  /// (the tail of `_messages`, reversed) for the same reason as
  /// `chat_thread.dart`'s `_prefetchNewMessages` — the newest messages are
  /// the ones on/near screen right now, so they should win
  /// [_fetchSemaphore]'s limited concurrent slots over older ones still
  /// further up the (widening) visible window.
  void _prefetchVisibleAttachments() {
    final visible = _messages.length <= _visibleCount ? _messages : _messages.sublist(_messages.length - _visibleCount);
    final newOnes = visible.reversed.where((m) => _prefetchedMessageIds.add(m.id));
    for (final message in newOnes) {
      final attachment = message.attachment;
      if (attachment == null || !attachment.mimeType.startsWith('image/')) continue;
      unawaited(
        withPrefetchLimit(() async {
          final storageDir = await getApplicationDocumentsDirectory();
          try {
            await groups_api.downloadGroupAttachment(
              storageDir: storageDir.path,
              groupId: widget.group.id,
              messageId: message.id,
              url: attachment.url,
              encKey: attachment.encKey,
            );
          } catch (_) {
            // Swallowed — `_GroupAttachmentPreview`'s own download attempt
            // (and can report failure for) the same attachment later.
          }
        }),
      );
    }
  }

  Future<void> _load() async {
    const secureStorage = FlutterSecureStorage();
    final mnemonic = await secureStorage.read(key: seedStorageKey);
    if (mnemonic == null) return;
    final storageDir = await getApplicationDocumentsDirectory();
    final messages = await groups_api.loadGroupMessages(
      mnemonic: mnemonic,
      storageDir: storageDir.path,
      groupId: widget.group.id,
    );
    if (!mounted) return;
    setState(() => _messages = messages);
    _prefetchVisibleAttachments();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Reversed list: offset 0 is the bottom (newest message).
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(0);
      }
    });
  }

  /// Re-reads this group's roster from local storage — used after a member
  /// list change (own edit, or a roster event received live) so the member
  /// count in the app bar and the member-list sheet stay current.
  Future<void> _reloadGroup() async {
    final storageDir = await getApplicationDocumentsDirectory();
    final groups = await groups_api.loadGroups(storageDir: storageDir.path);
    final updated = groups.where((g) => g.id == widget.group.id).firstOrNull;
    if (updated != null && mounted) {
      setState(() => _group = updated);
    }
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    final hasAttachment = _pendingAttachmentPath != null;
    if (!hasAttachment && text.isEmpty) return;
    if (_sending) return;
    setState(() => _sending = true);
    const secureStorage = FlutterSecureStorage();
    final mnemonic = await secureStorage.read(key: seedStorageKey);
    if (mnemonic == null) {
      setState(() => _sending = false);
      return;
    }
    final storageDir = await getApplicationDocumentsDirectory();
    final ratchetKey = await getOrCreateRatchetKey();
    try {
      if (hasAttachment) {
        await _sendPendingAttachment(mnemonic, storageDir.path, ratchetKey, text);
      } else {
        await groups_api.sendGroupMessage(
          mnemonic: mnemonic,
          storageDir: storageDir.path,
          groupId: widget.group.id,
          content: text,
          ratchetKey: ratchetKey,
        );
      }
      _controller.clear();
      await _load();
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _sendPendingAttachment(
    String mnemonic,
    String storageDir,
    String? ratchetKey,
    String caption,
  ) async {
    final path = _pendingAttachmentPath!;
    final mimeType = _pendingAttachmentMimeType ?? 'application/octet-stream';
    setState(() => _uploadProgress = 0.0);
    final events = groups_api.sendGroupAttachment(
      mnemonic: mnemonic,
      storageDir: storageDir,
      groupId: widget.group.id,
      filePath: path,
      mimeType: mimeType,
      caption: caption.isEmpty ? null : caption,
      ratchetKey: ratchetKey,
    );
    attachment_api.AttachmentUploadEvent? finalEvent;
    await for (final event in events) {
      if (!mounted) break;
      setState(() => _uploadProgress = event.fraction);
      if (event.done) {
        finalEvent = event;
        break;
      }
    }
    if (!mounted) return;
    setState(() => _uploadProgress = null);
    if (finalEvent?.error == null) {
      setState(() {
        _pendingAttachmentPath = null;
        _pendingAttachmentName = null;
        _pendingAttachmentMimeType = null;
      });
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Upload failed: ${finalEvent!.error}')));
    }
  }

  Future<void> _pickAttachment() async {
    final result = await FilePicker.platform.pickFiles();
    final file = result?.files.singleOrNull;
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

  Future<void> _openMemberList() async {
    const secureStorage = FlutterSecureStorage();
    final mnemonic = await secureStorage.read(key: seedStorageKey);
    if (mnemonic == null || !mounted) return;
    final storageDir = await getApplicationDocumentsDirectory();
    final selfUid = await keys_api.getAccountUid(mnemonic: mnemonic);
    final friends = await friends_api.loadFriends(storageDir: storageDir.path);
    final friendUids = friends.map((f) => f.uid).toSet();
    if (!mounted) return;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => _MemberListSheet(
        group: _group,
        selfUid: selfUid,
        friendUids: friendUids,
        onRemove: (uid) => _removeMember(uid),
        onLeave: () => _leaveGroup(sheetContext),
      ),
    );
  }

  Future<void> _removeMember(String memberUid) async {
    const secureStorage = FlutterSecureStorage();
    final mnemonic = await secureStorage.read(key: seedStorageKey);
    if (mnemonic == null) return;
    final storageDir = await getApplicationDocumentsDirectory();
    final ratchetKey = await getOrCreateRatchetKey();
    final updated = await groups_api.removeGroupMember(
      mnemonic: mnemonic,
      storageDir: storageDir.path,
      groupId: widget.group.id,
      memberUid: memberUid,
      ratchetKey: ratchetKey,
    );
    if (!mounted) return;
    setState(() => _group = updated);
  }

  Future<void> _leaveGroup(BuildContext sheetContext) async {
    const secureStorage = FlutterSecureStorage();
    final mnemonic = await secureStorage.read(key: seedStorageKey);
    if (mnemonic == null) return;
    final storageDir = await getApplicationDocumentsDirectory();
    final ratchetKey = await getOrCreateRatchetKey();
    await groups_api.leaveGroup(
      mnemonic: mnemonic,
      storageDir: storageDir.path,
      groupId: widget.group.id,
      ratchetKey: ratchetKey,
    );
    if (sheetContext.mounted) Navigator.of(sheetContext).pop();
    if (mounted) {
      // Pop the thread itself back to the group list — the group no longer
      // exists locally, same convention `home.dart` follows after any
      // roster-affecting action.
      Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      backgroundColor: const Color(0xFFFAF8F4),
      appBar: AppBar(
        backgroundColor: OrigilinkColors.background,
        elevation: 0,
        foregroundColor: OrigilinkColors.textPrimary,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_group.name),
            Text(
              l10n.groupMembersCount(_group.members.length),
              style: const TextStyle(fontSize: 12, color: OrigilinkColors.textSecondary),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.people_outline),
            onPressed: _openMemberList,
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: _messages.isEmpty
                  ? Center(
                      child: Text(
                        l10n.noMessagesYet,
                        style: const TextStyle(color: OrigilinkColors.textSecondary),
                      ),
                    )
                  : Builder(
                      builder: (context) {
                        final visible = _messages.length <= _visibleCount
                            ? _messages
                            : _messages.sublist(_messages.length - _visibleCount);
                        return ListView.builder(
                          controller: _scrollController,
                          reverse: true,
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                          itemCount: visible.length,
                          itemBuilder: (context, index) {
                            final reversedIndex = visible.length - 1 - index;
                            // Index-based lookahead, same reasoning as
                            // `chat_thread.dart`'s: widens the visible
                            // window once the buffer above the built row
                            // drops under one page. Deferred to a
                            // post-frame callback since `itemBuilder` runs
                            // during this list's layout pass and
                            // `setState` can't be called synchronously
                            // from there.
                            if (reversedIndex < _pageSize && !_lookaheadScheduled) {
                              _lookaheadScheduled = true;
                              WidgetsBinding.instance.addPostFrameCallback((_) {
                                _lookaheadScheduled = false;
                                _expandVisibleWindow();
                              });
                            }
                            final m = visible[reversedIndex];
                            final previous = reversedIndex > 0 ? visible[reversedIndex - 1] : null;
                            final messageDate = DateTime.fromMillisecondsSinceEpoch(
                              m.createdAt.toInt() * 1000,
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
                            // Discord-style grouping (see
                            // `chat_thread.dart`'s `_MessageBubble` doc) —
                            // a group can have many senders, so grouping
                            // matters even more here.
                            final groupStart =
                                previous == null ||
                                previous.senderUid != m.senderUid ||
                                isNewDay ||
                                messageDate.difference(previousDate).inMinutes.abs() > 5;
                            final row = _GroupMessageRow(
                              message: m,
                              groupId: widget.group.id,
                              groupStart: groupStart,
                            );
                            if (!isNewDay) return row;
                            return Column(children: [DateDividerChip(date: messageDate), row]);
                          },
                        );
                      },
                    ),
            ),
            if (_pendingAttachmentPath != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
                child: Row(
                  children: [
                    const Icon(Icons.insert_drive_file_outlined, size: 18, color: OrigilinkColors.textSecondary),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        _pendingAttachmentName ?? '',
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12, color: OrigilinkColors.textSecondary),
                      ),
                    ),
                    if (_uploadProgress != null)
                      SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2, value: _uploadProgress),
                      )
                    else
                      IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: _sending ? null : _removePendingAttachment,
                      ),
                  ],
                ),
              ),
            Padding(
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
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.attach_file, color: OrigilinkColors.textSecondary),
                            onPressed: _sending ? null : _pickAttachment,
                          ),
                          Expanded(
                            child: TextField(
                              controller: _controller,
                              minLines: 1,
                              maxLines: 5,
                              textInputAction: TextInputAction.send,
                              onSubmitted: (_) => _send(),
                              decoration: InputDecoration(
                                hintText: l10n.typeMessageHint,
                                border: InputBorder.none,
                                contentPadding: const EdgeInsets.only(right: 14, top: 11, bottom: 11),
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
                      onTap: _sending ? null : _send,
                      child: const Padding(
                        padding: EdgeInsets.all(11),
                        child: Icon(Icons.send, color: Colors.white, size: 20),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Discord-style flat row, matching `chat_thread.dart`'s `_MessageBubble`
/// and `global_chat_thread.dart`'s `_ChannelMessageBubble` — no bubble
/// background, always left-aligned, avatar/name/time shown only on
/// [groupStart]. Groups have no per-member avatar image (see
/// `_MemberListSheet`), so the avatar is an initial-letter circle instead.
class _GroupMessageRow extends StatelessWidget {
  const _GroupMessageRow({required this.message, required this.groupId, required this.groupStart});

  final groups_api.GroupChatMessage message;
  final String groupId;
  final bool groupStart;

  String _formatTime(int epochSeconds) {
    final dt = DateTime.fromMillisecondsSinceEpoch(epochSeconds * 1000);
    final hour = dt.hour.toString().padLeft(2, '0');
    final minute = dt.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final senderName = message.isMine ? l10n.youLabel : message.senderName;

    final avatarColumn = SizedBox(
      width: 36,
      child: groupStart
          ? CircleAvatar(
              radius: 16,
              backgroundColor: OrigilinkColors.primary,
              child: Text(
                senderName.isNotEmpty ? senderName[0].toUpperCase() : '?',
                style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600),
              ),
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
                            color: message.isMine
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
                if (message.attachment != null) ...[
                  _GroupAttachmentPreview(groupId: groupId, message: message),
                  if ((message.attachment!.caption ?? '').isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        message.attachment!.caption!,
                        style: const TextStyle(
                          color: OrigilinkColors.textPrimary,
                          fontSize: 16.5,
                          height: 1.35,
                        ),
                      ),
                    ),
                ] else
                  Text(
                    message.content,
                    style: const TextStyle(color: OrigilinkColors.textPrimary, fontSize: 16.5, height: 1.35),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Bottom sheet listing [group]'s members: display name, whether they're a
/// 1:1 friend vs group-only contact, and whether their direct routing
/// (`group_pubkey`/`device_pubkey`) is established yet. Offers a remove
/// action per non-self member and a "leave group" action.
class _MemberListSheet extends StatelessWidget {
  const _MemberListSheet({
    required this.group,
    required this.selfUid,
    required this.friendUids,
    required this.onRemove,
    required this.onLeave,
  });

  final groups_api.Group group;
  final String selfUid;
  final Set<String> friendUids;
  final void Function(String memberUid) onRemove;
  final VoidCallback onLeave;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Members (${group.members.length})',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.5),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: group.members.length,
                itemBuilder: (context, index) {
                  final member = group.members[index];
                  final isSelf = member.uid == selfUid;
                  final isFriend = friendUids.contains(member.uid);
                  final routingEstablished = member.groupPubkey != null || member.devicePubkey != null;
                  return ListTile(
                    leading: CircleAvatar(
                      backgroundColor: OrigilinkColors.primary,
                      child: Text(
                        member.displayName.isNotEmpty ? member.displayName[0].toUpperCase() : '?',
                        style: const TextStyle(color: Colors.white),
                      ),
                    ),
                    title: Text(member.displayName.isEmpty ? member.uid : member.displayName),
                    subtitle: Text(
                      [
                        isSelf ? 'You' : (isFriend ? 'Friend' : 'Group-only contact'),
                        routingEstablished ? 'Routing established' : 'Routing pending',
                      ].join(' • '),
                      style: const TextStyle(fontSize: 12, color: OrigilinkColors.textSecondary),
                    ),
                    trailing: isSelf
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.person_remove_outlined, color: Colors.redAccent),
                            onPressed: () => onRemove(member.uid),
                          ),
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: onLeave,
              icon: const Icon(Icons.logout, color: Colors.redAccent),
              label: const Text('Leave group', style: TextStyle(color: Colors.redAccent)),
            ),
          ],
        ),
      ),
    );
  }
}

/// Renders a group message's attachment — mirrors `chat_thread.dart`'s
/// `_AttachmentPreview`, but downloads via `downloadGroupAttachment` (no
/// friend pubkey / NIP-44 unwrap needed — see that function's doc comment).
class _GroupAttachmentPreview extends StatefulWidget {
  const _GroupAttachmentPreview({required this.groupId, required this.message});

  final String groupId;
  final groups_api.GroupChatMessage message;

  @override
  State<_GroupAttachmentPreview> createState() => _GroupAttachmentPreviewState();
}

class _GroupAttachmentPreviewState extends State<_GroupAttachmentPreview> {
  bool _loading = false;
  bool _failed = false;
  String? _localPath;

  bool get _isImage => widget.message.attachment?.mimeType.startsWith('image/') ?? false;

  @override
  void initState() {
    super.initState();
    if (_isImage) _download();
  }

  Future<void> _download() async {
    final attachment = widget.message.attachment;
    if (attachment == null || _loading || _localPath != null) return;
    setState(() {
      _loading = true;
      _failed = false;
    });
    final storageDir = await getApplicationDocumentsDirectory();
    try {
      final path = await groups_api.downloadGroupAttachment(
        storageDir: storageDir.path,
        groupId: widget.groupId,
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
        decoration: BoxDecoration(color: Colors.black26, borderRadius: BorderRadius.circular(8)),
        child: Center(
          child: _failed
              ? IconButton(
                  icon: const Icon(Icons.refresh, color: OrigilinkColors.textSecondary),
                  onPressed: _download,
                )
              : const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2)),
        ),
      );
    }

    return InkWell(
      onTap: _localPath == null ? _download : null,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_loading)
            const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
          else
            Icon(
              _localPath != null ? Icons.insert_drive_file_outlined : (_failed ? Icons.error_outline : Icons.download),
              color: OrigilinkColors.textSecondary,
            ),
          const SizedBox(width: 6),
          Flexible(child: Text(attachment.filename, overflow: TextOverflow.ellipsis)),
        ],
      ),
    );
  }
}
