import 'dart:async';
import 'package:flutter/material.dart';

import '../services/extension_service.dart';
import '../services/source_manager.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/skeleton.dart';
import 'source_catalog_screen.dart';

class ExtensionsScreen extends StatefulWidget {
  const ExtensionsScreen({super.key, this.isEmbedded = false});

  final bool isEmbedded;

  @override
  State<ExtensionsScreen> createState() => _ExtensionsScreenState();
}

class _ExtensionsScreenState extends State<ExtensionsScreen> {
  final _searchController = TextEditingController();
  final _service = ExtensionService.instance;
  Timer? _searchDebounce;
  String _query = '';
  String _selectedLang = 'ALL';
  bool _showNsfw = true;

  final List<String> _commonLangs = ['ALL', 'EN', 'ES', 'JA', 'KO', 'ZH', 'FR', 'ID', 'RU'];

  @override
  void initState() {
    super.initState();
    _service.addListener(_onServiceUpdate);
    if (!SourceManager.isIOSPlatform && _service.extensions.isEmpty && !_service.isLoading) {
      _service.fetchExtensions();
    }
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _service.removeListener(_onServiceUpdate);
    _searchController.dispose();
    super.dispose();
  }

  void _onServiceUpdate() {
    if (mounted) setState(() {});
  }

  void _addRepoDialog() {
    final controller = TextEditingController(text: _service.repoUrl);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        scrollable: true,
        title: Row(
          children: [
            const Icon(Icons.hub_rounded, color: AppColors.primary, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Extension Repository',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.sheetTitle,
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Keiyoushi repo.json / index_v2 (index.pb):',
              style: AppText.caption.copyWith(color: AppColors.muted),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              style: AppText.body,
              maxLines: 2,
              decoration: InputDecoration(
                hintText: 'https://raw.githubusercontent.com/keiyoushi/extensions/repo/repo.json',
                hintStyle: AppText.caption.copyWith(color: AppColors.read),
                filled: true,
                fillColor: AppColors.surfaceHigh,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
              ),
            ),
            const SizedBox(height: 8),
            if (_service.repoMetadata != null && _service.repoMetadata!.signingKeyFingerprint.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  'Signing key: ${_service.repoMetadata!.signingKeyFingerprint.substring(0, 16)}…',
                  style: AppText.mono.copyWith(fontSize: 10.5, color: AppColors.muted),
                ),
              ),
            Text(
              'Supports Keiyoushi repo.json (index_v2 protobuf) with 1,400+ extensions and PackageInstaller support.',
              style: AppText.caption.copyWith(color: AppColors.muted, fontStyle: FontStyle.italic),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              controller.text = ExtensionService.defaultRepoUrl;
            },
            child: Text('Reset Default', style: AppText.bodyMedium.copyWith(color: AppColors.muted)),
          ),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              final newUrl = controller.text.trim();
              Navigator.pop(ctx);
              _service.setRepoUrl(newUrl);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Syncing repository...')),
              );
            },
            child: const Text('Save & Sync'),
          ),
        ],
      ),
    );
  }

  void _showExtensionDetails(MangaExtension initialExt) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => ListenableBuilder(
        listenable: _service,
        builder: (ctx, _) {
          final ext = _service.getExtensionByPkg(initialExt.pkg) ?? initialExt;
          return DraggableScrollableSheet(
            initialChildSize: 0.55,
            minChildSize: 0.35,
            maxChildSize: 0.85,
            expand: false,
            builder: (_, scrollCtrl) => ListView(
              controller: scrollCtrl,
              padding: const EdgeInsets.all(20),
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: AppColors.outline,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    _buildIcon(ext, size: 54),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            ext.name,
                            style: AppText.sheetTitle,
                          ),
                          const SizedBox(height: 4),
                          Wrap(
                            spacing: 6,
                            runSpacing: 4,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: AppColors.primary.withValues(alpha: .2),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  ext.lang,
                                  style: AppText.badge.copyWith(color: AppColors.primary),
                                ),
                              ),
                              Text(
                                ext.hasUpdate && ext.repoVersion != null
                                    ? 'v${ext.version} → v${ext.repoVersion}'
                                    : 'v${ext.version}',
                                style: AppText.caption.copyWith(color: AppColors.muted),
                              ),
                              Text(
                                'lib ${ext.libVersion}',
                                style: AppText.caption.copyWith(color: AppColors.muted),
                              ),
                              if (ext.isNsfw)
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: Colors.redAccent.withValues(alpha: .2),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    '18+',
                                    style: AppText.badge.copyWith(color: Colors.redAccent),
                                  ),
                                ),
                              if (!ext.isCompatible)
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: Colors.orangeAccent.withValues(alpha: .2),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    'Incompatible lib version',
                                    style: AppText.badge.copyWith(color: Colors.orangeAccent),
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.bg,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppColors.outline),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('PACKAGE NAME', style: AppText.badge.copyWith(color: AppColors.muted)),
                      const SizedBox(height: 2),
                      SelectableText(
                        ext.pkg,
                        style: AppText.mono,
                      ),
                      if (ext.subSources.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        Text(
                          'INCLUDED SOURCES (${ext.subSources.length}) · TAP TO BROWSE',
                          style: AppText.badge.copyWith(color: AppColors.muted),
                        ),
                        const SizedBox(height: 6),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 150),
                          child: SingleChildScrollView(
                            child: Wrap(
                              spacing: 6,
                              runSpacing: 6,
                              children: [
                                for (final sub in [
                                  ...ext.subSources.where((s) =>
                                      _selectedLang == 'ALL' ||
                                      s['lang'] == _selectedLang ||
                                      s['lang'] == 'ALL'),
                                  ...ext.subSources.where((s) =>
                                      _selectedLang != 'ALL' &&
                                      s['lang'] != _selectedLang &&
                                      s['lang'] != 'ALL'),
                                ].take(30))
                                  ActionChip(
                                    visualDensity: VisualDensity.compact,
                                    backgroundColor: AppColors.surfaceHigh,
                                    side: BorderSide.none,
                                    label: Text(
                                      '${sub['name'] ?? ext.name} (${sub['lang'] ?? ext.lang})',
                                      style: AppText.caption,
                                    ),
                                    onPressed: !ext.isCompatible
                                        ? null
                                        : () {
                                            final subId = (sub['id'] ?? '').isNotEmpty
                                                ? '${ext.pkg}@${sub['id']}'
                                                : '${ext.pkg}@${sub['name'] ?? ''}';
                                            Navigator.pop(ctx);
                                            Navigator.of(context).push(
                                              smoothRoute(
                                                SourceCatalogScreen(
                                                  sourceId: subId,
                                                  sourceName: sub['name']?.isNotEmpty == true ? sub['name']! : ext.name,
                                                  sourceLang: sub['lang'] ?? ext.lang,
                                                ),
                                              ),
                                            );
                                          },
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ] else if (ext.sourceNames.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        Text('INCLUDED SOURCES (${ext.sourceNames.length})', style: AppText.badge.copyWith(color: AppColors.muted)),
                        const SizedBox(height: 4),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: ext.sourceNames.map((s) => Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: AppColors.surfaceHigh,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(s, style: AppText.caption),
                          )).toList(),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                Builder(
                  builder: (bCtx) {
                    final isDownloading = _service.isDownloading(ext.pkg);
                    final progress = _service.getProgress(ext.pkg);

                    if (isDownloading) {
                      return Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
                        decoration: BoxDecoration(
                          color: AppColors.surfaceHigh,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                value: progress > 0.05 ? progress : null,
                                strokeWidth: 2,
                                color: AppColors.primary,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                progress > 0
                                    ? 'Downloading APK... ${(progress * 100).toInt()}%'
                                    : 'Installing extension...',
                                style: AppText.bodySemiBold.copyWith(color: AppColors.primary),
                              ),
                            ),
                          ],
                        ),
                      );
                    }

                    if (ext.isInstalled) {
                      return Column(
                        children: [
                          if (ext.hasUpdate) ...[
                            SizedBox(
                              width: double.infinity,
                              child: FilledButton.icon(
                                onPressed: () async {
                                  final ok = await _service.downloadAndInstallExtension(ext);
                                  if (mounted) {
                                    final updatedVer = _service.getExtensionByPkg(ext.pkg)?.version ?? ext.repoVersion ?? ext.version;
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text(ok
                                            ? 'Updated ${ext.name} to v$updatedVer'
                                            : (_service.lastInstallError ?? 'Failed to update ${ext.name}.')),
                                      ),
                                    );
                                  }
                                },
                                icon: const Icon(Icons.system_update_rounded, size: 20),
                                label: Text('Update to v${ext.repoVersion ?? ext.version}'),
                                style: FilledButton.styleFrom(
                                  backgroundColor: AppColors.primary,
                                  foregroundColor: AppColors.onPrimary,
                                  minimumSize: const Size.fromHeight(46),
                                  padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                ),
                              ),
                            ),
                            const SizedBox(height: 10),
                          ],
                          SizedBox(
                            width: double.infinity,
                            child: FilledButton.icon(
                              onPressed: !ext.isCompatible
                                  ? null
                                  : () {
                                      Navigator.pop(ctx);
                                      Navigator.of(context).push(
                                        smoothRoute(
                                          SourceCatalogScreen(
                                            sourceId: ext.pkg,
                                            sourceName: ext.name,
                                            sourceLang: ext.lang,
                                          ),
                                        ),
                                      );
                                    },
                              icon: const Icon(Icons.grid_view_rounded, size: 20),
                              label: Text('Browse Catalog (${ext.name})'),
                              style: FilledButton.styleFrom(
                                backgroundColor: ext.hasUpdate ? AppColors.surfaceHigh : AppColors.primary,
                                foregroundColor: ext.hasUpdate ? AppColors.primary : AppColors.onPrimary,
                                minimumSize: const Size.fromHeight(46),
                                padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                              ),
                            ),
                          ),
                          const SizedBox(height: 10),
                          SizedBox(
                            width: double.infinity,
                            child: OutlinedButton.icon(
                              onPressed: () {
                                _service.uninstallExtension(ext);
                                Navigator.pop(ctx);
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text('Uninstalled ${ext.name}')),
                                );
                              },
                              icon: const Icon(Icons.delete_outline_rounded, size: 20, color: Colors.redAccent),
                              label: Text('Uninstall', style: AppText.bodySemiBold.copyWith(color: Colors.redAccent)),
                              style: OutlinedButton.styleFrom(
                                side: const BorderSide(color: Colors.redAccent),
                                minimumSize: const Size.fromHeight(46),
                                padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                              ),
                            ),
                          ),
                        ],
                      );
                    }

                    return Column(
                      children: [
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton.icon(
                            onPressed: !ext.isCompatible
                                ? null
                                : () async {
                                    final ok = await _service.downloadAndInstallExtension(ext);
                                    if (mounted) {
                                      final installedVer = _service.getExtensionByPkg(ext.pkg)?.version ?? ext.version;
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(
                                          content: Text(ok
                                              ? 'Installed ${ext.name} v$installedVer'
                                              : (_service.lastInstallError ?? 'Failed to install ${ext.name}.')),
                                          duration: const Duration(seconds: 3),
                                        ),
                                      );
                                    }
                                  },
                            icon: const Icon(Icons.download_rounded, size: 20),
                            label: Text(
                              ext.isCompatible
                                  ? 'Install (${ext.lang} • v${ext.version})'
                                  : 'Incompatible lib version (${ext.libVersion})',
                            ),
                            style: FilledButton.styleFrom(
                              backgroundColor: AppColors.primary,
                              foregroundColor: AppColors.onPrimary,
                              minimumSize: const Size.fromHeight(46),
                              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildIcon(MangaExtension ext, {double size = 42}) {
    if (ext.iconBytes != null && ext.iconBytes!.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: SizedBox(
          width: size,
          height: size,
          child: Image.memory(
            ext.iconBytes!,
            width: size,
            height: size,
            fit: BoxFit.cover,
            errorBuilder: (ctx, err, st) => _buildLetterAvatar(ext, size),
          ),
        ),
      );
    }
    if (ext.iconUrl.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: SizedBox(
          width: size,
          height: size,
          child: RetryingNetworkImage(
            url: ext.iconUrl,
            width: size,
            height: size,
            fit: BoxFit.cover,
            progressBuilder: (ctx, _) => ShimmerLoading(
              child: Container(
                width: size,
                height: size,
                color: AppColors.surfaceHigh,
              ),
            ),
            errorBuilder: (ctx, retry) => _buildLetterAvatar(ext, size),
          ),
        ),
      );
    }
    return _buildLetterAvatar(ext, size);
  }

  Widget _buildLetterAvatar(MangaExtension ext, double size) {
    final letter = ext.name.isNotEmpty ? ext.name[0].toUpperCase() : 'E';
    final color = Colors.primaries[ext.name.hashCode.abs() % Colors.primaries.length];
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color.withValues(alpha: .18),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: .4)),
      ),
      child: Center(
        child: Text(
          letter,
          style: AppText.cardTitle.copyWith(fontSize: size * 0.45, fontWeight: FontWeight.w700, color: color),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (SourceManager.isIOSPlatform) {
      return const SizedBox.shrink();
    }

    final allExts = _service.extensions;

    bool matchesFilters(MangaExtension ext) {
      if (!_showNsfw && ext.isNsfw) return false;
      if (_selectedLang != 'ALL' && !ext.supportsLang(_selectedLang)) {
        return false;
      }
      if (_query.isNotEmpty) {
        final q = _query.toLowerCase();
        final matchName = ext.name.toLowerCase().contains(q);
        final matchPkg = ext.pkg.toLowerCase().contains(q);
        final matchSrc = ext.sourceNames.any((s) => s.toLowerCase().contains(q));
        if (!matchName && !matchPkg && !matchSrc) return false;
      }
      return true;
    }

    final updatesAvailable = _service.updatesAvailableExtensions.where(matchesFilters).toList();
    final installed = _service.upToDateInstalledExtensions.where(matchesFilters).toList();
    final available = _service.availableExtensions.where(matchesFilters).toList();

    final body = Column(
      children: [
        if (widget.isEmbedded)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 8, 2),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _service.repoMetadata != null
                        ? '${_service.repoMetadata!.name} (${_service.extensions.length} extensions)'
                        : 'Keiyoushi Extension Repository',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.caption.copyWith(color: AppColors.muted),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.refresh_rounded, size: 18, color: AppColors.muted),
                  constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                  tooltip: 'Refresh repository',
                  onPressed: () {
                    _service.refreshDeviceExtensions();
                    _service.fetchExtensions(force: true);
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.hub_rounded, size: 18, color: AppColors.muted),
                  constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                  tooltip: 'Repository Settings',
                  onPressed: _addRepoDialog,
                ),
              ],
            ),
          ),

        // Search box
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Container(
            constraints: const BoxConstraints(minHeight: 44),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.outline),
            ),
            child: Row(
              children: [
                const Icon(Icons.search_rounded, size: 20, color: AppColors.muted),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    onChanged: (v) {
                      _searchDebounce?.cancel();
                      setState(() => _query = v.trim());
                    },
                    style: AppText.body,
                    decoration: InputDecoration(
                      hintText: 'Search 1,400+ extensions (e.g. Asura, Dex, Flame)...',
                      hintStyle: AppText.body.copyWith(color: AppColors.muted),
                      border: InputBorder.none,
                      isDense: true,
                    ),
                  ),
                ),
                if (_query.isNotEmpty)
                  IconButton(
                    onPressed: () {
                      _searchController.clear();
                      setState(() => _query = '');
                    },
                    constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                    padding: EdgeInsets.zero,
                    icon: const Icon(Icons.close_rounded, size: 18, color: AppColors.muted),
                  ),
              ],
            ),
          ),
        ),

        // Language Filter Chips + NSFW Toggle
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Padding(
                padding: const EdgeInsets.only(right: 8, bottom: 4),
                child: FilterChip(
                  label: const Text('18+ NSFW'),
                  selected: _showNsfw,
                  onSelected: (val) => setState(() => _showNsfw = val),
                  selectedColor: Colors.redAccent.withValues(alpha: .25),
                  backgroundColor: AppColors.surface,
                  labelStyle: AppText.chip.copyWith(
                    fontWeight: _showNsfw ? FontWeight.w700 : FontWeight.w500,
                    color: _showNsfw ? Colors.redAccent : AppColors.muted,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                    side: BorderSide(color: _showNsfw ? Colors.redAccent : AppColors.outline),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  showCheckmark: false,
                ),
              ),
              for (final lang in _commonLangs)
                Padding(
                  padding: const EdgeInsets.only(right: 6, bottom: 4),
                  child: ChoiceChip(
                    label: Text(lang),
                    selected: _selectedLang == lang,
                    onSelected: (val) {
                      if (val) setState(() => _selectedLang = lang);
                    },
                    selectedColor: AppColors.primary,
                    backgroundColor: AppColors.surface,
                    labelStyle: AppText.chip.copyWith(
                      fontWeight: _selectedLang == lang ? FontWeight.w700 : FontWeight.w500,
                      color: _selectedLang == lang ? AppColors.onPrimary : AppColors.muted,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                      side: BorderSide(color: _selectedLang == lang ? AppColors.primary : AppColors.outline),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    showCheckmark: false,
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 6),

        // Main list (Updates available -> Installed -> Available)
        Expanded(
          child: _service.isLoading && allExts.isEmpty
              ? ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  itemCount: 8,
                  itemBuilder: (ctx, i) => const ExtensionTileSkeleton(),
                )
              : RefreshIndicator(
                  onRefresh: () async {
                    await _service.refreshDeviceExtensions();
                    await _service.fetchExtensions(force: true);
                  },
                  color: AppColors.primary,
                  child: CustomScrollView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    slivers: [
                      if (_service.error != null)
                        SliverToBoxAdapter(
                          child: Container(
                            margin: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: AppColors.surface,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: Colors.orangeAccent.withValues(alpha: .4)),
                            ),
                            child: Row(
                              children: [
                                const Icon(Icons.cloud_off_rounded, size: 18, color: Colors.orangeAccent),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    'Repo offline (${_service.error}). Showing installed device extensions.',
                                    style: AppText.caption.copyWith(color: AppColors.muted),
                                  ),
                                ),
                                TextButton(
                                  onPressed: () => _service.fetchExtensions(force: true),
                                  child: const Text('Retry'),
                                ),
                              ],
                            ),
                          ),
                        ),

                      // SECTION 1: UPDATES AVAILABLE
                      if (updatesAvailable.isNotEmpty) ...[
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            child: Row(
                              children: [
                                Expanded(
                                  child: _header('UPDATES AVAILABLE (${updatesAvailable.length})'),
                                ),
                                TextButton.icon(
                                  onPressed: () async {
                                    final count = await _service.updateAllExtensions();
                                    if (context.mounted) {
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(
                                          content: Text(count > 0
                                              ? 'Updated $count extension${count == 1 ? '' : 's'}'
                                              : (_service.lastInstallError ?? 'Failed to update extensions.')),
                                          duration: const Duration(seconds: 3),
                                        ),
                                      );
                                    }
                                  },
                                  icon: const Icon(Icons.done_all_rounded, size: 15),
                                  label: Text(
                                    'Update All',
                                    style: AppText.chip.copyWith(color: AppColors.primary, fontWeight: FontWeight.w700),
                                  ),
                                  style: TextButton.styleFrom(
                                    foregroundColor: AppColors.primary,
                                    minimumSize: const Size(44, 36),
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        SliverPadding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          sliver: SliverList.builder(
                            itemCount: updatesAvailable.length,
                            itemBuilder: (_, i) => _buildExtensionTile(updatesAvailable[i]),
                          ),
                        ),
                        const SliverToBoxAdapter(child: SizedBox(height: 12)),
                      ],

                      // SECTION 2: INSTALLED
                      if (installed.isNotEmpty) ...[
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            child: _header('INSTALLED (${installed.length})'),
                          ),
                        ),
                        SliverPadding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          sliver: SliverList.builder(
                            itemCount: installed.length,
                            itemBuilder: (_, i) => _buildExtensionTile(installed[i]),
                          ),
                        ),
                        const SliverToBoxAdapter(child: SizedBox(height: 12)),
                      ],

                      // SECTION 3: AVAILABLE
                      if (available.isNotEmpty) ...[
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            child: _header('AVAILABLE (${available.length})'),
                          ),
                        ),
                        SliverPadding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          sliver: SliverList.builder(
                            itemCount: available.length,
                            itemBuilder: (_, i) => _buildExtensionTile(available[i]),
                          ),
                        ),
                        const SliverToBoxAdapter(child: SizedBox(height: 24)),
                      ],

                      if (updatesAvailable.isEmpty && installed.isEmpty && available.isEmpty)
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.all(40),
                            child: EmptyState(
                              icon: Icons.search_off_rounded,
                              title: 'No extensions found',
                              message: 'Try searching for another name or changing the language filter from $_selectedLang.',
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
        ),
      ],
    );

    if (widget.isEmbedded) {
      return body;
    }

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        elevation: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Extensions', style: AppText.title),
            Text(
              'Tachiyomi / Keiyoushi extensions',
              style: AppText.caption.copyWith(color: AppColors.muted),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded, color: AppColors.muted),
            onPressed: () {
              _service.refreshDeviceExtensions();
              _service.fetchExtensions(force: true);
            },
          ),
          IconButton(
            icon: const Icon(Icons.hub_rounded, color: AppColors.muted),
            onPressed: _addRepoDialog,
          ),
        ],
      ),
      body: body,
    );
  }

  Widget _header(String text) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8, top: 4),
      child: Text(
        text,
        style: AppText.sectionHeader,
      ),
    );
  }

  Widget _buildExtensionTile(MangaExtension ext) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => _showExtensionDetails(ext),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.outline),
          ),
          child: Row(
            children: [
              _buildIcon(ext, size: 44),
              const SizedBox(width: 12),
              // Info block
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      ext.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.cardTitle,
                    ),
                    const SizedBox(height: 3),
                    Wrap(
                      spacing: 4,
                      runSpacing: 2,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                          decoration: BoxDecoration(
                            color: AppColors.surfaceHigh,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            ext.lang,
                            style: AppText.badge.copyWith(color: AppColors.primary),
                          ),
                        ),
                        if (ext.isNsfw)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                            decoration: BoxDecoration(
                              color: Colors.redAccent.withValues(alpha: .2),
                              borderRadius: BorderRadius.circular(3),
                            ),
                            child: Text(
                              '18+',
                              style: AppText.badge.copyWith(color: Colors.redAccent),
                            ),
                          ),
                        if (!ext.isCompatible)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                            decoration: BoxDecoration(
                              color: Colors.orangeAccent.withValues(alpha: .2),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              'Incompatible lib version',
                              style: AppText.badge.copyWith(color: Colors.orangeAccent),
                            ),
                          ),
                        Text(
                          ext.hasUpdate && ext.repoVersion != null
                              ? 'v${ext.version} → v${ext.repoVersion}'
                              : 'v${ext.version}',
                          style: AppText.caption.copyWith(
                            color: ext.hasUpdate ? AppColors.primary : AppColors.muted,
                            fontWeight: ext.hasUpdate ? FontWeight.w600 : FontWeight.normal,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      ext.sourceNames.isNotEmpty
                          ? ext.sourceNames.take(3).join(', ')
                          : ext.pkg.replaceFirst(RegExp(r'^eu\.kanade\.tachiyomi\.(?:extension\.)?'), ''),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.caption.copyWith(color: AppColors.muted),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              // Action button:
              Builder(
                builder: (bCtx) {
                  final targetSourceId = (_selectedLang != 'ALL' && ext.lang == 'ALL')
                      ? '${ext.pkg}@$_selectedLang'
                      : ext.pkg;
                  final targetLang = _selectedLang != 'ALL' ? _selectedLang : ext.lang;

                  final isDownloading = _service.isDownloading(ext.pkg);
                  final progress = _service.getProgress(ext.pkg);

                  if (isDownloading) {
                    return Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: AppColors.surfaceHigh,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                              value: progress > 0.05 ? progress : null,
                              strokeWidth: 2,
                              color: AppColors.primary,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            progress > 0 ? '${(progress * 100).toInt()}%' : '...',
                            style: AppText.caption.copyWith(fontWeight: FontWeight.w700, color: AppColors.primary),
                          ),
                        ],
                      ),
                    );
                  }

                  if (ext.isInstalled) {
                    return Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (ext.hasUpdate)
                          Padding(
                            padding: const EdgeInsets.only(right: 4),
                            child: FilledButton(
                              onPressed: () async {
                                final ok = await _service.downloadAndInstallExtension(ext);
                                if (mounted) {
                                  final updatedVer = _service.getExtensionByPkg(ext.pkg)?.version ?? ext.repoVersion ?? ext.version;
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(ok
                                          ? 'Updated ${ext.name} to v$updatedVer'
                                          : (_service.lastInstallError ?? 'Failed to update ${ext.name}.')),
                                      duration: const Duration(seconds: 3),
                                    ),
                                  );
                                }
                              },
                              style: FilledButton.styleFrom(
                                backgroundColor: AppColors.primary,
                                foregroundColor: AppColors.onPrimary,
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                minimumSize: const Size(44, 44),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                              ),
                              child: Text(
                                'Update',
                                style: AppText.chip.copyWith(color: AppColors.onPrimary, fontWeight: FontWeight.w700),
                              ),
                            ),
                          ),
                        if (ext.isCompatible)
                          IconButton(
                            constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                            icon: const Icon(Icons.explore_outlined, size: 20, color: AppColors.primary),
                            tooltip: 'Browse ${ext.name} Catalog',
                            onPressed: () {
                              Navigator.of(context).push(
                                smoothRoute(
                                  SourceCatalogScreen(
                                    sourceId: targetSourceId,
                                    sourceName: ext.name,
                                    sourceLang: targetLang,
                                  ),
                                ),
                              );
                            },
                          ),
                        IconButton(
                          constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                          icon: const Icon(Icons.delete_outline_rounded, size: 18, color: Colors.redAccent),
                          tooltip: 'Uninstall ${ext.name}',
                          onPressed: () {
                            _service.uninstallExtension(ext);
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text('Uninstalled ${ext.name}'),
                                duration: const Duration(seconds: 1),
                              ),
                            );
                          },
                        ),
                      ],
                    );
                  }

                  if (!ext.isCompatible) {
                    return Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.orangeAccent.withValues(alpha: .15),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        'Incompatible',
                        style: AppText.badge.copyWith(color: Colors.orangeAccent),
                      ),
                    );
                  }

                  return FilledButton.icon(
                    onPressed: () async {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('Downloading ${ext.name}...'),
                          duration: const Duration(seconds: 1),
                        ),
                      );
                      final ok = await _service.downloadAndInstallExtension(ext);
                      if (mounted) {
                        final installedVer = _service.getExtensionByPkg(ext.pkg)?.version ?? ext.version;
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(ok
                                ? 'Installed ${ext.name} v$installedVer'
                                : (_service.lastInstallError ?? 'Failed to install ${ext.name}.')),
                            duration: const Duration(seconds: 3),
                          ),
                        );
                      }
                    },
                    icon: const Icon(Icons.download_rounded, size: 14),
                    label: Text(
                      'Install',
                      style: AppText.chip.copyWith(color: AppColors.onPrimary, fontWeight: FontWeight.w700),
                    ),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      foregroundColor: AppColors.onPrimary,
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      minimumSize: const Size(44, 44),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}
