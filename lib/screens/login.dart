import 'dart:io';

import 'package:flutter/material.dart';
import 'package:origilink/l10n/app_localizations.dart';
import 'package:origilink/services/avatar_picker.dart';

/// Greige-based color palette.
class OrigilinkColors {
  static const background = Color(0xFFF1ECE4);
  static const surface = Color(0xFFE7DFD2);
  static const primary = Color(0xFFA6957D);
  static const primaryDark = Color(0xFF6F6252);
  static const textPrimary = Color(0xFF4A4238);
  static const textSecondary = Color(0xFF8B8070);
}

/// Profile (display name / status message) setup screen shown before account creation.
/// Origilink has no concept of a fixed account key, so this only decides
/// the display profile used across the app.
class ProfileSetupScreen extends StatefulWidget {
  const ProfileSetupScreen({super.key, this.onContinue});

  final void Function(String displayName, String statusMessage, String? avatarPath)? onContinue;

  @override
  State<ProfileSetupScreen> createState() => _ProfileSetupScreenState();
}

class _ProfileSetupScreenState extends State<ProfileSetupScreen> {
  final _formKey = GlobalKey<FormState>();
  final _displayNameController = TextEditingController();
  final _statusMessageController = TextEditingController();
  String? _avatarPath;

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

  void _handleContinue() {
    if (!_formKey.currentState!.validate()) return;
    widget.onContinue?.call(
      _displayNameController.text.trim(),
      _statusMessageController.text.trim(),
      _avatarPath,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      backgroundColor: OrigilinkColors.background,
      body: SafeArea(
        child: Stack(
          children: [
            Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
                child: Form(
                  key: _formKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _buildAvatarPicker(),
                      const SizedBox(height: 24),
                      Text(
                        l10n.appTitle,
                        style: TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.w600,
                          color: OrigilinkColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        l10n.profileSetupSubtitle,
                        style: TextStyle(
                          fontSize: 14,
                          color: OrigilinkColors.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 40),
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
                          onPressed: _handleContinue,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: OrigilinkColors.primaryDark,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: Text(
                            l10n.continueButton,
                            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (Navigator.canPop(context))
              Positioned(
                top: 8,
                left: 8,
                child: IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.arrow_back, color: OrigilinkColors.textSecondary),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildAvatarPicker() {
    final avatarPath = _avatarPath;
    return GestureDetector(
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
