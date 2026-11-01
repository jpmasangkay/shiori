import 'package:flutter/material.dart';

import '../display_settings.dart';
import '../theme.dart';

Future<void> showDisplaySheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.surface,
    barrierColor: Colors.black.withValues(alpha: .68),
    showDragHandle: false,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    clipBehavior: Clip.antiAlias,
    builder: (_) => const _DisplaySheet(),
  );
}

class _DisplaySheet extends StatelessWidget {
  const _DisplaySheet();

  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.sizeOf(context).height;
    final sheetHeight = (screenHeight * 0.72).clamp(380.0, 560.0);

    return SafeArea(
      top: false,
      child: DefaultTabController(
        length: 2,
        initialIndex: 1,
        child: SizedBox(
          height: sheetHeight,
          child: Column(

          children: [
            Container(
              width: 32,
              height: 4,
              margin: const EdgeInsets.only(top: 10, bottom: 6),
              decoration: BoxDecoration(
                color: AppColors.read,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
            TabBar(
              dividerColor: AppColors.outline,
              indicatorColor: AppColors.primary,
              indicatorSize: TabBarIndicatorSize.label,
              labelColor: AppColors.primary,
              unselectedLabelColor: AppColors.muted,
              labelStyle: AppText.bodySemiBold,
              unselectedLabelStyle: AppText.body,
              overlayColor: const WidgetStatePropertyAll(Colors.transparent),
              tabs: const [Tab(text: 'Sort'), Tab(text: 'Display')],
            ),
            const Expanded(
              child: TabBarView(
                children: [_SortTab(), _DisplayTab()],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

}

class _Heading extends StatelessWidget {
  const _Heading(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 9),
        child: Text(
          text.toUpperCase(),
          style: AppText.sectionHeader,
        ),
      );
}

class _DisplayTab extends StatelessWidget {
  const _DisplayTab();

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: displaySettings,
      builder: (context, _) {
        final s = displaySettings;
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
          children: [
            const _Heading('Display mode'),
            GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              mainAxisExtent: 44,
              children: [
                for (final m in DisplayMode.values)
                  _ModeButton(
                    label: m.label,
                    active: s.mode == m,
                    onTap: () => s.update(() => s.mode = m),
                  ),
              ],
            ),
            const SizedBox(height: 18),
            const _Heading('Grid size'),
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text.rich(
                TextSpan(
                  text: 'Columns: ',
                  children: [
                    TextSpan(
                      text: '${s.columns} per row',
                      style: AppText.bodyMedium.copyWith(color: AppColors.primary),
                    ),
                  ],
                ),
                style: AppText.body,
              ),
            ),
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                activeTrackColor: AppColors.primary,
                inactiveTrackColor: AppColors.outline,
                thumbColor: AppColors.primary,
                overlayColor: AppColors.primary.withValues(alpha: .12),
                activeTickMarkColor: Colors.transparent,
                inactiveTickMarkColor: Colors.transparent,
              ),
              child: Slider(
                min: 2,
                max: 5,
                divisions: 3,
                value: s.columns.toDouble(),
                onChanged: (v) => s.update(() => s.columns = v.round()),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: List.generate(
                  4,
                  (_) => Container(
                    width: 3,
                    height: 3,
                    decoration: const BoxDecoration(color: AppColors.read, shape: BoxShape.circle),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 18),
            const _Heading('Library'),
            _ToggleRow('Category tabs', s.categoryTabs, (v) => s.update(() => s.categoryTabs = v)),
          ],
        );
      },
    );
  }
}

class _ModeButton extends StatelessWidget {
  const _ModeButton({required this.label, required this.active, required this.onTap});
  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: active ? AppColors.surfaceHigh : Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: active ? AppColors.primary : AppColors.outline),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (active) ...[
                  const Icon(Icons.check_rounded, size: 16, color: AppColors.primary),
                  const SizedBox(width: 6),
                ],
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.chip.copyWith(
                      color: active ? AppColors.primary : AppColors.muted,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 36×20 toggle with a 14px thumb, matching `.toggle-row > i`.
class _ToggleRow extends StatelessWidget {
  const _ToggleRow(this.label, this.on, this.onChanged);
  final String label;
  final bool on;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => onChanged(!on),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 44),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.body,
              ),
            ),
            const SizedBox(width: 12),
            AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              width: 36,
              height: 20,
              padding: const EdgeInsets.all(2),
              alignment: on ? Alignment.centerRight : Alignment.centerLeft,
              decoration: BoxDecoration(
                color: on ? AppColors.primary : Colors.transparent,
                border: Border.all(color: on ? AppColors.primary : AppColors.read),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  color: on ? AppColors.onPrimary : AppColors.read,
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SortTab extends StatelessWidget {
  const _SortTab();

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: displaySettings,
      builder: (context, _) {
        final s = displaySettings;
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
          children: [
            const _Heading('Sort by'),
            for (final o in LibrarySort.values)
              InkWell(
                onTap: () => s.update(() => s.sort = o),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 44),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 28,
                        child: o == s.sort
                            ? const Icon(Icons.check_rounded, size: 18, color: AppColors.primary)
                            : null,
                      ),
                      Expanded(
                        child: Text(
                          o.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.body.copyWith(
                            color: o == s.sort ? AppColors.primary : AppColors.text,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
