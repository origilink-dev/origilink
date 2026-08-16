import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:gal/gal.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:path_provider/path_provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:origilink/l10n/app_localizations.dart';
import 'package:origilink/screens/friend_requests.dart';
import 'package:origilink/screens/login.dart';
import 'package:origilink/screens/logout.dart' show seedStorageKey;
import 'package:origilink/services/account_sync.dart';
import 'package:origilink/src/rust/api/friends.dart' as friends_api;
import 'package:origilink/src/rust/api/invites.dart' as invites_api;
import 'package:origilink/src/rust/api/keys.dart' as keys_api;
import 'package:origilink/src/rust/api/sync.dart' as sync_api;

/// Add-friend flow: show your own QR (an invite others scan to send a
/// friend request) or scan someone else's. Each invite mints a fresh,
/// revocable per-relationship key (see `keys::derive_contact_keys`) —
/// nothing here is the account's core identity.
class AddFriendScreen extends StatefulWidget {
  const AddFriendScreen({super.key, this.messageEvents});

  /// Live friend-protocol events (shared with `home.dart`'s subscription)
  /// — without this, a request arriving while this screen is already open
  /// wouldn't update the badge until the user navigated away and back.
  final Stream<sync_api.FriendEvent>? messageEvents;

  @override
  State<AddFriendScreen> createState() => _AddFriendScreenState();
}

class _AddFriendScreenState extends State<AddFriendScreen> {
  int _pendingRequestCount = 0;
  StreamSubscription<sync_api.FriendEvent>? _sub;

  @override
  void initState() {
    super.initState();
    _refreshPendingRequestCount();
    _sub = widget.messageEvents?.listen((event) {
      if (event.kind == 'request') _refreshPendingRequestCount();
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _refreshPendingRequestCount() async {
    final count = await pendingFriendRequestCount();
    if (!mounted) return;
    setState(() => _pendingRequestCount = count);
  }

  Future<void> _openFriendRequests() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => FriendRequestsScreen(messageEvents: widget.messageEvents),
      ),
    );
    _refreshPendingRequestCount();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        backgroundColor: OrigilinkColors.background,
        appBar: AppBar(
          backgroundColor: OrigilinkColors.background,
          elevation: 0,
          foregroundColor: OrigilinkColors.textPrimary,
          title: Text(l10n.addFriendTitle),
          actions: [
            IconButton(
              tooltip: l10n.friendRequestsTitle,
              icon: Badge(
                isLabelVisible: _pendingRequestCount > 0,
                label: Text('$_pendingRequestCount'),
                child: const Icon(Icons.mail_outline),
              ),
              onPressed: _openFriendRequests,
            ),
            IconButton(
              tooltip: l10n.activeInvitesTitle,
              icon: const Icon(Icons.list_alt_outlined),
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const ActiveInvitesScreen(),
                  ),
                );
              },
            ),
          ],
          bottom: TabBar(
            labelColor: OrigilinkColors.primaryDark,
            unselectedLabelColor: OrigilinkColors.textSecondary,
            indicatorColor: OrigilinkColors.primaryDark,
            tabs: [
              Tab(text: l10n.myQrTab),
              Tab(text: l10n.scanTab),
            ],
          ),
        ),
        body: const TabBarView(children: [_MyQrTab(), _ScanTab()]),
      ),
    );
  }
}

class _MyQrTab extends StatefulWidget {
  const _MyQrTab();

  @override
  State<_MyQrTab> createState() => _MyQrTabState();
}

enum _LimitMode { preset, custom, unlimited }

class _MyQrTabState extends State<_MyQrTab> {
  static const _usesPresets = [1, 5, 10];
  static const _daysPresets = [1, 7, 30];

  final _usesController = TextEditingController();
  final _daysController = TextEditingController();
  _LimitMode _usesMode = _LimitMode.preset;
  int _usesPreset = 1;
  _LimitMode _daysMode = _LimitMode.unlimited;
  int _daysPreset = 1;

  bool _generating = false;
  String? _qrPayload;

  @override
  void dispose() {
    _usesController.dispose();
    _daysController.dispose();
    super.dispose();
  }

  /// Saves the current QR code as a PNG to the device's photo gallery —
  /// mainly for getting the invite onto another device (e.g. an emulator)
  /// without a working camera, by transferring the saved image instead of
  /// scanning it live.
  Future<void> _saveQrToDevice() async {
    final payload = _qrPayload;
    if (payload == null) return;
    final l10n = AppLocalizations.of(context)!;
    final qrValidationResult = QrValidator.validate(
      data: payload,
      version: QrVersions.auto,
      errorCorrectionLevel: QrErrorCorrectLevel.L,
    );
    if (qrValidationResult.status != QrValidationStatus.valid) return;
    final painter = QrPainter.withQr(qr: qrValidationResult.qrCode!, gapless: true);
    const double size = 1024;
    // Scanners (ZXing/MLKit, used by mobile_scanner) need a quiet zone
    // around the QR to detect the finder patterns — painting it flush to
    // the canvas edges (as the raw painter does) makes saved codes
    // undetectable even though the encoded data is intact.
    const double quietZone = size * 0.08;
    const double qrSize = size - quietZone * 2;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(
      const Rect.fromLTWH(0, 0, size, size),
      Paint()..color = const Color(0xFFFFFFFF),
    );
    canvas.translate(quietZone, quietZone);
    painter.paint(canvas, const Size(qrSize, qrSize));
    final image = await recorder.endRecording().toImage(size.toInt(), size.toInt());
    final imageData = await image.toByteData(format: ui.ImageByteFormat.png);
    if (imageData == null) return;
    final bytes = imageData.buffer.asUint8List();
    try {
      await Gal.putImageBytes(bytes, name: 'origilink_invite_qr');
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.qrSavedToDeviceMessage)));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.qrSaveFailedMessage)));
    }
  }

  Future<void> _copyCode() async {
    final payload = _qrPayload;
    if (payload == null) return;
    await Clipboard.setData(ClipboardData(text: payload));
    if (!mounted) return;
    final l10n = AppLocalizations.of(context)!;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(l10n.codeCopiedMessage)));
  }

  Future<void> _generate() async {
    setState(() => _generating = true);
    final storageDir = await getApplicationDocumentsDirectory();
    const secureStorage = FlutterSecureStorage();
    final mnemonic = await secureStorage.read(key: seedStorageKey);
    if (mnemonic == null) {
      setState(() => _generating = false);
      return;
    }

    final maxUses = switch (_usesMode) {
      _LimitMode.unlimited => null,
      _LimitMode.preset => _usesPreset,
      _LimitMode.custom => int.tryParse(_usesController.text) ?? 1,
    };
    final days = switch (_daysMode) {
      _LimitMode.unlimited => null,
      _LimitMode.preset => _daysPreset,
      _LimitMode.custom => int.tryParse(_daysController.text),
    };
    final ttlSeconds = days == null ? null : days * 86400;

    final invite = await invites_api.createInvite(
      storageDir: storageDir.path,
      ttlSeconds: ttlSeconds,
      maxUses: maxUses,
    );
    unawaited(publishAccountInvitesBackup());
    // A request against this invite could arrive while the user is still
    // sitting on this "My QR" screen (the whole point of showing it) —
    // don't wait for a return-to-Home resubscribe to start watching it.
    friendEventsRefreshSignal.value++;
    final payload = await sync_api.buildInviteQrPayload(
      mnemonic: mnemonic,
      storageDir: storageDir.path,
      accountIndex: invite.accountIndex,
    );
    if (!mounted) return;
    setState(() {
      _qrPayload = payload;
      _generating = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final payload = _qrPayload;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (payload != null) ...[
            Center(
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: QrImageView(data: payload, size: 220),
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 44,
              child: OutlinedButton(
                onPressed: _generating ? null : _generate,
                style: OutlinedButton.styleFrom(
                  foregroundColor: OrigilinkColors.primaryDark,
                  side: const BorderSide(color: OrigilinkColors.primary),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: Text(l10n.regenerateQrButton),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 44,
              child: OutlinedButton(
                onPressed: _copyCode,
                style: OutlinedButton.styleFrom(
                  foregroundColor: OrigilinkColors.primaryDark,
                  side: const BorderSide(color: OrigilinkColors.primary),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: Text(l10n.copyCodeButton),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 44,
              child: OutlinedButton(
                onPressed: _saveQrToDevice,
                style: OutlinedButton.styleFrom(
                  foregroundColor: OrigilinkColors.primaryDark,
                  side: const BorderSide(color: OrigilinkColors.primary),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: Text(l10n.saveQrToDeviceButton),
              ),
            ),
            const SizedBox(height: 24),
            const Divider(),
            const SizedBox(height: 16),
          ],
          _buildLimitField(
            label: l10n.maxUsesLabel,
            controller: _usesController,
            mode: _usesMode,
            onModeChanged: (m) => setState(() => _usesMode = m),
            selectedPreset: _usesPreset,
            onPresetSelected: (p) => setState(() => _usesPreset = p),
            presets: _usesPresets,
          ),
          const SizedBox(height: 16),
          _buildLimitField(
            label: l10n.validForLabel,
            controller: _daysController,
            mode: _daysMode,
            onModeChanged: (m) => setState(() => _daysMode = m),
            selectedPreset: _daysPreset,
            onPresetSelected: (p) => setState(() => _daysPreset = p),
            presets: _daysPresets,
          ),
          const SizedBox(height: 24),
          if (payload == null)
            SizedBox(
              height: 48,
              child: ElevatedButton(
                onPressed: _generating ? null : _generate,
                style: ElevatedButton.styleFrom(
                  backgroundColor: OrigilinkColors.primaryDark,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: _generating
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : Text(l10n.generateQrButton),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildLimitField({
    required String label,
    required TextEditingController controller,
    required _LimitMode mode,
    required ValueChanged<_LimitMode> onModeChanged,
    required int selectedPreset,
    required ValueChanged<int> onPresetSelected,
    required List<int> presets,
  }) {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: OrigilinkColors.textSecondary,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final preset in presets)
              _presetChip(
                label: '$preset',
                selected: mode == _LimitMode.preset && selectedPreset == preset,
                onTap: () {
                  onPresetSelected(preset);
                  onModeChanged(_LimitMode.preset);
                },
              ),
            _presetChip(
              label: l10n.unlimitedLabel,
              selected: mode == _LimitMode.unlimited,
              onTap: () => onModeChanged(_LimitMode.unlimited),
            ),
            _presetChip(
              label: l10n.customLabel,
              selected: mode == _LimitMode.custom,
              onTap: () => onModeChanged(_LimitMode.custom),
            ),
          ],
        ),
        if (mode == _LimitMode.custom) ...[
          const SizedBox(height: 8),
          TextField(
            controller: controller,
            keyboardType: TextInputType.number,
            autofocus: true,
            decoration: InputDecoration(
              filled: true,
              fillColor: OrigilinkColors.surface,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 12,
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _presetChip({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onTap(),
      selectedColor: OrigilinkColors.primary,
      backgroundColor: OrigilinkColors.surface,
      labelStyle: TextStyle(
        color: selected ? Colors.white : OrigilinkColors.textPrimary,
        fontWeight: FontWeight.w500,
      ),
    );
  }
}

class _ScanTab extends StatefulWidget {
  const _ScanTab();

  @override
  State<_ScanTab> createState() => _ScanTabState();
}

class _ScanTabState extends State<_ScanTab> {
  final _scannerController = MobileScannerController();
  final _pasteController = TextEditingController();
  bool _handling = false;

  @override
  void dispose() {
    _scannerController.dispose();
    _pasteController.dispose();
    super.dispose();
  }

  Future<void> _submitPastedCode() async {
    final text = _pasteController.text.trim();
    if (text.isEmpty) return;
    await _handleDetected(text);
    _pasteController.clear();
  }

  Future<void> _pickFromGallery() async {
    final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (picked == null) return;
    final capture = await _scannerController.analyzeImage(picked.path);
    final barcodes = capture?.barcodes ?? const [];
    final value = barcodes.isNotEmpty ? barcodes.first.rawValue : null;
    if (value != null) {
      await _handleDetected(value);
    } else if (mounted) {
      final l10n = AppLocalizations.of(context)!;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.scanInvalidQr)));
    }
  }

  Future<void> _handleDetected(String raw) async {
    if (_handling) return;
    setState(() => _handling = true);
    final l10n = AppLocalizations.of(context)!;

    sync_api.InviteQrPayload payload;
    try {
      payload = await sync_api.parseInviteQrPayload(data: raw);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l10n.scanInvalidQr)));
        setState(() => _handling = false);
      }
      return;
    }

    const secureStorage = FlutterSecureStorage();
    final mnemonic = await secureStorage.read(key: seedStorageKey);
    // The invite's own pubkey is a fresh per-invite key (see
    // `sync.rs`'s `InviteQrPayload` doc comment), so it can't be compared
    // directly against this device's identity — but `uid` is
    // account-stable, so a self-scan (e.g. testing against your own QR)
    // is still caught here rather than silently creating a friendship
    // with yourself.
    if (mnemonic != null && payload.uid == await keys_api.getAccountUid(mnemonic: mnemonic)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.cannotAddSelfMessage)));
        setState(() => _handling = false);
      }
      return;
    }

    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: OrigilinkColors.background,
        title: Text(l10n.sendRequestConfirmTitle),
        content: Text(l10n.sendRequestConfirmBody(payload.displayName)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(
              MaterialLocalizations.of(dialogContext).cancelButtonLabel,
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.sendRequestButton),
          ),
        ],
      ),
    );

    if (confirmed != true) {
      setState(() => _handling = false);
      return;
    }

    final storageDir = await getApplicationDocumentsDirectory();
    var alreadyFriend = false;
    if (mnemonic != null) {
      // The scanned invite's pubkey is a fresh per-invite key, so it can't
      // be matched against existing friends directly — but the inviter's
      // stable UID (also in the QR) can, letting us recognize "already a
      // friend" right now instead of only after they accept.
      alreadyFriend = await friends_api.isKnownUid(
        storageDir: storageDir.path,
        uid: payload.uid,
      );
      await sync_api.sendFriendRequest(
        mnemonic: mnemonic,
        storageDir: storageDir.path,
        invitePubkey: payload.pubkey,
        inviteRelays: payload.relays,
      );
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(alreadyFriend ? l10n.friendAlreadyAddedMessage : l10n.requestSentMessage),
      ),
    );
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Stack(
      children: [
        MobileScanner(
          controller: _scannerController,
          onDetect: (capture) {
            if (capture.barcodes.isEmpty) return;
            final value = capture.barcodes.first.rawValue;
            if (value != null) unawaited(_handleDetected(value));
          },
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 32,
          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  l10n.scanPrompt,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                ),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _pickFromGallery,
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: const BorderSide(color: Colors.white),
                  backgroundColor: Colors.black.withValues(alpha: 0.3),
                ),
                icon: const Icon(Icons.photo_library_outlined, size: 18),
                label: Text(l10n.pickFromGallery),
              ),
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _pasteController,
                        style: const TextStyle(color: Colors.white),
                        decoration: InputDecoration(
                          hintText: l10n.pasteCodeHint,
                          hintStyle: const TextStyle(color: Colors.white70),
                          filled: true,
                          fillColor: Colors.black.withValues(alpha: 0.4),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide.none,
                          ),
                        ),
                        onSubmitted: (_) => _submitPastedCode(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton(
                      onPressed: _submitPastedCode,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: const BorderSide(color: Colors.white),
                        backgroundColor: Colors.black.withValues(alpha: 0.3),
                      ),
                      child: Text(l10n.pasteCodeButton),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (_handling)
          Container(
            color: Colors.black.withValues(alpha: 0.3),
            child: const Center(child: CircularProgressIndicator()),
          ),
      ],
    );
  }
}

/// Lists every invite this device has created (active or not), with a way
/// to manually revoke one — e.g. if its QR leaked and started attracting
/// spam requests.
class ActiveInvitesScreen extends StatefulWidget {
  const ActiveInvitesScreen({super.key});

  @override
  State<ActiveInvitesScreen> createState() => _ActiveInvitesScreenState();
}

class _ActiveInvitesScreenState extends State<ActiveInvitesScreen> {
  List<invites_api.Invite> _invites = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final storageDir = await getApplicationDocumentsDirectory();
    final invites = await invites_api.listActiveInvites(
      storageDir: storageDir.path,
    );
    if (!mounted) return;
    setState(() {
      _invites = invites;
      _loading = false;
    });
  }

  Future<void> _revoke(invites_api.Invite invite) async {
    final storageDir = await getApplicationDocumentsDirectory();
    await invites_api.revokeInvite(
      storageDir: storageDir.path,
      accountIndex: invite.accountIndex,
    );
    unawaited(publishAccountInvitesBackup());
    _load();
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
        title: Text(l10n.activeInvitesTitle),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _invites.isEmpty
          ? Center(
              child: Text(
                l10n.noActiveInvites,
                style: const TextStyle(color: OrigilinkColors.textSecondary),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: _invites.length,
              itemBuilder: (context, index) {
                final invite = _invites[index];
                final nowSeconds =
                    DateTime.now().millisecondsSinceEpoch ~/ 1000;
                final expiresAt = invite.expiresAt;
                final subtitle = [
                  invite.maxUses == null
                      ? l10n.invitesUsesUsedUnlimited(invite.useCount)
                      : l10n.invitesUsesUsed(invite.useCount, invite.maxUses!),
                  if (expiresAt != null)
                    l10n.invitesExpiresIn(
                      ((expiresAt - nowSeconds) / 86400).ceil(),
                    ),
                ].join(' · ');
                return Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: OrigilinkColors.surface,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('#${invite.accountIndex}'),
                    subtitle: Text(
                      subtitle,
                      style: const TextStyle(
                        color: OrigilinkColors.textSecondary,
                      ),
                    ),
                    trailing: TextButton(
                      onPressed: () => _revoke(invite),
                      child: Text(
                        l10n.revokeInvite,
                        style: const TextStyle(color: Colors.red),
                      ),
                    ),
                  ),
                );
              },
            ),
    );
  }
}
