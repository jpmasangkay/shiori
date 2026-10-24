import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../theme.dart';

/// Standard browser headers for CDN image fetching to bypass Cloudflare and referer blocks.
Map<String, String> imageHeadersForUrl(String url) {
  final uri = Uri.tryParse(url);
  final host = uri?.host.toLowerCase() ?? '';
  String referer = 'https://$host/';
  if (host.contains('comick') || host.contains('meo')) {
    referer = 'https://comick.art/';
  } else if (host.contains('mangadex')) {
    referer = 'https://mangadex.org/';
  } else if (host.contains('asura')) {
    referer = 'https://asuracomic.net/';
  } else if (host.contains('flame')) {
    referer = 'https://flamecomics.xyz/';
  } else if (host.contains('weebcentral')) {
    referer = 'https://weebcentral.com/';
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
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
    'Referer': referer,
    'Accept': 'image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8',
  };
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
    final url = imageUrl;
    if (url == null || !url.startsWith('http')) return const _CoverPlaceholder();

    return ColorFiltered(
      colorFilter: saturate(saturation),
      child: CachedNetworkImage(
        imageUrl: url,
        httpHeaders: imageHeadersForUrl(url),
        fit: fit ?? BoxFit.cover,
        width: double.infinity,
        height: double.infinity,
        placeholder: (_, _) => const _CoverPlaceholder(),
        errorWidget: (_, _, _) => const _CoverPlaceholder(),
      ),
    );
  }
}

class _CoverPlaceholder extends StatelessWidget {
  const _CoverPlaceholder();

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(
      color: AppColors.surfaceHigh,
      child: Center(
        child: Icon(Icons.auto_stories_outlined, color: AppColors.read, size: 24),
      ),
    );
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
