import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:origilink/l10n/app_localizations.dart';
import 'package:origilink/screens/login.dart';
import 'package:origilink/screens/logout.dart' show seedStorageKey;
import 'package:origilink/services/avatar_picker.dart';
import 'package:origilink/src/rust/api/global_chat.dart' as global_chat_api;
import 'package:origilink/src/rust/api/relay.dart' as relay_api;

/// Onboarding step (skippable) and standalone redirect target for creating
/// a Global Chat identity's public NIP-01 profile — deliberately separate
/// from the private account's profile (see `global_chat.rs`'s module doc
/// on why posting under a distinct identity matters). Skipping just leaves
/// [global_chat_api.hasGlobalProfile] false; the account can always come
/// back here later, either by retrying a Global action (which redirects
/// here again) or from Settings. Styled to match `edit_profile.dart`'s
/// private-profile editor (same avatar picker, filled text fields, single
/// primary button) so the two feel like one app rather than two — "skip"
/// only makes sense the first time through, before any profile exists.
class GlobalProfileSetupScreen extends StatefulWidget {
  const GlobalProfileSetupScreen({super.key, required this.onDone, this.existingProfile});

  /// Called after either a successful create/save or a skip — the caller
  /// decides what "done" means (continue onboarding, pop back to whatever
  /// Global action triggered the redirect, etc.).
  final VoidCallback onDone;

  /// When editing an already-configured profile (e.g. opened from Home's
  /// pencil icon), pre-fills the form and hides the skip option — there's
  /// nothing to skip past once a profile already exists.
  final global_chat_api.GlobalOwnProfile? existingProfile;

  @override
  State<GlobalProfileSetupScreen> createState() => _GlobalProfileSetupScreenState();
}

class _GlobalProfileSetupScreenState extends State<GlobalProfileSetupScreen> {
  late final _nameController = TextEditingController(text: widget.existingProfile?.name);
  late final _aboutController = TextEditingController(text: widget.existingProfile?.about);
  late String? _avatarPath = widget.existingProfile?.avatarPath;
  bool _saving = false;

  bool get _isEditing => widget.existingProfile != null;

  @override
  void dispose() {
    _nameController.dispose();
    _aboutController.dispose();
    super.dispose();
  }

  Future<void> _pickAvatar() async {
    final cropped = await pickAndCropAvatar(context);
    if (cropped == null) return;
    setState(() => _avatarPath = cropped);
  }

  Future<void> _create() async {
    if (_nameController.text.trim().isEmpty) return;
    setState(() => _saving = true);
    const secureStorage = FlutterSecureStorage();
    final mnemonic = await secureStorage.read(key: seedStorageKey);
    final storageDir = await getApplicationDocumentsDirectory();
    if (mnemonic != null) {
      var avatarPath = _avatarPath;
      if (avatarPath != null && !avatarPath.startsWith(storageDir.path)) {
        avatarPath = await global_chat_api.saveGlobalProfileAvatar(
          storageDir: storageDir.path,
          pickedPath: avatarPath,
        );
      }
      final relayList = await relay_api.loadRelayList(storageDir: storageDir.path);
      await global_chat_api.publishGlobalProfile(
        mnemonic: mnemonic,
        storageDir: storageDir.path,
        relayUrls: relayList.urls,
        name: _nameController.text.trim(),
        about: _aboutController.text.trim(),
        avatarPath: avatarPath,
      );
    }
    if (!mounted) return;
    setState(() => _saving = false);
    widget.onDone();
  }

  void _showInfoDialog(BuildContext context, AppLocalizations l10n) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: OrigilinkColors.background,
        title: Text(l10n.globalProfileSetupTitle),
        content: Text(
          l10n.globalProfileSetupBody,
          style: const TextStyle(color: OrigilinkColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(MaterialLocalizations.of(dialogContext).okButtonLabel),
          ),
        ],
      ),
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
        title: Text(_isEditing ? l10n.editProfile : l10n.globalProfileSetupTitle),
        actions: [
          IconButton(
            icon: const Icon(Icons.info_outline),
            tooltip: l10n.globalProfileSetupTitle,
            onPressed: () => _showInfoDialog(context, l10n),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildAvatarPicker(),
              const SizedBox(height: 32),
              TextField(
                controller: _nameController,
                decoration: _inputDecoration(l10n.displayNameLabel),
                autofocus: !_isEditing,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _aboutController,
                decoration: _inputDecoration(l10n.statusMessageLabel),
              ),
              const SizedBox(height: 32),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton(
                  onPressed: _saving ? null : _create,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: OrigilinkColors.primaryDark,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: _saving
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : Text(
                          _isEditing ? l10n.continueButton : l10n.globalProfileSetupCreate,
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                        ),
                ),
              ),
              if (!_isEditing) ...[
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: OutlinedButton(
                    onPressed: _saving ? null : widget.onDone,
                    child: Text(l10n.globalProfileSetupSkip),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAvatarPicker() {
    final avatarPath = _avatarPath;
    return Center(
      child: GestureDetector(
        onTap: _pickAvatar,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              width: 88,
              height: 88,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: OrigilinkColors.surface,
                borderRadius: BorderRadius.circular(18),
              ),
              child: avatarPath != null
                  ? Image.file(File(avatarPath), width: 88, height: 88, fit: BoxFit.cover)
                  : const Icon(Icons.public, size: 32, color: OrigilinkColors.textSecondary),
            ),
            Positioned(
              right: -6,
              bottom: -6,
              child: Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.45),
                  shape: BoxShape.circle,
                  border: Border.all(color: OrigilinkColors.background, width: 2),
                ),
                child: const Icon(Icons.photo_camera_outlined, size: 16, color: Colors.white),
              ),
            ),
          ],
        ),
      ),
    );
  }

  InputDecoration _inputDecoration(String label) {
    return InputDecoration(
      labelText: label,
      filled: true,
      fillColor: OrigilinkColors.surface,
      labelStyle: TextStyle(color: OrigilinkColors.textSecondary),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: OrigilinkColors.primary, width: 1.5),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    );
  }
}
