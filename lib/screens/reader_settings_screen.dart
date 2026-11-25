import 'package:flutter/material.dart';

import '../services/reader_settings.dart';
import '../theme.dart';

/// Global Reader Settings screen exposing default reading direction (separate
/// from per-manga overrides), comfort overlays, hardware controls, layout, and
/// image processing defaults.
class ReaderSettingsScreen extends StatelessWidget {
  const ReaderSettingsScreen({super.key});

  static const _directions = [
    ('automatic', 'Automatic (Smart Detection)'),
    ('rightToLeft', 'Right to Left (Manga)'),
    ('webtoon', 'Webtoon (Manhwa / Manhua)'),
    ('leftToRight', 'Left to Right (Western Comics)'),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        elevation: 0,
        title: Text('Reader Settings', style: AppText.title),
      ),
      body: ListenableBuilder(
        listenable: ReaderSettings.instance,
        builder: (context, _) {
          final rs = ReaderSettings.instance;
          return ListView(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            children: [
              _header('DEFAULT READING MODE'),
              _card([
                ListTile(
                  title: Text('Default Reading Direction', style: AppText.bodyMedium),
                  subtitle: Text(
                    _directions
                        .firstWhere(
                          (d) => d.$1 == rs.defaultDirection,
                          orElse: () => _directions.first,
                        )
                        .$2,
                    style: AppText.caption.copyWith(color: AppColors.primary),
                  ),
                  trailing: Icon(Icons.chevron_right_rounded, color: AppColors.muted),
                  onTap: () => _pickDirection(context, rs),
                ),
                Divider(color: AppColors.outline, height: 1),
                ListTile(
                  title: Text('Image Fit Mode', style: AppText.bodyMedium),
                  subtitle: Text(
                    rs.fitMode == BoxFit.fitWidth ? 'Fit Width' : 'Fit Screen (Contain)',
                    style: AppText.caption.copyWith(color: AppColors.primary),
                  ),
                  trailing: SegmentedButton<BoxFit>(
                    segments: const [
                      ButtonSegment(value: BoxFit.contain, label: Text('Fit')),
                      ButtonSegment(value: BoxFit.fitWidth, label: Text('Width')),
                    ],
                    selected: {rs.fitMode},
                    onSelectionChanged: (s) => rs.setFitMode(s.first),
                  ),
                ),
                Divider(color: AppColors.outline, height: 1),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Reader Background', style: AppText.bodyMedium),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final bg in ReaderBackground.values)
                            ChoiceChip(
                              label: Text(bg.label),
                              selected: rs.background == bg,
                              onSelected: (_) => rs.setBackground(bg),
                              selectedColor: AppColors.active,
                              backgroundColor: AppColors.surfaceHigh,
                              labelStyle: AppText.chip.copyWith(
                                color: rs.background == bg ? AppColors.primary : AppColors.muted,
                              ),
                              showCheckmark: false,
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ]),

              const SizedBox(height: 20),
              _header('SCREEN & HARDWARE'),
              _card([
                SwitchListTile(
                  value: rs.keepScreenOn,
                  activeThumbColor: AppColors.primary,
                  title: Text('Keep Screen Awake', style: AppText.bodyMedium),
                  subtitle: Text('Prevents screen sleep while reading', style: AppText.caption),
                  onChanged: rs.setKeepScreenOn,
                ),
                Divider(color: AppColors.outline, height: 1),
                SwitchListTile(
                  value: rs.immersiveFullscreen,
                  activeThumbColor: AppColors.primary,
                  title: Text('Immersive Fullscreen', style: AppText.bodyMedium),
                  subtitle: Text('Hide system status & navigation bars while reading', style: AppText.caption),
                  onChanged: rs.setImmersiveFullscreen,
                ),
                Divider(color: AppColors.outline, height: 1),
                SwitchListTile(
                  value: rs.showReadingStatusBar,
                  activeThumbColor: AppColors.primary,
                  title: Text('Minimal Reading Status Bar', style: AppText.bodyMedium),
                  subtitle: Text('Show subtle page number & clock when menus are hidden', style: AppText.caption),
                  onChanged: rs.setShowReadingStatusBar,
                ),
                Divider(color: AppColors.outline, height: 1),
                SwitchListTile(
                  value: rs.volumeKeyNavigation,
                  activeThumbColor: AppColors.primary,
                  title: Text('Volume Key Navigation', style: AppText.bodyMedium),
                  subtitle: Text('Use hardware volume buttons to turn pages', style: AppText.caption),
                  onChanged: rs.setVolumeKeyNavigation,
                ),
                if (rs.volumeKeyNavigation) ...[
                  Divider(color: AppColors.outline, height: 1),
                  SwitchListTile(
                    value: rs.invertVolumeKeys,
                    activeThumbColor: AppColors.primary,
                    title: Text('Invert Volume Keys', style: AppText.bodyMedium),
                    subtitle: Text('Swap Volume Up / Volume Down page direction', style: AppText.caption),
                    onChanged: rs.setInvertVolumeKeys,
                  ),
                ],
                Divider(color: AppColors.outline, height: 1),
                SwitchListTile(
                  value: rs.enableTapZones,
                  activeThumbColor: AppColors.primary,
                  title: Text('Tap Zones Navigation', style: AppText.bodyMedium),
                  subtitle: Text('Tap screen edges to turn pages, center for menu', style: AppText.caption),
                  onChanged: rs.setEnableTapZones,
                ),
                if (rs.enableTapZones) ...[
                  Divider(color: AppColors.outline, height: 1),
                  SwitchListTile(
                    value: rs.invertTapZones,
                    activeThumbColor: AppColors.primary,
                    title: Text('Invert Tap Zones', style: AppText.bodyMedium),
                    subtitle: Text('Flip left and right edge actions', style: AppText.caption),
                    onChanged: rs.setInvertTapZones,
                  ),
                  Divider(color: AppColors.outline, height: 1),
                  SwitchListTile(
                    value: rs.webtoonTapScroll,
                    activeThumbColor: AppColors.primary,
                    title: Text('Webtoon Tap-to-Scroll', style: AppText.bodyMedium),
                    subtitle: Text('Tap top/bottom edges to smoothly scroll in Webtoon mode', style: AppText.caption),
                    onChanged: rs.setWebtoonTapScroll,
                  ),
                ],
                Divider(color: AppColors.outline, height: 1),
                SwitchListTile(
                  value: rs.skipDuplicateChapters,
                  activeThumbColor: AppColors.primary,
                  title: Text('Skip Duplicate Chapters', style: AppText.bodyMedium),
                  subtitle: Text('Automatically skip duplicate chapter numbers from other scanlators', style: AppText.caption),
                  onChanged: rs.setSkipDuplicateChapters,
                ),
                Divider(color: AppColors.outline, height: 1),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Screen Orientation', style: AppText.bodyMedium),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final ori in ReaderOrientation.values)
                            ChoiceChip(
                              label: Text(ori.label),
                              selected: rs.orientation == ori,
                              onSelected: (_) => rs.setOrientation(ori),
                              selectedColor: AppColors.active,
                              backgroundColor: AppColors.surfaceHigh,
                              labelStyle: AppText.chip.copyWith(
                                color: rs.orientation == ori ? AppColors.primary : AppColors.muted,
                              ),
                              showCheckmark: false,
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ]),

              const SizedBox(height: 20),
              _header('LAYOUT & IMAGE PROCESSING'),
              _card([
                SwitchListTile(
                  value: rs.dualPageSpread,
                  activeThumbColor: AppColors.primary,
                  title: Text('Double-Page Spread (Landscape)', style: AppText.bodyMedium),
                  subtitle: Text('Display two pages side by side on tablets & landscape', style: AppText.caption),
                  onChanged: rs.setDualPageSpread,
                ),
                Divider(color: AppColors.outline, height: 1),
                SwitchListTile(
                  value: rs.cropBorders,
                  activeThumbColor: AppColors.primary,
                  title: Text('Crop Page Margins', style: AppText.bodyMedium),
                  subtitle: Text('Trim excess whitespace along page edges', style: AppText.caption),
                  onChanged: rs.setCropBorders,
                ),
                Divider(color: AppColors.outline, height: 1),
                SwitchListTile(
                  value: rs.grayscaleFilter,
                  activeThumbColor: AppColors.primary,
                  title: Text('Grayscale Filter', style: AppText.bodyMedium),
                  subtitle: Text('Render all pages in monochrome grayscale', style: AppText.caption),
                  onChanged: rs.setGrayscaleFilter,
                ),
                Divider(color: AppColors.outline, height: 1),
                SwitchListTile(
                  value: rs.invertColors,
                  activeThumbColor: AppColors.primary,
                  title: Text('Invert Colors', style: AppText.bodyMedium),
                  subtitle: Text('Invert white manga backgrounds for night reading', style: AppText.caption),
                  onChanged: rs.setInvertColors,
                ),
                Divider(color: AppColors.outline, height: 1),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('Webtoon Side Padding', style: AppText.bodyMedium),
                          Text(
                            '${(rs.webtoonSidePadding * 100).round()}%',
                            style: AppText.caption.copyWith(color: AppColors.primary),
                          ),
                        ],
                      ),
                      Slider(
                        value: rs.webtoonSidePadding,
                        min: 0.0,
                        max: 0.25,
                        divisions: 5,
                        activeColor: AppColors.primary,
                        onChanged: rs.setWebtoonSidePadding,
                      ),
                    ],
                  ),
                ),
                Divider(color: AppColors.outline, height: 1),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('Auto-Scroll Speed', style: AppText.bodyMedium),
                          Text(
                            '${rs.autoScrollSpeed.toStringAsFixed(1)}x',
                            style: AppText.caption.copyWith(color: AppColors.primary),
                          ),
                        ],
                      ),
                      Slider(
                        value: rs.autoScrollSpeed,
                        min: 0.25,
                        max: 3.0,
                        divisions: 11,
                        activeColor: AppColors.primary,
                        onChanged: rs.setAutoScrollSpeed,
                      ),
                    ],
                  ),
                ),
                Divider(color: AppColors.outline, height: 1),
                SwitchListTile(
                  value: rs.dataSaver,
                  activeThumbColor: AppColors.primary,
                  title: Text('Data Saver Mode', style: AppText.bodyMedium),
                  subtitle: Text('Load compressed images and conserve prefetch bandwidth', style: AppText.caption),
                  onChanged: rs.setDataSaver,
                ),
              ]),
              const SizedBox(height: 24),
            ],
          );
        },
      ),
    );
  }

  void _pickDirection(BuildContext context, ReaderSettings rs) {
    showDialog<void>(
      context: context,
      builder: (ctx) => SimpleDialog(
        backgroundColor: AppColors.surface,
        title: Text('Default Reading Direction', style: AppText.sheetTitle),
        children: [
          for (final (key, label) in _directions)
            ListTile(
              title: Text(label, style: AppText.body),
              trailing: rs.defaultDirection == key
                  ? Icon(Icons.check_rounded, color: AppColors.primary)
                  : null,
              onTap: () {
                rs.setDefaultReadingDirection(key);
                Navigator.pop(ctx);
              },
            ),
        ],
      ),
    );
  }

  Widget _header(String label) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(label, style: AppText.sectionHeader),
    );
  }

  Widget _card(List<Widget> children) {
    return Material(
      color: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: AppColors.outline),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(children: children),
    );
  }
}
