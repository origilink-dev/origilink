import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:origilink/l10n/app_localizations.dart';
import 'package:origilink/screens/login.dart';
import 'package:origilink/screens/logout.dart' show seedStorageKey;
import 'package:origilink/services/account_sync.dart';
import 'package:origilink/services/avatar_picker.dart';
import 'package:origilink/src/rust/api/account.dart' as account_api;

/// Lets the user change their avatar, display name, and status message.
/// Pops with the updated [account_api.Account] once saved, or nothing if
/// the user cancels.
class EditProfileScreen extends StatefulWidget {
  const EditProfileScreen({super.key, required this.profile});

  final account_api.Account profile;

  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  final _formKey = GlobalKey<FormState>();
  late final _displayNameController = TextEditingController(
    text: widget.profile.displayName,
  );
  late final _statusMessageController = TextEditingController(
    text: widget.profile.statusMessage,
  );
  late String? _avatarPath = widget.profile.avatarPath;
  bool _saving = false;

  @override
  void dispose() {
    _displayNameController.dispose();
    _statusMessageController.dispose();
    super.dispose();
  }

  Future<void> _pickAvatar() async {
    final cropped = await pickAndCropAvatar(context);
    if (cropped == null) return;
    setState(() => _avatarPath = cropped);
  }

  Future<void> _handleSave() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);

    final storageDir = await getApplicationDocumentsDirectory();
    var avatarPath = _avatarPath;
    // Only copy the picked file into permanent storage if it isn't already
    // there (i.e. the user picked a new image rather than keeping the old one).
    if (avatarPath != null && !avatarPath.startsWith(storageDir.path)) {
      avatarPath = await account_api.saveAccountAvatar(
        storageDir: storageDir.path,
        pickedPath: avatarPath,
      );
    }
    final avatarChanged = avatarPath != widget.profile.avatarPath;

    // Only re-upload (a fresh, undeduplicatable encrypted blob every time)
    // when the avatar actually changed — otherwise keep reusing the
    // existing link so friends/backups don't re-fetch it for nothing.
    var avatarLink = widget.profile.avatarLink;
    if (avatarChanged) {
      avatarLink = null;
      if (avatarPath != null) {
        const secureStorage = FlutterSecureStorage();
        final mnemonic = await secureStorage.read(key: seedStorageKey);
        if (mnemonic != null) {
          try {
            avatarLink = await account_api.uploadAccountAvatarLink(
              mnemonic: mnemonic,
              storageDir: storageDir.path,
              avatarPath: avatarPath,
              previousAvatarLink: widget.profile.avatarLink,
            );
          } catch (_) {
            // Offline or every upload server unreachable — friends/other
            // devices just won't get the new avatar until the next save.
          }
        }
      }
    }

    await account_api.saveAccount(
      storageDir: storageDir.path,
      displayName: _displayNameController.text.trim(),
      statusMessage: _statusMessageController.text.trim(),
      avatarPath: avatarPath,
      avatarLink: avatarLink,
    );
    final saved = (await account_api.loadAccount(storageDir: storageDir.path))!;
    unawaited(publishAccountBackup(saved));
    if (avatarChanged) unawaited(publishAccountAvatarBackup(saved));
    unawaited(publishProfileUpdateToFriends(saved, avatarChanged: avatarChanged));

    if (!mounted) return;
    Navigator.of(context).pop(saved);
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
        title: Text(l10n.editProfile),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildAvatarPicker(),
                const SizedBox(height: 32),
                TextFormField(
                  controller: _displayNameController,
                  decoration: _inputDecoration(l10n.displayNameLabel),
                  validator: (value) => (value == null || value.trim().isEmpty)
                      ? l10n.displayNameRequired
                      : null,
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _statusMessageController,
                  decoration: _inputDecoration(l10n.statusMessageLabel),
                ),
                const SizedBox(height: 32),
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: ElevatedButton(
                    onPressed: _saving ? null : _handleSave,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: OrigilinkColors.primaryDark,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: _saving
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : Text(
                            l10n.continueButton,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                  ),
                ),
              ],
            ),
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
                borderRadius: BorderRadius.circular(24),
              ),
              child: avatarPath != null
                  ? Image.file(File(avatarPath), width: 88, height: 88, fit: BoxFit.cover)
                  : const Icon(
                      Icons.photo_outlined,
                      size: 32,
                      color: OrigilinkColors.textSecondary,
                    ),
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
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: OrigilinkColors.primary, width: 1.5),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    );
  }
}
