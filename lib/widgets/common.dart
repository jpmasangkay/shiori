import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../theme.dart';
import 'skeleton.dart';

const String _browserUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';
const String _imageAccept = 'image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8';

/// Learned image host -> referer mappings (e.g. for community extensions whose
/// CDN hosts we can't know ahead of time). Populated by the API layer once it
/// knows which source an image URL belongs to.
class ImageReferers {
  ImageReferers._();

  static final Map<String, String> _hostReferers = {};

  /// Remembers that images served from [imageUrl]'s host must be requested
  /// with [referer] (usually the source's base URL).
  static void register(String imageUrl, String referer) {
    if (referer.isEmpty) return;
    final host = Uri.tryParse(imageUrl)?.host.toLowerCase() ?? '';
    if (host.isEmpty) return;
    var ref = referer.trim();
    if (!ref.startsWith('http')) return;
    if (!ref.endsWith('/')) ref = '$ref/';
    _hostReferers[host] = ref;
  }

  /// Registers [referer] for every URL in [imageUrls].
  static void registerAll(Iterable<String> imageUrls, String referer) {
    for (final u in imageUrls) {
      register(u, referer);
    }
  }

  static String? lookup(String host) => _hostReferers[host];
}

/// Standard browser headers for CDN image fetching to bypass Cloudflare and referer blocks.
Map<String, String> imageHeadersForUrl(String url) {
  final uri = Uri.tryParse(url);
  final host = uri?.host.toLowerCase() ?? '';
  final learned = ImageReferers.lookup(host);
  if (learned != null) {
    return {'User-Agent': _browserUserAgent, 'Referer': learned, 'Accept': _imageAccept};
  }
  String referer = 'https://$host/';
  if (host.contains('comick') || host.contains('meo')) {
    referer = 'https://comick.art/';
  } else if (host.contains('mangadex')) {
    referer = 'https://mangadex.org/';
  } else if (host.contains('asurascans')) {
    referer = 'https://asurascans.com/';
  } else if (host.contains('asura')) {
    referer = 'https://asuracomic.net/';
  } else if (host.contains('flame')) {
    referer = 'https://flamecomics.xyz/';
  } else if (host.contains('weebcentral') || host.contains('planeptune') || host.contains('compsci88')) {
    referer = 'https://weebcentral.com/';
  } else if (host.contains('pstatic') || host.contains('webtoon')) {
    referer = 'https://www.webtoons.com/';
  } else if (host.contains('bato') || host.contains('battwo') || host.contains('batotoo')) {
    referer = 'https://bato.to/';
  } else if (host.contains('mangapark')) {
    referer = 'https://mangapark.net/';
  } else if (host.contains('fanfox') || host.contains('mangafox')) {
    referer = 'https://fanfox.net/';
  } else if (host.contains('readdetectiveconan') || host.contains('mangapill')) {
    referer = 'https://mangapill.com/';
  } else if (host.contains('mangakatana')) {
    referer = 'https://mangakatana.com/';
  } else if (host.contains('mangaread')) {
    referer = 'https://www.mangaread.org/';
  } else if (host.contains('manganato') || host.contains('chapmanganato')) {
    referer = 'https://chapmanganato.to/';
  } else if (host.contains('mangakakalot')) {
    referer = 'https://mangakakalot.com/';
  }
  return {
    'User-Agent': _browserUserAgent,
    'Referer': referer,
    'Accept': _imageAccept,
  };
}

/// Alternative header sets to try when an image fails with the default
/// headers. Different CDNs reject different referers, so we fall back to no
/// referer and then to the image's own origin.
List<Map<String, String>> imageHeaderVariants(String url) {
  final primary = imageHeadersForUrl(url);
  final host = Uri.tryParse(url)?.host ?? '';
  final variants = <Map<String, String>>[
    primary,
    {'User-Agent': _browserUserAgent, 'Accept': _imageAccept},
    if (host.isNotEmpty) {'User-Agent': _browserUserAgent, 'Referer': 'https://$host/', 'Accept': _imageAccept},
  ];
  // Drop duplicates (e.g. when the primary referer already is the origin).
  final seen = <String>{};
  return [
    for (final v in variants)
      if (seen.add(v['Referer'] ?? '<none>')) v,
  ];
}

/// Equivalent of the CSS `filter: saturate(x)`.
ColorFilter saturate(double s) {
  const r = 0.213, g = 0.715, b = 0.072;
  return ColorFilter.matrix(<double>[
    r + (1 - r) * s, g - g * s, b - b * s, 0, 0, //
    r - r * s, g + (1 - g) * s, b - b * s, 0, 0, //
    r - r * s, g - g * s, b + (1 - b) * s, 0, 0, //
    0, 0, 0, 1, 0,
  ]);
}

/// Network image that never gives up on the first failure: it automatically
/// retries with alternative headers / fallback URLs, and finally hands a
/// `retry` callback to [errorBuilder] so the user can try again manually.
class RetryingNetworkImage extends StatefulWidget {
  const RetryingNetworkImage({
    super.key,
    required this.url,
    this.fallbackUrls = const [],
    this.fit,
    this.width,
    this.height,
    this.placeholder,
    this.progressBuilder,
    this.errorBuilder,
    this.fadeInDuration = const Duration(milliseconds: 280),
  });

  final String url;
  final List<String> fallbackUrls;
  final BoxFit? fit;
  final double? width;
  final double? height;
  final WidgetBuilder? placeholder;
  final Widget Function(BuildContext context, double? progress)? progressBuilder;
  final Widget Function(BuildContext context, VoidCallback retry)? errorBuilder;
  final Duration fadeInDuration;

  /// Remembers which header variant worked per host so later images from the
  /// same CDN load on the first try.
  static final Map<String, int> _workingVariantByHost = {};

  @override
  State<RetryingNetworkImage> createState() => _RetryingNetworkImageState();
}

class _RetryingNetworkImageState extends State<RetryingNetworkImage> {
  late List<(String, Map<String, String>, int)> _attempts;
  int _attempt = 0;
  int _generation = 0;
  bool _exhausted = false;
  bool _retryScheduled = false;
  Timer? _retryTimer;

  @override
  void initState() {
    super.initState();
    _buildAttempts();
  }

  @override
  void didUpdateWidget(covariant RetryingNetworkImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url || !listEquals(oldWidget.fallbackUrls, widget.fallbackUrls)) {
      _retryTimer?.cancel();
      _attempt = 0;
      _exhausted = false;
      _retryScheduled = false;
      _buildAttempts();
    }
  }

  @override
  void dispose() {
    _retryTimer?.cancel();
    super.dispose();
  }

  void _buildAttempts() {
    final urls = <String>[widget.url, ...widget.fallbackUrls.where((u) => u.startsWith('http') && u != widget.url)];
    final attempts = <(String, Map<String, String>, int)>[];
    for (final u in urls) {
      final variants = imageHeaderVariants(u);
      final host = Uri.tryParse(u)?.host ?? '';
      final preferred = RetryingNetworkImage._workingVariantByHost[host];
      final order = [for (var i = 0; i < variants.length; i++) i];
      if (preferred != null && preferred < variants.length) {
        order
          ..remove(preferred)
          ..insert(0, preferred);
      }
      for (final i in order) {
        attempts.add((u, variants[i], i));
      }
    }
    _attempts = attempts;
  }

  void _onError() {
    if (_retryScheduled || _exhausted) return;
    _retryScheduled = true;
    final failed = _attempts[_attempt];
    // Make sure the failed stream isn't served from the memory cache again.
    CachedNetworkImageProvider(failed.$1).evict().catchError((_) => false);

    if (_attempt + 1 >= _attempts.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() {
          _exhausted = true;
          _retryScheduled = false;
        });
      });
      return;
    }
    // Small backoff so flaky CDNs get a moment to recover.
    _retryTimer = Timer(Duration(milliseconds: 250 + 200 * _attempt), () {
      if (!mounted) return;
      setState(() {
        _attempt++;
        _retryScheduled = false;
      });
    });
  }

  void _manualRetry() {
    _retryTimer?.cancel();
    for (final a in _attempts) {
      CachedNetworkImageProvider(a.$1).evict().catchError((_) => false);
    }
    setState(() {
      _attempt = 0;
      _generation++;
      _exhausted = false;
      _retryScheduled = false;
    });
  }

  Widget _placeholder(BuildContext context) =>
      widget.placeholder?.call(context) ?? const _CoverPlaceholder(loading: true);

  @override
  Widget build(BuildContext context) {
    if (_exhausted) {
      return widget.errorBuilder?.call(context, _manualRetry) ?? const _CoverPlaceholder();
    }
    final (url, headers, variantIndex) = _attempts[_attempt];
    final progressBuilder = widget.progressBuilder;

    return CachedNetworkImage(
      key: ValueKey('$url#$_attempt#$_generation'),
      imageUrl: url,
      httpHeaders: headers,
      fit: widget.fit,
      width: widget.width,
      height: widget.height,
      fadeInDuration: widget.fadeInDuration,
      fadeOutDuration: const Duration(milliseconds: 120),
      placeholder: progressBuilder == null ? (ctx, _) => _placeholder(ctx) : null,
      progressIndicatorBuilder: progressBuilder == null
          ? null
          : (ctx, _, p) => progressBuilder(ctx, p.progress),
      imageBuilder: (ctx, provider) {
        final host = Uri.tryParse(url)?.host ?? '';
        if (host.isNotEmpty) RetryingNetworkImage._workingVariantByHost[host] = variantIndex;
        return Image(
          image: provider,
          fit: widget.fit,
          width: widget.width,
          height: widget.height,
          gaplessPlayback: true,
        );
      },
      errorWidget: (ctx, _, _) {
        _onError();
        // Keep showing the loading state while the next attempt is queued.
        return progressBuilder?.call(ctx, null) ?? _placeholder(ctx);
      },
    );
  }
}

class CoverImage extends StatelessWidget {
  const CoverImage({
    super.key,
    this.imageUrl,
    this.saturation = .7,
    this.fit,
  });

  final String? imageUrl;
  final double saturation;
  final BoxFit? fit;

  @override
  Widget build(BuildContext context) {
    var url = imageUrl?.trim();
    if (url != null && url.startsWith('//')) url = 'https:$url';
    if (url == null || !url.startsWith('http')) return const _CoverPlaceholder();

    return ColorFiltered(
      colorFilter: saturate(saturation),
      child: RetryingNetworkImage(
        url: url,
        fit: fit ?? BoxFit.cover,
        width: double.infinity,
        height: double.infinity,
      ),
    );
  }
}

class _CoverPlaceholder extends StatelessWidget {
  const _CoverPlaceholder({this.loading = false});

  final bool loading;

  @override
  Widget build(BuildContext context) {
    const box = ColoredBox(
      color: AppColors.surfaceHigh,
      child: Center(
        child: Icon(Icons.auto_stories_outlined, color: AppColors.read, size: 24),
      ),
    );
    if (!loading) return box;
    return const ShimmerLoading(child: SizedBox.expand(child: box));
  }
}

/// Centered icon + title + message, used for empty and error states.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.action,
  });

  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: AppColors.read),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            if (message != null) ...[
              const SizedBox(height: 8),
              Text(
                message!,
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(fontSize: 12, color: AppColors.muted, height: 1.5),
              ),
            ],
            if (action != null) ...[
              const SizedBox(height: 16),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

/// The "Shiori" logo icon.
class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 28});
  final double size;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.22),
      child: Image.asset(
        'assets/logo.png',
        width: size,
        height: size,
        fit: BoxFit.cover,
      ),
    );
  }
}


class BarIcon extends StatelessWidget {
  const BarIcon(this.icon, {super.key, this.label, this.onTap, this.size = 22});
  final IconData icon;
  final String? label;
  final VoidCallback? onTap;
  final double size;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onTap ?? () {},
      tooltip: label,
      icon: Icon(icon, size: size),
      color: AppColors.text,
      constraints: const BoxConstraints.tightFor(width: 40, height: 40),
      padding: EdgeInsets.zero,
      splashRadius: 20,
    );
  }
}

class AppTopBar extends StatelessWidget {
  const AppTopBar({
    super.key,
    required this.title,
    this.branded = false,
    this.onBack,
    this.actions = const [],
    this.gradient = false,
    this.bottom,
  });

  final String title;
  final bool branded;
  final VoidCallback? onBack;
  final List<Widget> actions;
  final bool gradient;
  final PreferredSizeWidget? bottom;

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;
    final bottomHeight = bottom?.preferredSize.height ?? 0;
    return Container(
      height: 64 + top + bottomHeight,
      padding: EdgeInsets.fromLTRB(onBack != null ? 4 : 12, top + 8, 8, 0),
      decoration: gradient
          ? BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  AppColors.bg.withValues(alpha: .7),
                  Colors.transparent,
                ],
              ),
            )
          : null,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              if (onBack != null)
                BarIcon(Icons.arrow_back_rounded, label: 'Back', onTap: onBack),
              if (branded) ...[const BrandMark(size: 28), const SizedBox(width: 10)],
              Expanded(
                child: Text(
                  title,
                  style: GoogleFonts.inter(fontSize: 18, fontWeight: FontWeight.w600),
                ),
              ),
              ...actions,
            ],
          ),
          ?bottom,
        ],
      ),
    );
  }
}

/// Smooth fade + micro-slide route transition used across detail, catalog, and reader screens.
Route<T> smoothRoute<T>(Widget page) {
  return PageRouteBuilder<T>(
    transitionDuration: const Duration(milliseconds: 240),
    reverseTransitionDuration: const Duration(milliseconds: 200),
    pageBuilder: (context, animation, secondaryAnimation) => page,
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      return FadeTransition(
        opacity: curved,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.025),
            end: Offset.zero,
          ).animate(curved),
          child: child,
        ),
      );
    },
  );
}
