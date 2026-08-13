import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:origilink/l10n/app_localizations.dart';
import 'package:origilink/screens/login.dart';
import 'package:origilink/screens/logout.dart' show seedStorageKey;
import 'package:origilink/screens/global_chat_thread.dart';
import 'package:origilink/screens/global_profile_setup.dart';
import 'package:origilink/src/rust/api/global_chat.dart' as global_chat_api;
import 'package:origilink/src/rust/api/relay.dart' as relay_api;

/// Confirms a Global Profile exists (see `global_chat.rs`'s
/// `has_global_profile`), redirecting to [GlobalProfileSetupScreen] first
/// if not — shared by every entry point that's about to post under the
/// Global identity (creating a channel, sending a message) so none of them
/// silently proceed with an unconfigured identity. Returns whether the
/// caller can proceed.
Future<bool> ensureGlobalProfile(BuildContext context) async {
  final storageDir = await getApplicationDocumentsDirectory();
  final hasProfile = await global_chat_api.hasGlobalProfile(storageDir: storageDir.path);
  if (hasProfile) return true;
  if (!context.mounted) return false;
  await Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => GlobalProfileSetupScreen(onDone: () => Navigator.of(context).pop()),
    ),
  );
  return false;
}

Future<List<String>> _loadRelayUrls() async {
  final storageDir = await getApplicationDocumentsDirectory();
  final relayList = await relay_api.loadRelayList(storageDir: storageDir.path);
  return relayList.urls;
}

/// Creates a brand-new channel (prompting for name/about), after confirming
/// a Global Profile exists. Publishing also auto-joins the channel (see
/// `global_chat.rs`'s `create_channel`), so no separate join step is
/// needed. Returns true if a channel was actually created.
Future<bool> createGlobalChannel(BuildContext context) async {
  if (!await ensureGlobalProfile(context)) return false;
  if (!context.mounted) return false;
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
  if (result != true || nameController.text.trim().isEmpty) return false;
  if (!context.mounted) return false;

  const secureStorage = FlutterSecureStorage();
  final mnemonic = await secureStorage.read(key: seedStorageKey);
  if (mnemonic == null) return false;
  final storageDir = await getApplicationDocumentsDirectory();
  await global_chat_api.createChannel(
    mnemonic: mnemonic,
    storageDir: storageDir.path,
    relayUrls: await _loadRelayUrls(),
    name: nameController.text.trim(),
    about: aboutController.text.trim(),
  );
  return true;
}

/// Browse/search every NIP-28 channel visible on the configured relays —
/// reached from Talk's Global-mode "+" menu, distinct from the Talk list
/// itself (which only shows channels already joined, see
/// `GlobalChatTalkTab`). Opening a channel from here joins it (mirrors
/// `chat_list.dart`'s "opening a friend's thread marks it started"
/// convention), so there's no separate join button.
class GlobalChannelSearchScreen extends StatefulWidget {
  const GlobalChannelSearchScreen({super.key});

  @override
  State<GlobalChannelSearchScreen> createState() => _GlobalChannelSearchScreenState();
}

class _GlobalChannelSearchScreenState extends State<GlobalChannelSearchScreen> {
  List<global_chat_api.GlobalChannel> _allChannels = [];
  bool _loading = true;
  bool _origilinkOnly = true;

  List<global_chat_api.GlobalChannel> get _visibleChannels =>
      _origilinkOnly ? _allChannels.where((c) => c.isOrigilink).toList() : _allChannels;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final channels = await global_chat_api.listChannels(relayUrls: await _loadRelayUrls());
    if (!mounted) return;
    setState(() {
      _allChannels = channels;
      _loading = false;
    });
  }

  Future<void> _openChannel(global_chat_api.GlobalChannel channel) async {
    if (!await ensureGlobalProfile(context)) return;
    if (!mounted) return;
    final storageDir = await getApplicationDocumentsDirectory();
    await global_chat_api.joinChannel(storageDir: storageDir.path, channel: channel);
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => GlobalChatThreadScreen(channel: channel)),
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
        foregroundColor: OrigilinkColors.textPrimary,
        title: Text(l10n.searchChannelsTitle),
        actions: [
          Tooltip(
            message: _origilinkOnly ? l10n.showAllChannelsTooltip : l10n.showOrigilinkChannelsTooltip,
            child: InkWell(
              borderRadius: BorderRadius.circular(20),
              onTap: () => setState(() => _origilinkOnly = !_origilinkOnly),
              child: Transform.scale(
                scale: 0.75,
                child: Switch.adaptive(
                  value: _origilinkOnly,
                  activeThumbColor: OrigilinkColors.primaryDark,
                  onChanged: (value) => setState(() => _origilinkOnly = value),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _visibleChannels.isEmpty
          ? RefreshIndicator(
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
            )
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView.separated(
                padding: const EdgeInsets.symmetric(vertical: 4),
                itemCount: _visibleChannels.length,
                separatorBuilder: (context, index) => const Divider(
                  height: 1,
                  indent: 82,
                  color: Color(0x14000000),
                ),
                itemBuilder: (context, index) {
                  final channel = _visibleChannels[index];
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
            ),
    );
  }
}
