import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:origilink/l10n/app_localizations.dart';
import 'package:origilink/screens/login.dart';
import 'package:origilink/screens/logout.dart' show seedStorageKey;
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

/// Shared "search channels" / "create channel" bottom sheet — the same
/// choice offered from Talk's Global "+" menu, reused as-is by any other
/// Global entry point (e.g. Home's joined-channels section) so the two
/// actions aren't implemented twice. Returns true if a channel was joined
/// (via search) or created, so the caller knows to refresh its list.
Future<bool> showGlobalChannelAddMenu(BuildContext context) async {
  final l10n = AppLocalizations.of(context)!;
  final choice = await showModalBottomSheet<String>(
    context: context,
    backgroundColor: OrigilinkColors.background,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.search),
            title: Text(l10n.searchChannelsTitle),
            onTap: () => Navigator.of(sheetContext).pop('search'),
          ),
          ListTile(
            leading: const Icon(Icons.add_comment_outlined),
            title: Text(l10n.createChannelMenuTitle),
            onTap: () => Navigator.of(sheetContext).pop('create'),
          ),
        ],
      ),
    ),
  );
  if (choice == 'search') {
    if (!context.mounted) return false;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const GlobalChannelSearchScreen()),
    );
    // Search always reloads its own state on channel open (joining); the
    // caller can't tell from here whether a join actually happened, so it
    // conservatively reloads too — cheap (local file read), unlike a relay
    // round-trip.
    return true;
  } else if (choice == 'create') {
    if (!context.mounted) return false;
    return createGlobalChannel(context);
  }
  return false;
}

/// Browse/search every NIP-28 channel visible on the configured relays —
/// reached from Talk's "+" menu, distinct from the Talk list itself (which
/// only shows channels already joined, see `chat_list.dart`'s
/// `ChatListTabState.reloadChannels`). Opening a channel from here joins it
/// (mirrors `chat_list.dart`'s "opening a friend's thread marks it
/// started" convention), so there's no separate join button.
/// Same pill-shaped segmented look as [PrivateGlobalToggle] (Home/Talk's
/// Private/Global switch) — reused here as a mini filter rather than a
/// bare [Switch], so "which channels am I looking at" reads the same way
/// across the app instead of two different toggle idioms for a similar
/// concept.
class _ChannelFilterToggle extends StatelessWidget {
  const _ChannelFilterToggle({required this.origilinkOnly, required this.onChanged});

  final bool origilinkOnly;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: OrigilinkColors.surface,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _segment(l10n.channelFilterOrigilink, selected: origilinkOnly, onTap: () => onChanged(true)),
          _segment(l10n.channelFilterAll, selected: !origilinkOnly, onTap: () => onChanged(false)),
        ],
      ),
    );
  }

  Widget _segment(String label, {required bool selected, required VoidCallback onTap}) {
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? OrigilinkColors.textPrimary : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: selected ? Colors.white : OrigilinkColors.textSecondary,
          ),
        ),
      ),
    );
  }
}

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
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => GlobalChannelPreviewScreen(channel: channel)),
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
          _ChannelFilterToggle(
            origilinkOnly: _origilinkOnly,
            onChanged: (value) => setState(() => _origilinkOnly = value),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _visibleChannels.isEmpty
          ? RefreshIndicator(
              onRefresh: _load,
              child: LayoutBuilder(
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

/// Shown before actually joining a channel found via search — mirrors
/// `friend_profile.dart`'s "view profile, then explicitly press Talk to
/// start chatting" flow, so browsing search results doesn't silently join
/// (and start receiving) every channel tapped along the way.
class GlobalChannelPreviewScreen extends StatefulWidget {
  const GlobalChannelPreviewScreen({super.key, required this.channel});

  final global_chat_api.GlobalChannel channel;

  @override
  State<GlobalChannelPreviewScreen> createState() => _GlobalChannelPreviewScreenState();
}

class _GlobalChannelPreviewScreenState extends State<GlobalChannelPreviewScreen> {
  bool _joining = false;

  /// Joins and returns to wherever this preview was opened from (search
  /// results, Home's Global list, ...) — mirrors `add_friend.dart`'s
  /// send-request flow, which confirms and stays put rather than jumping
  /// straight into the new thread. The channel now shows up in Talk /
  /// Home's Global list like any other joined channel; opening its thread
  /// is a separate, explicit tap from there.
  Future<void> _handleJoin(BuildContext context) async {
    if (!await ensureGlobalProfile(context)) return;
    if (!mounted) return;
    setState(() => _joining = true);
    final storageDir = await getApplicationDocumentsDirectory();
    await global_chat_api.joinChannel(storageDir: storageDir.path, channel: widget.channel);
    if (!context.mounted) return;
    final l10n = AppLocalizations.of(context)!;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.channelAddedMessage)));
    // All the way back to Home (this preview is normally reached via
    // Home's "+" menu → search results → here), not just one level up to
    // the search results screen.
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final channel = widget.channel;
    return Scaffold(
      backgroundColor: OrigilinkColors.background,
      appBar: AppBar(
        backgroundColor: OrigilinkColors.background,
        elevation: 0,
        foregroundColor: OrigilinkColors.textPrimary,
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        children: [
          const SizedBox(height: 12),
          Center(
            child: CircleAvatar(
              radius: 44,
              backgroundColor: OrigilinkColors.surface,
              child: const Icon(Icons.tag, color: OrigilinkColors.textSecondary, size: 36),
            ),
          ),
          const SizedBox(height: 16),
          Center(
            child: Text(
              channel.name.isEmpty ? l10n.untitledChannel : channel.name,
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w600,
                color: OrigilinkColors.textPrimary,
              ),
              textAlign: TextAlign.center,
            ),
          ),
          if (channel.about.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              channel.about,
              style: const TextStyle(color: OrigilinkColors.textSecondary),
              textAlign: TextAlign.center,
            ),
          ],
          const SizedBox(height: 28),
          ElevatedButton.icon(
            onPressed: _joining ? null : () => _handleJoin(context),
            icon: _joining
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : const Icon(Icons.add),
            label: Text(l10n.joinChannelButton),
            style: ElevatedButton.styleFrom(
              backgroundColor: OrigilinkColors.primaryDark,
              foregroundColor: Colors.white,
              minimumSize: const Size.fromHeight(48),
            ),
          ),
        ],
      ),
    );
  }
}
