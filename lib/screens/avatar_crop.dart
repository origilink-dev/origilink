import 'dart:typed_data';

import 'package:crop_your_image/crop_your_image.dart';
import 'package:flutter/material.dart';
import 'package:origilink/l10n/app_localizations.dart';

/// WhatsApp-style "pick then crop to a circle" step, implemented as a pure
/// Flutter widget (no native platform crop UI) so it behaves identically
/// across Android versions/API levels instead of depending on a
/// platform-specific native activity.
class AvatarCropScreen extends StatefulWidget {
  const AvatarCropScreen({super.key, required this.imageBytes});

  final Uint8List imageBytes;

  @override
  State<AvatarCropScreen> createState() => _AvatarCropScreenState();
}

class _AvatarCropScreenState extends State<AvatarCropScreen> {
  final _controller = CropController();
  bool _cropping = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          IconButton(
            icon: _cropping
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : const Icon(Icons.check),
            onPressed: _cropping ? null : () => _controller.crop(),
          ),
        ],
      ),
      body: Crop(
        controller: _controller,
        image: widget.imageBytes,
        aspectRatio: 1,
        withCircleUi: true,
        baseColor: Colors.black,
        maskColor: Colors.black.withValues(alpha: 0.6),
        progressIndicator: const CircularProgressIndicator(color: Colors.white),
        onStatusChanged: (status) {
          setState(() => _cropping = status == CropStatus.cropping);
        },
        onCropped: (result) {
          switch (result) {
            case CropSuccess(:final croppedImage):
              Navigator.of(context).pop(croppedImage);
            case CropFailure():
              if (!mounted) return;
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(SnackBar(content: Text(l10n.avatarCropFailed)));
          }
        },
      ),
    );
  }
}
