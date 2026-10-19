import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../data.dart';
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
        length: 3,
        initialIndex: 2,
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
              dividerColor: AppColors.surfaceHigh,
              indicatorColor: AppColors.primary,
              indicatorSize: TabBarIndicatorSize.label,
              labelColor: AppColors.primary,
              unselectedLabelColor: AppColors.muted,
              labelStyle: GoogleFonts.inter(fontSize: 13),
              unselectedLabelStyle: GoogleFonts.inter(fontSize: 13),
              overlayColor: const WidgetStatePropertyAll(Colors.transparent),
              tabs: const [Tab(text: 'Filter'), Tab(text: 'Sort'), Tab(text: 'Display')],
            ),
            const Expanded(
              child: TabBarView(
                children: [_FilterTab(), _SortTab(), _DisplayTab()],
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
          style: GoogleFonts.inter(
            fontSize: 10,
            fontWeight: FontWeight.w600,
            letterSpacing: .7,
            color: AppColors.muted,
          ),
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
              mainAxisExtent: 38,
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
                      style: const TextStyle(color: AppColors.primary, fontWeight: FontWeight.w500),
                    ),
                  ],
                ),
                style: GoogleFonts.inter(fontSize: 12),
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
            const _Heading('Overlay badges'),
            _ToggleRow('Unread count', s.unreadCount, (v) => s.update(() => s.unreadCount = v)),
            _ToggleRow('Downloaded chapters', s.downloaded, (v) => s.update(() => s.downloaded = v)),
            _ToggleRow('Local source badge', s.localBadge, (v) => s.update(() => s.localBadge = v)),
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
        side: BorderSide(color: active ? Colors.transparent : AppColors.outline),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
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
                  style: GoogleFonts.inter(
                    fontSize: 11,
                    color: active ? AppColors.primary : AppColors.muted,
                  ),
                ),
              ),
            ],
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
      child: SizedBox(
        height: 40,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: GoogleFonts.inter(fontSize: 12)),
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

class _FilterTab extends StatefulWidget {
  const _FilterTab();
  @override
  State<_FilterTab> createState() => _FilterTabState();
}

class _FilterTabState extends State<_FilterTab> {
  final _on = <String, bool>{
    'Downloaded': false,
    'Unread': false,
    'Started': false,
    'Completed': false,
  };

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      children: [
        const _Heading('Filter'),
        for (final e in _on.entries)
          _ToggleRow(e.key, e.value, (v) => setState(() => _on[e.key] = v)),
      ],
    );
  }
}

class _SortTab extends StatefulWidget {
  const _SortTab();
  @override
  State<_SortTab> createState() => _SortTabState();
}

class _SortTabState extends State<_SortTab> {
  static const _options = [
    'Alphabetically',
    'Total chapters',
    'Last read',
    'Last update',
    'Unread count',
  ];
  String _selected = 'Alphabetically';

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      children: [
        const _Heading('Sort by'),
        for (final o in _options)
          InkWell(
            onTap: () => setState(() => _selected = o),
            child: SizedBox(
              height: 40,
              child: Row(
                children: [
                  SizedBox(
                    width: 28,
                    child: o == _selected
                        ? const Icon(Icons.check_rounded, size: 18, color: AppColors.primary)
                        : null,
                  ),
                  Text(
                    o,
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      color: o == _selected ? AppColors.primary : AppColors.text,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
