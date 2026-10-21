import 'package:flutter/material.dart';
import '../theme.dart';

/// Shimmer effect that pulses a gradient smoothly across its children.
class ShimmerLoading extends StatefulWidget {
  final Widget child;
  final bool isLoading;

  const ShimmerLoading({
    super.key,
    required this.child,
    this.isLoading = true,
  });

  @override
  State<ShimmerLoading> createState() => _ShimmerLoadingState();
}

class _ShimmerLoadingState extends State<ShimmerLoading> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat();

    _animation = Tween<double>(begin: -1.0, end: 2.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOutSine),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.isLoading) return widget.child;

    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) {
        return ShaderMask(
          blendMode: BlendMode.srcATop,
          shaderCallback: (bounds) {
            return LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              stops: [
                (_animation.value - 0.3).clamp(0.0, 1.0),
                _animation.value.clamp(0.0, 1.0),
                (_animation.value + 0.3).clamp(0.0, 1.0),
              ],
              colors: const [
                AppColors.surface,
                AppColors.surfaceHigh,
                AppColors.surface,
              ],
            ).createShader(bounds);
          },
          child: child,
        );
      },
      child: widget.child,
    );
  }
}

/// Generic rounded placeholder block for skeleton layouts.
class SkeletonBox extends StatelessWidget {
  final double? width;
  final double height;
  final double borderRadius;

  const SkeletonBox({
    super.key,
    this.width,
    required this.height,
    this.borderRadius = 8,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: AppColors.surfaceHigh,
        borderRadius: BorderRadius.circular(borderRadius),
      ),
    );
  }
}

/// Skeleton for manga grid cards (e.g. in Catalog, Browse, Library).
class MangaCardSkeleton extends StatelessWidget {
  const MangaCardSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return ShimmerLoading(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: AppColors.surfaceHigh,
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
          const SizedBox(height: 8),
          const SkeletonBox(height: 12, width: double.infinity, borderRadius: 4),
          const SizedBox(height: 4),
          const SkeletonBox(height: 10, width: 80, borderRadius: 4),
        ],
      ),
    );
  }
}

/// Skeleton grid of manga cards.
class MangaGridSkeleton extends StatelessWidget {
  final int count;
  final int crossAxisCount;

  const MangaGridSkeleton({
    super.key,
    this.count = 8,
    this.crossAxisCount = 3,
  });

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.all(12),
      physics: const NeverScrollableScrollPhysics(),
      shrinkWrap: true,
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: crossAxisCount,
        childAspectRatio: 0.62,
        crossAxisSpacing: 10,
        mainAxisSpacing: 12,
      ),
      itemCount: count,
      itemBuilder: (ctx, i) => const MangaCardSkeleton(),
    );
  }
}

/// Skeleton row for chapter tiles in DetailScreen.
class ChapterTileSkeleton extends StatelessWidget {
  const ChapterTileSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return ShimmerLoading(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.surfaceHigh.withValues(alpha: .5)),
        ),
        child: Row(
          children: [
            const SkeletonBox(width: 32, height: 32, borderRadius: 8),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: const [
                  SkeletonBox(height: 13, width: 140, borderRadius: 4),
                  SizedBox(height: 6),
                  SkeletonBox(height: 10, width: 80, borderRadius: 3),
                ],
              ),
            ),
            const SkeletonBox(width: 24, height: 24, borderRadius: 6),
          ],
        ),
      ),
    );
  }
}

/// Skeleton for Updates screen rows.
class UpdateRowSkeleton extends StatelessWidget {
  const UpdateRowSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return ShimmerLoading(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.surfaceHigh),
        ),
        child: Row(
          children: [
            const SkeletonBox(width: 48, height: 68, borderRadius: 8),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: const [
                  SkeletonBox(height: 14, width: 160, borderRadius: 4),
                  SizedBox(height: 8),
                  SkeletonBox(height: 12, width: 100, borderRadius: 4),
                  SizedBox(height: 8),
                  SkeletonBox(height: 10, width: 60, borderRadius: 3),
                ],
              ),
            ),
            const SkeletonBox(width: 36, height: 36, borderRadius: 8),
          ],
        ),
      ),
    );
  }
}

/// Skeleton for extension list items.
class ExtensionTileSkeleton extends StatelessWidget {
  const ExtensionTileSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return ShimmerLoading(
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.surfaceHigh),
        ),
        child: Row(
          children: [
            const SkeletonBox(width: 44, height: 44, borderRadius: 10),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: const [
                  SkeletonBox(height: 14, width: 120, borderRadius: 4),
                  SizedBox(height: 6),
                  SkeletonBox(height: 11, width: 180, borderRadius: 4),
                ],
              ),
            ),
            const SizedBox(width: 10),
            const SkeletonBox(width: 70, height: 32, borderRadius: 8),
          ],
        ),
      ),
    );
  }
}
