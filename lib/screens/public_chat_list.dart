import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:origilink/l10n/app_localizations.dart';
import 'package:origilink/screens/login.dart';
import 'package:origilink/screens/logout.dart' show seedStorageKey;
import 'package:origilink/screens/public_chat_thread.dart';
import 'package:origilink/src/rust/api/public_chat.dart' as public_chat_api;
import 'package:origilink/src/rust/api/relay.dart' as relay_api;

/// Public chat tab body shown inside the home screen's bottom navigation.
/// Lists NIP-28 channels visible on the configured relays — everyone on
/// the same relays can browse and post, no friendship or invite required.
/// Defaults to showing only channels this app created (tagged with a
/// `client` tag, see `public_chat.rs`'s module doc) — the toggle in the
/// top-left switches to every NIP-28 channel on those relays, since a
/// channel isn't actually walled off from other Nostr clients.
class PublicChatListTab extends StatefulWidget {
  const PublicChatListTab({super.key});

  @override
  State<PublicChatListTab> createState() => _PublicChatListTabState();
}

class _PublicChatListTabState extends State<PublicChatListTab> {
  List<public_chat_api.PublicChannel> _channels = [];
  bool _loading = true;
  bool _origilinkOnly = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<List<String>> _relayUrls() async {
    final storageDir = await getApplicationDocumentsDirectory();
    final relayList = await relay_api.loadRelayList(storageDir: storageDir.path);
    return relayList.urls;
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final channels = await public_chat_api.listChannels(
      relayUrls: await _relayUrls(),
      origilinkOnly: _origilinkOnly,
    );
    if (!mounted) return;
    setState(() {
      _channels = channels;
      _loading = false;
    });
  }

  Future<void> _createChannel() async {
    final l10n = AppLocalizations.of(context)!;
    final nameController = TextEditingController();
    final aboutController = TextEditingController();
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.newChannelTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: InputDecoration(labelText: l10n.channelNameLabel),
              autofocus: true,
            ),
            TextField(
              controller: aboutController,
              decoration: InputDecoration(labelText: l10n.channelAboutLabel),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.cancelButton),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.createButton),
          ),
        ],
      ),
    );
    if (result != true || nameController.text.trim().isEmpty) return;
    if (!mounted) return;

    const secureStorage = FlutterSecureStorage();
    final mnemonic = await secureStorage.read(key: seedStorageKey);
    if (mnemonic == null) return;
    await public_chat_api.createChannel(
      mnemonic: mnemonic,
      relayUrls: await _relayUrls(),
      name: nameController.text.trim(),
      about: aboutController.text.trim(),
    );
    await _load();
  }

  void _openChannel(public_chat_api.PublicChannel channel) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => PublicChatThreadScreen(channel: channel)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      backgroundColor: OrigilinkColors.background,
      appBar: AppBar(
        backgroundColor: OrigilinkColors.background,
        elevation: 0,
        automaticallyImplyLeading: false,
        // Origilink-only vs. every NIP-28 channel toggle — top-left, per
        // request, rather than the usual top-right action-icon convention.
        leading: IconButton(
          tooltip: _origilinkOnly ? l10n.showAllChannelsTooltip : l10n.showOrigilinkChannelsTooltip,
          icon: Icon(_origilinkOnly ? Icons.filter_alt : Icons.filter_alt_off),
          onPressed: () {
            setState(() => _origilinkOnly = !_origilinkOnly);
            _load();
          },
        ),
        title: Text(_origilinkOnly ? l10n.origilinkChannelsTitle : l10n.allChannelsTitle),
        actions: [
          IconButton(icon: const Icon(Icons.add), onPressed: _createChannel),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: _channels.isEmpty
                  ? ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: [
                        SizedBox(
                          height: 320,
                          child: Center(
                            child: Text(
                              l10n.noChannelsYet,
                              style: const TextStyle(color: OrigilinkColors.textSecondary),
                            ),
                          ),
                        ),
                      ],
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.all(16),
                      itemCount: _channels.length,
                      itemBuilder: (context, index) {
                        final channel = _channels[index];
                        return Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          decoration: BoxDecoration(
                            color: OrigilinkColors.surface,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: ListTile(
                            title: Text(
                              channel.name.isEmpty ? l10n.untitledChannel : channel.name,
                            ),
                            subtitle: channel.about.isEmpty ? null : Text(channel.about),
                            onTap: () => _openChannel(channel),
                          ),
                        );
                      },
                    ),
            ),
    );
  }
}
