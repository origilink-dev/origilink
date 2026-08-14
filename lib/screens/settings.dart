import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:origilink/l10n/app_localizations.dart';
import 'package:origilink/languages.dart';
import 'package:origilink/screens/logout.dart';
import 'package:origilink/screens/edit_profile.dart';
import 'package:origilink/screens/global_profile_setup.dart';
import 'package:origilink/screens/login.dart';
import 'package:origilink/screens/relay_settings.dart';
import 'package:origilink/screens/attachment_server_settings.dart';
import 'package:origilink/src/rust/api/account.dart' as account_api;
import 'package:origilink/src/rust/api/global_chat.dart' as global_chat_api;
import 'package:origilink/src/rust/api/sync.dart' as sync_api;

/// Settings menu reachable from the top-right gear icon on Home. Links to
/// the profile edit screen and relay configuration.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({
    super.key,
    required this.profile,
    required this.onProfileUpdated,
    required this.onSelectLanguage,
    required this.onLogout,
    this.messageEvents,
  });

  final account_api.Account profile;
  final ValueChanged<account_api.Account> onProfileUpdated;
  final ValueChanged<Locale> onSelectLanguage;
  final VoidCallback onLogout;
  final Stream<sync_api.FriendEvent>? messageEvents;

  void _openAccountSettings(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AccountSettingsScreen(onLogout: onLogout),
      ),
    );
  }

  Future<void> _openEditProfile(BuildContext context) async {
    final updated = await Navigator.of(context).push<account_api.Account>(
      MaterialPageRoute(builder: (_) => EditProfileScreen(profile: profile)),
    );
    if (updated == null) return;
    onProfileUpdated(updated);
  }

  /// Opens Global Profile setup/edit, pre-filled if one already exists —
  /// the Global Chat identity is otherwise only reachable by switching
  /// Home's Private/Global toggle, which isn't obvious as "where you edit
  /// your Global profile" from Settings.
  Future<void> _openGlobalProfile(BuildContext context) async {
    final storageDir = await getApplicationDocumentsDirectory();
    final existing = await global_chat_api.loadGlobalProfile(storageDir: storageDir.path);
    if (!context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => GlobalProfileSetupScreen(
          existingProfile: existing,
          onDone: () => Navigator.of(context).pop(),
        ),
      ),
    );
  }

  void _openRelaySettings(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => RelaySettingsScreen(messageEvents: messageEvents),
      ),
    );
  }

  void _openAttachmentServerSettings(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const AttachmentServerSettingsScreen()),
    );
  }

  void _openLicensePage(BuildContext context) {
    showLicensePage(
      context: context,
      applicationName: 'OrigiLink',
      applicationVersion: '1.0.0',
    );
  }

  Future<void> _openLanguagePicker(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final currentCode = Localizations.localeOf(context).languageCode;
    final selected = await showDialog<Locale>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: OrigilinkColors.background,
          title: Text(l10n.settingsLanguage),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final locale in AppLocalizations.supportedLocales)
                ListTile(
                  title: Text(languageNames[locale.languageCode] ?? locale.languageCode.toUpperCase()),
                  trailing: locale.languageCode == currentCode
                      ? const Icon(Icons.check, color: OrigilinkColors.primaryDark)
                      : null,
                  onTap: () => Navigator.of(dialogContext).pop(locale),
                ),
            ],
          ),
        );
      },
    );
    if (selected == null) return;
    onSelectLanguage(selected);
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
        title: Text(l10n.settingsTitle),
      ),
      body: SafeArea(
        child: ListView(
          children: [
            ListTile(
              leading: const Icon(Icons.person_outline, color: OrigilinkColors.textSecondary),
              title: Text(l10n.settingsProfile),
              trailing: const Icon(Icons.chevron_right, color: OrigilinkColors.textSecondary),
              onTap: () => _openEditProfile(context),
            ),
            ListTile(
              leading: const Icon(Icons.public, color: OrigilinkColors.textSecondary),
              title: Text(l10n.globalProfileSetupTitle),
              trailing: const Icon(Icons.chevron_right, color: OrigilinkColors.textSecondary),
              onTap: () => _openGlobalProfile(context),
            ),
            ListTile(
              leading: const Icon(Icons.dns_outlined, color: OrigilinkColors.textSecondary),
              title: Text(l10n.settingsRelay),
              trailing: const Icon(Icons.chevron_right, color: OrigilinkColors.textSecondary),
              onTap: () => _openRelaySettings(context),
            ),
            ListTile(
              leading: const Icon(Icons.cloud_upload_outlined, color: OrigilinkColors.textSecondary),
              title: Text(l10n.settingsAttachmentServer),
              trailing: const Icon(Icons.chevron_right, color: OrigilinkColors.textSecondary),
              onTap: () => _openAttachmentServerSettings(context),
            ),
            ListTile(
              leading: const Icon(Icons.translate, color: OrigilinkColors.textSecondary),
              title: Text(l10n.settingsLanguage),
              trailing: const Icon(Icons.chevron_right, color: OrigilinkColors.textSecondary),
              onTap: () => _openLanguagePicker(context),
            ),
            ListTile(
              leading: const Icon(Icons.manage_accounts_outlined, color: OrigilinkColors.textSecondary),
              title: Text(l10n.settingsAccount),
              trailing: const Icon(Icons.chevron_right, color: OrigilinkColors.textSecondary),
              onTap: () => _openAccountSettings(context),
            ),
            ListTile(
              leading: const Icon(Icons.description_outlined, color: OrigilinkColors.textSecondary),
              title: Text(l10n.settingsLicenses),
              trailing: const Icon(Icons.chevron_right, color: OrigilinkColors.textSecondary),
              onTap: () => _openLicensePage(context),
            ),
          ],
        ),
      ),
    );
  }
}
