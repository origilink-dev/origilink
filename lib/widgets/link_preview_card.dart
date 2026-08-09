import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:origilink/screens/login.dart';
import 'package:origilink/src/rust/api/link_preview.dart' as link_preview_api;

/// A Discord/WhatsApp-style "unfurl" card: if [text] contains a bare URL,
/// fetches its Open Graph metadata and shows a small title/description/
/// thumbnail preview under the message, tappable to open the link in the
/// system browser. Shows nothing while loading or if the fetch fails/finds
/// no metadata — a missing preview should never look like an error.
///
/// Previews are cached process-wide by URL so scrolling a bubble in and out
/// of view (which recreates this widget) doesn't refetch every time. Shared
/// between 1:1/group chat (`chat_thread.dart`) and public channels
/// (`global_chat_thread.dart`), since both render plain-text message bodies
/// that may contain a link.
final _urlPattern = RegExp(r'https?://[^\s]+');

/// Splits [text] on bare URLs, rendering them in link-blue and tappable to
/// open in the system browser (with the rest in [baseStyle]) — so a URL is
/// always openable even when [LinkPreviewCard] finds no OGP metadata to
/// unfurl (e.g. a direct link to an image file rather than an HTML page).
TextSpan linkifiedSpan(String text, TextStyle baseStyle) {
  final matches = _urlPattern.allMatches(text);
  if (matches.isEmpty) return TextSpan(text: text, style: baseStyle);

  final spans = <TextSpan>[];
  var last = 0;
  for (final match in matches) {
    if (match.start > last) {
      spans.add(TextSpan(text: text.substring(last, match.start), style: baseStyle));
    }
    final url = match.group(0)!;
    spans.add(
      TextSpan(
        text: url,
        style: baseStyle.copyWith(color: const Color(0xFF1A73E8)),
        recognizer: TapGestureRecognizer()
          ..onTap = () {
            final uri = Uri.tryParse(url);
            if (uri != null) launchUrl(uri, mode: LaunchMode.externalApplication);
          },
      ),
    );
    last = match.end;
  }
  if (last < text.length) {
    spans.add(TextSpan(text: text.substring(last), style: baseStyle));
  }
  return TextSpan(children: spans);
}

class LinkPreviewCard extends StatefulWidget {
  const LinkPreviewCard({super.key, required this.text});

  final String text;

  @override
  State<LinkPreviewCard> createState() => _LinkPreviewCardState();
}

final _imageExtensionPattern = RegExp(r'\.(png|jpe?g|gif|webp|bmp|avif)$', caseSensitive: false);

/// Whether [url]'s path looks like a direct link to an image file — these
/// never carry OGP metadata (there's no HTML page to hold it), so
/// [_LinkPreviewCardState] shows the image itself inline instead of trying
/// (and silently failing) to unfurl it like a regular web link.
bool _looksLikeDirectImageUrl(String url) {
  final path = Uri.tryParse(url)?.path ?? url;
  return _imageExtensionPattern.hasMatch(path);
}

class _LinkPreviewCardState extends State<LinkPreviewCard> {
  static final Map<String, link_preview_api.LinkPreview?> _cache = {};

  link_preview_api.LinkPreview? _preview;
  String? _directImageUrl;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant LinkPreviewCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Defense in depth alongside the `ValueKey(message.id)` callers are
    // expected to pass: without a stable key, ListView/Column can reuse this
    // State for a different message at the same position, and without this
    // check the stale `_preview` from the old message would keep showing.
    if (oldWidget.text != widget.text) {
      setState(() {
        _preview = null;
        _directImageUrl = null;
        _loaded = false;
      });
      _load();
    }
  }

  Future<void> _load() async {
    final url = await link_preview_api.extractFirstUrl(text: widget.text);
    if (url == null || !mounted) return;
    if (_looksLikeDirectImageUrl(url)) {
      setState(() {
        _directImageUrl = url;
        _loaded = true;
      });
      return;
    }
    if (_cache.containsKey(url)) {
      setState(() {
        _preview = _cache[url];
        _loaded = true;
      });
      return;
    }
    try {
      final preview = await link_preview_api.fetchLinkPreview(url: url);
      _cache[url] = preview;
      if (!mounted) return;
      setState(() {
        _preview = preview;
        _loaded = true;
      });
    } catch (_) {
      _cache[url] = null;
      if (!mounted) return;
      setState(() => _loaded = true);
    }
  }

  Future<void> _open() async {
    final url = _preview?.url ?? _directImageUrl;
    if (url == null) return;
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final directImageUrl = _directImageUrl;
    if (directImageUrl != null) {
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: _open,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 240),
              child: Image.network(
                directImageUrl,
                fit: BoxFit.cover,
                loadingBuilder: (context, child, progress) {
                  if (progress == null) return child;
                  return const SizedBox(
                    height: 120,
                    child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
                  );
                },
                errorBuilder: (_, __, ___) => const SizedBox.shrink(),
              ),
            ),
          ),
        ),
      );
    }

    if (!_loaded || _preview == null) return const SizedBox.shrink();
    final preview = _preview!;
    if (preview.title == null && preview.description == null && preview.imageUrl == null) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: _open,
        child: Container(
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.04),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.black.withValues(alpha: 0.08)),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (preview.imageUrl != null)
                AspectRatio(
                  aspectRatio: 1.9,
                  child: Image.network(
                    preview.imageUrl!,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (preview.siteName != null)
                      Text(
                        preview.siteName!.toUpperCase(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: OrigilinkColors.textSecondary.withValues(alpha: 0.8),
                          fontSize: 10.5,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.3,
                        ),
                      ),
                    if (preview.title != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          preview.title!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: OrigilinkColors.textPrimary,
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                            height: 1.25,
                          ),
                        ),
                      ),
                    if (preview.description != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          preview.description!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: OrigilinkColors.textSecondary.withValues(alpha: 0.9),
                            fontSize: 12,
                            height: 1.3,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
