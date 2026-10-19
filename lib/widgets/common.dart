import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../data.dart';
import '../theme.dart';

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
  const CoverImage(
    this.index, {
    super.key,
    this.imageUrl,
    this.saturation = .7,
    this.fit,
  });

  final int index;
  final String? imageUrl;
  final double saturation;
  final BoxFit? fit;

  @override
  Widget build(BuildContext context) {
    Widget imageWidget;
    if (imageUrl != null && imageUrl!.startsWith('http')) {
      imageWidget = Image.network(
        imageUrl!,
        fit: fit ?? BoxFit.cover,
        width: double.infinity,
        height: double.infinity,
        errorBuilder: (_, _, _) => Image.asset(
          coverAsset(index),
          fit: fit ?? BoxFit.cover,
          width: double.infinity,
          height: double.infinity,
        ),
      );
    } else {
      imageWidget = Image.asset(
        coverAsset(index),
        fit: fit ?? BoxFit.cover,
        cacheWidth: 480,
        width: double.infinity,
        height: double.infinity,
      );
    }

    return ColorFiltered(
      colorFilter: saturate(saturation),
      child: imageWidget,
    );
  }
}

/// The "Shiori" bookmark logo (32×32 viewBox).
class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 28});
  final double size;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: Size.square(size), painter: _BrandPainter());
}

class _BrandPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 32);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(3, 3, 26, 26),
        const Radius.circular(4),
      ),
      Paint()..color = AppColors.onPrimary,
    );
    canvas.drawPath(
      Path()
        ..moveTo(10, 8.5)
        ..lineTo(22, 8.5)
        ..lineTo(22, 24.5)
        ..lineTo(16, 20.5)
        ..lineTo(10, 24.5)
        ..close(),
      Paint()..color = AppColors.primary,
    );
    canvas.drawPath(
      Path()
        ..moveTo(16, 8.5)
        ..lineTo(22, 14)
        ..lineTo(16, 14)
        ..close(),
      Paint()..color = AppColors.surfaceHigh,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
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
  });

  final String title;
  final bool branded;
  final VoidCallback? onBack;
  final List<Widget> actions;
  final bool gradient;

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;
    return Container(
      height: 64 + top,
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
      child: Row(
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
    );
  }
}

/// A two-segment pill: surface-high count + primary unread count.
class CoverBadge extends StatelessWidget {
  const CoverBadge({super.key, required this.left, required this.right, this.showLeft = true, this.showRight = true});
  final String left;
  final String right;
  final bool showLeft;
  final bool showRight;

  @override
  Widget build(BuildContext context) {
    final style = GoogleFonts.inter(fontSize: 10, height: 19 / 10);
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showLeft)
            Container(
              color: AppColors.surfaceHigh,
              padding: const EdgeInsets.symmetric(horizontal: 5),
              child: Text(left, style: style),
            ),
          if (showRight)
            Container(
              color: AppColors.primary,
              padding: const EdgeInsets.symmetric(horizontal: 5),
              child: Text(
                right,
                style: style.copyWith(
                  color: AppColors.onPrimary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
