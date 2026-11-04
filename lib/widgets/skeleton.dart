import 'package:flutter/material.dart';
import '../theme.dart';

/// Smooth breathing pulse effect that is lightweight and hardware-accelerated for low-end devices.
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
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);

    _animation = Tween<double>(begin: 0.38, end: 0.95).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
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

    return RepaintBoundary(
      child: FadeTransition(
        opacity: _animation,
        child: widget.child,
      ),
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

/// Skeleton that mirrors the source catalog grid (2:3 covers with the title
/// overlaid at the bottom) so the swap to real content doesn't jump.
class CatalogGridSkeleton extends StatelessWidget {
  const CatalogGridSkeleton({super.key, this.count = 12});

  final int count;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final cols = (width / 115).clamp(2, 6).floor();
    return ShimmerLoading(
      child: GridView.builder(
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 20),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: cols,
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
          childAspectRatio: 2 / 3,
        ),
        itemCount: count,
        itemBuilder: (_, i) => Container(
          decoration: BoxDecoration(
            color: AppColors.surfaceHigh,
            borderRadius: BorderRadius.circular(6),
          ),
          padding: const EdgeInsets.all(7),
          child: const Column(
            mainAxisAlignment: MainAxisAlignment.end,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SkeletonBox(height: 10, width: double.infinity, borderRadius: 3),
              SizedBox(height: 4),
              SkeletonBox(height: 10, width: 50, borderRadius: 3),
            ],
          ),
        ),
      ),
    );
  }
}

/// Horizontal row of cover skeletons, matching the global search result rows.
class MangaRowSkeleton extends StatelessWidget {
  const MangaRowSkeleton({super.key, this.count = 5, this.height = 180, this.itemWidth = 105});

  final int count;
  final double height;
  final double itemWidth;

  @override
  Widget build(BuildContext context) {
    return ShimmerLoading(
      child: SizedBox(
        height: height,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: count,
          separatorBuilder: (_, _) => const SizedBox(width: 8),
          itemBuilder: (_, i) => SizedBox(
            width: itemWidth,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: AppColors.surfaceHigh,
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                const SkeletonBox(height: 10, width: double.infinity, borderRadius: 3),
                const SizedBox(height: 4),
                const SkeletonBox(height: 10, width: 60, borderRadius: 3),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Skeleton for compact list rows with a small cover (History).
class HistoryRowSkeleton extends StatelessWidget {
  const HistoryRowSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return const ShimmerLoading(
      child: SizedBox(
        height: 64,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 14, vertical: 4),
          child: Row(
            children: [
              SkeletonBox(width: 44, height: 56, borderRadius: 4),
              SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SkeletonBox(height: 13, width: 170, borderRadius: 4),
                    SizedBox(height: 6),
                    SkeletonBox(height: 10, width: 110, borderRadius: 3),
                  ],
                ),
              ),
              SkeletonBox(width: 28, height: 28, borderRadius: 14),
            ],
          ),
        ),
      ),
    );
  }
}

/// Fades and slides its child in once when first built. Used so content that
/// replaces a skeleton eases in instead of popping.
class FadeSlideIn extends StatelessWidget {
  const FadeSlideIn({
    super.key,
    required this.child,
    this.duration = const Duration(milliseconds: 320),
    this.delay = Duration.zero,
    this.offset = 12,
  });

  final Widget child;
  final Duration duration;
  final Duration delay;
  final double offset;

  @override
  Widget build(BuildContext context) {
    final total = duration + delay;
    final start = total.inMilliseconds == 0 ? 0.0 : delay.inMilliseconds / total.inMilliseconds;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: total,
      curve: Interval(start, 1, curve: Curves.easeOutCubic),
      child: child,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(offset: Offset(0, (1 - t) * offset), child: child),
      ),
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
