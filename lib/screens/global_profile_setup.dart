import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:origilink/l10n/app_localizations.dart';
import 'package:origilink/screens/login.dart';
import 'package:origilink/screens/logout.dart' show seedStorageKey;
import 'package:origilink/src/rust/api/global_chat.dart' as global_chat_api;
import 'package:origilink/src/rust/api/relay.dart' as relay_api;

/// Onboarding step (skippable) and standalone redirect target for creating
/// a Global Chat identity's public NIP-01 profile — deliberately separate
/// from the private account's profile (see `global_chat.rs`'s module doc
/// on why posting under a distinct identity matters). Skipping just leaves
/// [global_chat_api.hasGlobalProfile] false; the account can always come
/// back here later, either by retrying a Global action (which redirects
/// here again) or from Settings.
class GlobalProfileSetupScreen extends StatefulWidget {
  const GlobalProfileSetupScreen({super.key, required this.onDone});

  /// Called after either a successful create or a skip — the caller
  /// decides what "done" means (continue onboarding, pop back to whatever
  /// Global action triggered the redirect, etc.).
  final VoidCallback onDone;

  @override
  State<GlobalProfileSetupScreen> createState() => _GlobalProfileSetupScreenState();
}

class _GlobalProfileSetupScreenState extends State<GlobalProfileSetupScreen> {
  final _nameController = TextEditingController();
  final _aboutController = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    _nameController.dispose();
    _aboutController.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    if (_nameController.text.trim().isEmpty) return;
    setState(() => _saving = true);
    const secureStorage = FlutterSecureStorage();
    final mnemonic = await secureStorage.read(key: seedStorageKey);
    final storageDir = await getApplicationDocumentsDirectory();
    if (mnemonic != null) {
      final relayList = await relay_api.loadRelayList(storageDir: storageDir.path);
      await global_chat_api.publishGlobalProfile(
        mnemonic: mnemonic,
        storageDir: storageDir.path,
        relayUrls: relayList.urls,
        name: _nameController.text.trim(),
        about: _aboutController.text.trim(),
      );
    }
    if (!mounted) return;
    setState(() => _saving = false);
    widget.onDone();
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
        title: Text(l10n.globalProfileSetupTitle),
      ),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.globalProfileSetupBody,
              style: const TextStyle(color: OrigilinkColors.textSecondary),
            ),
            const SizedBox(height: 24),
            TextField(
              controller: _nameController,
              decoration: InputDecoration(labelText: l10n.displayNameLabel),
              autofocus: true,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _aboutController,
              decoration: InputDecoration(labelText: l10n.statusMessageLabel),
            ),
            const Spacer(),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _saving ? null : widget.onDone,
                    child: Text(l10n.globalProfileSetupSkip),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: _saving ? null : _create,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: OrigilinkColors.primaryDark,
                      foregroundColor: Colors.white,
                    ),
                    child: _saving
                        ? const SizedBox(
                            height: 18,
                            width: 18,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                          )
                        : Text(l10n.globalProfileSetupCreate),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
