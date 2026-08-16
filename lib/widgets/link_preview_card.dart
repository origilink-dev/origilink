import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:origilink/screens/login.dart';
import 'package:origilink/src/rust/api/link_preview.dart' as link_preview_api;

/// Caps how many prefetch downloads (link previews, their thumbnails,
/// chat attachment images, channel avatars — every background prefetch in
/// the app funnels through this one instance) are ever in flight at once.
/// Not a per-feature budget: it exists purely so a very active screen
/// (a public channel's freshly-primed page, say) can't open unbounded
/// simultaneous connections and exhaust sockets / choke a slow network —
/// any single feature is free to use as much of it as is available.
class _FetchSemaphore {
  _FetchSemaphore(this._maxConcurrent);

  final int _maxConcurrent;
  int _active = 0;
  final _waiting = <Completer<void>>[];

  Future<T> run<T>(Future<T> Function() task) async {
    if (_active >= _maxConcurrent) {
      final completer = Completer<void>();
      _waiting.add(completer);
      await completer.future;
    }
    _active++;
    try {
      return await task();
    } finally {
      _active--;
      if (_waiting.isNotEmpty) {
        _waiting.removeAt(0).complete();
      }
    }
  }
}

final _fetchSemaphore = _FetchSemaphore(60);

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

/// Fires off (and ignores the result of) a fetch for every distinct URL
/// across [texts], so the on-disk/in-memory cache in `link_preview.rs` is
/// already warm by the time a [LinkPreviewCard] actually builds for one of
/// these messages — e.g. call this once for a freshly-loaded page of
/// history so scrolling through it never has to wait on a fetch that could
/// have started already. Errors are swallowed: a failed prefetch just means
/// the real widget fetches (and fails) again later, same as today.
///
/// [persist] should be false for public-channel messages (see
/// [LinkPreviewCard.persistCache]'s doc comment) — the in-memory cache
/// still applies regardless, so scrolling back over the same channel
/// session is still free, it just isn't written to disk.
///
/// Warming `link_preview.rs`'s metadata cache alone isn't enough to avoid a
/// visible pop-in: `Image.network` only starts pulling bytes once its
/// widget actually builds, so without this the thumbnail itself would
/// still only start downloading the moment the card scrolls into view.
/// [precacheNetworkImage] pushes those bytes into Flutter's own
/// `ImageCache` ahead of time too, so the box's reserved space is filled
/// in immediately instead of after a visible network wait.
void prefetchLinkPreviews(Iterable<String> texts, {bool persist = true}) {
  unawaited(() async {
    final storageDir = await getApplicationDocumentsDirectory();
    final seen = <String>{};
    final urls = <String>[];
    for (final text in texts) {
      for (final url in await link_preview_api.extractUrls(text: text)) {
        if (seen.add(url)) urls.add(url);
      }
    }

    Future<void> fetchOne(String url) => _fetchSemaphore.run(() async {
      if (_looksLikeDirectImageUrl(url)) {
        await precacheNetworkImage(url);
        return;
      }
      try {
        final preview = await link_preview_api.fetchLinkPreview(
          storageDir: storageDir.path,
          url: url,
          persist: persist,
        );
        final imageUrl = preview.imageUrl;
        if (imageUrl != null) await precacheNetworkImage(imageUrl);
      } catch (_) {
        // Swallowed — see doc comment.
      }
    });

    // All fired at once, not batched by hand — [_fetchSemaphore] is what
    // actually bounds how many run concurrently, shared across every
    // prefetch caller app-wide (see its doc comment).
    await Future.wait(urls.map(fetchOne));
  }());
}

/// Starts fetching [url] into Flutter's global `ImageCache` without
/// needing a `BuildContext` (unlike `precacheImage`) — safe to call from
/// background prefetch code that runs before/independent of any widget
/// tree. Errors are swallowed the same way the real `Image.network`'s own
/// `errorBuilder` already handles them when it fetches again later.
///
/// Returns once the image has finished loading (or failed) rather than the
/// instant the request starts, so callers that want it to count against
/// [_fetchSemaphore] (see [precacheNetworkImageLimited]) can hold that slot
/// for the download's actual duration, not just the moment it kicks off.
Future<void> precacheNetworkImage(String url) {
  final completer = Completer<void>();
  final stream = NetworkImage(url).resolve(const ImageConfiguration());
  late final ImageStreamListener listener;
  listener = ImageStreamListener(
    (_, _) {
      stream.removeListener(listener);
      if (!completer.isCompleted) completer.complete();
    },
    onError: (_, _) {
      stream.removeListener(listener);
      if (!completer.isCompleted) completer.complete();
    },
  );
  stream.addListener(listener);
  return completer.future;
}

/// [precacheNetworkImage], but counted against the app-wide
/// [_fetchSemaphore] cap — for callers outside this file (e.g. a channel's
/// sender avatars) that aren't already running inside a semaphore-gated
/// task the way [prefetchLinkPreviews]'s own image precaching is.
Future<void> precacheNetworkImageLimited(String url) => _fetchSemaphore.run(() => precacheNetworkImage(url));

/// Runs [task] against the same app-wide [_fetchSemaphore] cap as every
/// other background prefetch (link previews, their thumbnails, channel
/// avatars) — for prefetch work outside this file that isn't image
/// loading, e.g. `chat_thread.dart`'s attachment downloads, so one shared
/// budget bounds all of it together instead of each feature having its
/// own separate concurrency limit stacking on top of the others.
Future<T> withPrefetchLimit<T>(Future<T> Function() task) => _fetchSemaphore.run(task);

/// Renders one [_SingleLinkPreview] per distinct URL found in [text], stacked
/// after all of the message's text — so a message with two pasted links (not
/// just one) gets both unfurled, instead of silently dropping everything
/// after the first.
class LinkPreviewCard extends StatefulWidget {
  const LinkPreviewCard({super.key, required this.text, this.persistCache = true});

  final String text;

  /// Whether a successful fetch may be written to the on-disk cache — pass
  /// false for public-channel messages (see [prefetchLinkPreviews]'s doc
  /// comment for why: an unbounded set of strangers' links shouldn't grow
  /// an on-disk file forever). The in-memory, this-session-only cache still
  /// applies regardless.
  final bool persistCache;

  @override
  State<LinkPreviewCard> createState() => _LinkPreviewCardState();
}

class _LinkPreviewCardState extends State<LinkPreviewCard> {
  List<String>? _urls;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant LinkPreviewCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) {
      setState(() => _urls = null);
      _load();
    }
  }

  Future<void> _load() async {
    final urls = await link_preview_api.extractUrls(text: widget.text);
    if (!mounted) return;
    setState(() => _urls = urls);
  }

  @override
  Widget build(BuildContext context) {
    final urls = _urls;
    if (urls == null || urls.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final url in urls)
          _SingleLinkPreview(key: ValueKey(url), url: url, persistCache: widget.persistCache),
      ],
    );
  }
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

class _SingleLinkPreview extends StatefulWidget {
  const _SingleLinkPreview({super.key, required this.url, required this.persistCache});

  final String url;
  final bool persistCache;

  @override
  State<_SingleLinkPreview> createState() => _SingleLinkPreviewState();
}

class _SingleLinkPreviewState extends State<_SingleLinkPreview> {
  static final Map<String, link_preview_api.LinkPreview?> _cache = {};

  link_preview_api.LinkPreview? _preview;
  String? _directImageUrl;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final url = widget.url;
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
      final storageDir = await getApplicationDocumentsDirectory();
      final preview = await link_preview_api.fetchLinkPreview(
        storageDir: storageDir.path,
        url: url,
        persist: widget.persistCache,
      );
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
    // The fetch can take a few hundred ms, and without this the card pops in
    // at full height afterward, shoving anything below it down abruptly.
    // `AnimatedSize` smooths every height change (skeleton -> loaded content,
    // or skeleton -> nothing if the fetch found no metadata) instead of just
    // the final jump.
    return AnimatedSize(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
      alignment: Alignment.topLeft,
      child: _buildContent(context),
    );
  }

  Widget _buildContent(BuildContext context) {
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

    if (!_loaded) return _buildSkeleton();
    if (_preview == null) return const SizedBox.shrink();
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
            // Deliberately NOT combined with `clipBehavior` on this same
            // Container: clipping to the border's own outer rect shaves off
            // its outside half wherever anti-aliasing lands slightly
            // outside the path, which reads as the border "vanishing" at
            // the bottom/corners. Only the image below gets its own
            // ClipRRect; the border here is left unclipped and always
            // paints in full.
            border: Border.all(color: Colors.black.withValues(alpha: 0.08)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (preview.imageUrl != null)
                ClipRRect(
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(9)),
                  child: AspectRatio(
                    aspectRatio: 1.9,
                    child: Container(
                      color: Colors.white,
                      // `contain`, not `cover`: og:image is often a
                      // near-square logo (Apple, YouTube, ...) rather than a
                      // 1.9:1 banner, and `cover` would crop its top/bottom
                      // off, making it look like the logo bled past the
                      // card's rounded edge instead of just being smaller.
                      child: Image.network(
                        preview.imageUrl!,
                        fit: BoxFit.contain,
                        errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                      ),
                    ),
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

  /// Same footprint as the loaded card (rounded frame, 1.9:1 image band,
  /// two text-line placeholders) so the `AnimatedSize` transition into real
  /// content is a simple fade/reflow rather than growing from nothing.
  Widget _buildSkeleton() {
    Widget bar({double width = double.infinity, double height = 10}) => Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(4),
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.black.withValues(alpha: 0.08)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: const BorderRadius.vertical(top: Radius.circular(9)),
              child: AspectRatio(
                aspectRatio: 1.9,
                child: Container(color: Colors.black.withValues(alpha: 0.03)),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  bar(width: 120, height: 8),
                  const SizedBox(height: 8),
                  bar(height: 10),
                  const SizedBox(height: 6),
                  bar(width: 180, height: 10),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
