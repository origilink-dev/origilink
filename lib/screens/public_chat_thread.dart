import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:origilink/l10n/app_localizations.dart';
import 'package:origilink/screens/login.dart';
import 'package:origilink/screens/logout.dart' show seedStorageKey;
import 'package:origilink/src/rust/api/public_chat.dart' as public_chat_api;
import 'package:origilink/src/rust/api/relay.dart' as relay_api;

/// A NIP-28 channel's message timeline. Unlike 1:1/group chat there's no
/// live subscription wired up for channels yet — messages are (re)loaded on
/// open, pull-to-refresh, and right after sending, rather than a
/// `Timer.periodic` poll (never do that — see `chat_list.dart`/`home.dart`
/// history for why: it's wasted work and the wrong fix for staleness).
class PublicChatThreadScreen extends StatefulWidget {
  const PublicChatThreadScreen({super.key, required this.channel});

  final public_chat_api.PublicChannel channel;

  @override
  State<PublicChatThreadScreen> createState() => _PublicChatThreadScreenState();
}

class _PublicChatThreadScreenState extends State<PublicChatThreadScreen> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  List<public_chat_api.PublicChannelMessage> _messages = [];
  String? _myPubkey;
  bool _loading = true;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<List<String>> _relayUrls() async {
    final storageDir = await getApplicationDocumentsDirectory();
    final relayList = await relay_api.loadRelayList(storageDir: storageDir.path);
    return relayList.urls;
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    const secureStorage = FlutterSecureStorage();
    final mnemonic = await secureStorage.read(key: seedStorageKey);
    final relayUrls = await _relayUrls();
    final results = await Future.wait([
      public_chat_api.loadChannelMessages(relayUrls: relayUrls, channelId: widget.channel.id),
      if (mnemonic != null) public_chat_api.publicChatIdentityPubkey(mnemonic: mnemonic),
    ]);
    if (!mounted) return;
    setState(() {
      _messages = results[0] as List<public_chat_api.PublicChannelMessage>;
      _myPubkey = mnemonic != null ? results[1] as String : null;
      _loading = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
    });
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    const secureStorage = FlutterSecureStorage();
    final mnemonic = await secureStorage.read(key: seedStorageKey);
    if (mnemonic != null) {
      await public_chat_api.sendChannelMessage(
        mnemonic: mnemonic,
        relayUrls: await _relayUrls(),
        channelId: widget.channel.id,
        content: text,
      );
      _controller.clear();
      await _load();
    }
    if (!mounted) return;
    setState(() => _sending = false);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      backgroundColor: OrigilinkColors.background,
      appBar: AppBar(
        backgroundColor: OrigilinkColors.background,
        elevation: 0,
        title: Text(widget.channel.name.isEmpty ? l10n.untitledChannel : widget.channel.name),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
        ],
      ),
      body: Column(
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
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.all(16),
                    itemCount: _messages.length,
                    itemBuilder: (context, index) {
                      final message = _messages[index];
                      final isMine = message.senderPubkey == _myPubkey;
                      return Align(
                        alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
                        child: Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                          constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
                          decoration: BoxDecoration(
                            color: isMine ? OrigilinkColors.primaryDark : OrigilinkColors.surface,
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (!isMine)
                                Text(
                                  '${message.senderPubkey.substring(0, 8)}…',
                                  style: const TextStyle(fontSize: 11, color: OrigilinkColors.textSecondary),
                                ),
                              Text(
                                message.content,
                                style: TextStyle(color: isMine ? Colors.white : OrigilinkColors.textPrimary),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      decoration: InputDecoration(
                        hintText: l10n.typeChannelMessageHint,
                        filled: true,
                        fillColor: OrigilinkColors.surface,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      ),
                      onSubmitted: (_) => _send(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    icon: _sending
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.send),
                    onPressed: _sending ? null : _send,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
