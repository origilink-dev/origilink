import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:origilink/l10n/app_localizations.dart';
import 'package:origilink/screens/login.dart';
import 'package:origilink/screens/seed_backup.dart';
import 'package:origilink/src/rust/api/account.dart' as account_api;
import 'package:origilink/src/rust/api/global_chat.dart' as global_chat_api;
import 'package:origilink/src/rust/api/keys.dart' as keys_api;
import 'package:origilink/src/rust/api/relay.dart' as relay_api;
import 'package:origilink/src/rust/api/sync.dart' as sync_api;

const seedStorageKey = 'account_seed_mnemonic';

/// Account management screen. Offers seed phrase backup, logout, and account
/// deletion. Both logout and delete currently wipe the same local data
/// (profile, relays, seed) — Origilink has no relay-backed sync yet, so there's
/// nothing else to distinguish them by. They're kept as separate entries
/// (with separate confirmation copy) so the UI is ready for the day logout
/// only needs to clear the local device while a synced account survives.
class AccountSettingsScreen extends StatelessWidget {
  const AccountSettingsScreen({super.key, required this.onLogout});

  final VoidCallback onLogout;

  Future<void> _confirmLogout(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: OrigilinkColors.background,
          title: Text(l10n.logoutConfirmTitle),
          content: Text(l10n.logoutConfirmBody),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(MaterialLocalizations.of(dialogContext).cancelButtonLabel),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(l10n.logoutButton),
            ),
          ],
        );
      },
    );
    if (confirmed != true) return;
    onLogout();
  }

  Future<void> _confirmDeleteAccount(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: OrigilinkColors.background,
          title: Text(l10n.deleteAccountConfirmTitle),
          content: Text(l10n.deleteAccountConfirmBody),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(MaterialLocalizations.of(dialogContext).cancelButtonLabel),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              style: TextButton.styleFrom(foregroundColor: Colors.red),
              child: Text(l10n.deleteAccountButton),
            ),
          ],
        );
      },
    );
    if (confirmed != true) return;

    const secureStorage = FlutterSecureStorage();
    final mnemonic = await secureStorage.read(key: seedStorageKey);
    if (mnemonic != null) {
      final storageDir = await getApplicationDocumentsDirectory();
      final relayList = await relay_api.loadRelayList(storageDir: storageDir.path);
      try {
        await sync_api.deleteAccountBackup(mnemonic: mnemonic, relayUrls: relayList.urls);
      } catch (_) {
        // Relays unreachable — the local wipe still proceeds; the backup
        // event may linger on relays that were offline for this request.
      }

      // Best-effort: also remove this device's uploaded avatar blobs from
      // the Blossom server(s) — nothing will ever reference them again
      // once the local account/profile is wiped.
      final account = await account_api.loadAccount(storageDir: storageDir.path);
      final avatarLink = account?.avatarLink;
      if (avatarLink != null) {
        try {
          await account_api.deleteAccountAvatarBlob(mnemonic: mnemonic, avatarLink: avatarLink);
        } catch (_) {
          // Offline or server doesn't support delete — nothing more to do.
        }
      }
      final globalProfile = await global_chat_api.loadGlobalProfile(storageDir: storageDir.path);
      final pictureUrl = globalProfile?.pictureUrl;
      if (pictureUrl != null) {
        try {
          await global_chat_api.deleteGlobalProfilePicture(
            mnemonic: mnemonic,
            pictureUrl: pictureUrl,
          );
        } catch (_) {
          // Offline or server doesn't support delete — nothing more to do.
        }
      }
    }
    onLogout();
  }

  Future<String?> _loadUid() async {
    const secureStorage = FlutterSecureStorage();
    final mnemonic = await secureStorage.read(key: seedStorageKey);
    if (mnemonic == null) return null;
    return keys_api.getAccountUid(mnemonic: mnemonic);
  }

  Future<void> _copyUid(BuildContext context, String uid) async {
    final l10n = AppLocalizations.of(context)!;
    await Clipboard.setData(ClipboardData(text: uid));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.uidCopiedMessage)));
  }

  Future<void> _openSeedBackup(BuildContext context) async {
    const storage = FlutterSecureStorage();
    var mnemonic = await storage.read(key: seedStorageKey);
    if (mnemonic == null) {
      mnemonic = await keys_api.generateMnemonic();
      await storage.write(key: seedStorageKey, value: mnemonic);
    }
    if (!context.mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => SeedBackupScreen(mnemonic: mnemonic!)),
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
        title: Text(l10n.accountSettingsTitle),
      ),
      body: SafeArea(
        child: ListView(
          children: [
            FutureBuilder<String?>(
              future: _loadUid(),
              builder: (context, snapshot) {
                final uid = snapshot.data;
                return ListTile(
                  leading: const Icon(Icons.badge_outlined, color: OrigilinkColors.textSecondary),
                  title: Text(l10n.myUid),
                  subtitle: uid == null
                      ? null
                      : Text(
                          '${uid.substring(0, 16)}...',
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            color: OrigilinkColors.textSecondary,
                          ),
                        ),
                  trailing: const Icon(Icons.copy_outlined, color: OrigilinkColors.textSecondary),
                  onTap: uid == null ? null : () => _copyUid(context, uid),
                );
              },
            ),
            const Divider(height: 1, color: Color(0x14000000)),
            ListTile(
              leading: const Icon(Icons.key_outlined, color: OrigilinkColors.textSecondary),
              title: Text(l10n.seedBackupButton),
              trailing: const Icon(Icons.chevron_right, color: OrigilinkColors.textSecondary),
              onTap: () => _openSeedBackup(context),
            ),
            ListTile(
              leading: const Icon(Icons.logout, color: OrigilinkColors.textSecondary),
              title: Text(l10n.logoutButton),
              trailing: const Icon(Icons.chevron_right, color: OrigilinkColors.textSecondary),
              onTap: () => _confirmLogout(context),
            ),
            ListTile(
              leading: const Icon(Icons.delete_forever_outlined, color: Colors.red),
              title: Text(
                l10n.deleteAccountButton,
                style: const TextStyle(color: Colors.red, fontWeight: FontWeight.w600),
              ),
              trailing: const Icon(Icons.chevron_right, color: Colors.red),
              onTap: () => _confirmDeleteAccount(context),
            ),
          ],
        ),
      ),
    );
  }
}
