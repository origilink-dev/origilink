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
/// `client` tag, see `public_chat.rs`'s module doc). The origilink-only
/// vs. all-channels toggle and the "create channel" action live in
/// `home.dart`'s shared top bar (alongside settings) rather than a
/// per-tab AppBar, so this widget is controlled from there: `origilinkOnly`
/// is passed in, and channel creation is triggered via `createChannel()`
/// through `publicChatListKey`.
class PublicChatListTab extends StatefulWidget {
  const PublicChatListTab({super.key, required this.origilinkOnly});

  final bool origilinkOnly;

  @override
  State<PublicChatListTab> createState() => PublicChatListTabState();
}

class PublicChatListTabState extends State<PublicChatListTab> {
  /// Every channel found on the configured relays, unfiltered — fetched
  /// once and re-filtered locally by [_visibleChannels] whenever
  /// `origilinkOnly` flips, since `list_channels` doesn't take that flag
  /// (see its doc comment): the relay query is identical either way, only
  /// which of the results get shown differs. Toggling the switch is
  /// instant with no relay round-trip as a result.
  List<public_chat_api.PublicChannel> _allChannels = [];
  bool _loading = true;

  List<public_chat_api.PublicChannel> get _visibleChannels =>
      widget.origilinkOnly ? _allChannels.where((c) => c.isOrigilink).toList() : _allChannels;

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
    final channels = await public_chat_api.listChannels(relayUrls: await _relayUrls());
    if (!mounted) return;
    setState(() {
      _allChannels = channels;
      _loading = false;
    });
  }

  Future<void> createChannel() async {
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
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final visibleChannels = _visibleChannels;
    if (visibleChannels.isEmpty) {
      return RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            SizedBox(
              height: 320,
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
                      l10n.noChannelsYet,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                        color: OrigilinkColors.textSecondary,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: 4),
        itemCount: visibleChannels.length,
        separatorBuilder: (context, index) => const Divider(
          height: 1,
          indent: 82,
          color: Color(0x14000000),
        ),
        itemBuilder: (context, index) {
          final channel = visibleChannels[index];
          return InkWell(
            onTap: () => _openChannel(channel),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
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
                        if (channel.about.isNotEmpty) ...[
                          const SizedBox(height: 3),
                          Text(
                            channel.about,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: OrigilinkColors.textSecondary),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
