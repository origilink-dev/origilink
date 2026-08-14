import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:origilink/screens/avatar_crop.dart';

/// Picks an image from the gallery and lets the user crop it to a square,
/// mirroring WhatsApp/Discord-style profile picture selection. The crop UI
/// (`AvatarCropScreen`) is pure Flutter rather than a native platform
/// activity, so it behaves the same across Android versions. The cropped
/// result is downscaled to at most 512x512 and re-encoded as JPEG (quality
/// 85) before being written to a temp file — Rust's upload code (see
/// `account.rs`/`global_chat.rs`) just uploads whatever bytes it's handed.
/// Returns `null` if the user cancels either step.
Future<String?> pickAndCropAvatar(BuildContext context) async {
  final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
  if (picked == null) return null;
  final bytes = await picked.readAsBytes();

  if (!context.mounted) return null;
  final cropped = await Navigator.of(context).push<Uint8List>(
    MaterialPageRoute(builder: (_) => AvatarCropScreen(imageBytes: bytes), fullscreenDialog: true),
  );
  if (cropped == null) return null;

  final decoded = img.decodeImage(cropped);
  if (decoded == null) return null;
  final resized = decoded.width > 512 || decoded.height > 512
      ? img.copyResize(decoded, width: 512, height: 512)
      : decoded;
  final jpg = img.encodeJpg(resized, quality: 85);

  final tempDir = await getTemporaryDirectory();
  final destPath = '${tempDir.path}/avatar_crop_${DateTime.now().millisecondsSinceEpoch}.jpg';
  await File(destPath).writeAsBytes(jpg);
  return destPath;
}
