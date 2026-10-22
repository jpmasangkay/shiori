import 'dart:async';
import 'dart:io';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

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

  final List<String> _commonLangs = ['ALL', 'EN', 'ES', 'JA', 'KO', 'ZH', 'FR', 'ID', 'RU'];

  @override
  void initState() {
    super.initState();
    _service.addListener(_onServiceUpdate);
    if (_service.extensions.isEmpty && !_service.isLoading) {
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
        title: Row(
          children: [
            const Icon(Icons.hub_rounded, color: AppColors.primary, size: 20),
            const SizedBox(width: 8),
            Text('Extension Repository', style: GoogleFonts.inter(fontSize: 16, fontWeight: FontWeight.w600)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Keiyoushi Protocol Buffer index repo:',
              style: GoogleFonts.inter(fontSize: 12, color: AppColors.muted),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              style: GoogleFonts.inter(fontSize: 12),
              maxLines: 2,
              decoration: InputDecoration(
                hintText: 'https://raw.githubusercontent.com/.../index.pb',
                hintStyle: const TextStyle(fontSize: 11, color: AppColors.read),
                filled: true,
                fillColor: AppColors.surfaceHigh,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Supports Keiyoushi (index.pb) with 1,400+ extensions and automatic APK downloads.',
              style: GoogleFonts.inter(fontSize: 10, color: AppColors.muted, fontStyle: FontStyle.italic),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              controller.text = ExtensionService.defaultRepoUrl;
            },
            child: const Text('Reset Default', style: TextStyle(color: AppColors.muted)),
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

  void _confirmUninstallAll() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Row(
          children: [
            const Icon(Icons.delete_sweep_rounded, color: Colors.redAccent, size: 22),
            const SizedBox(width: 8),
            Text('Uninstall All Sources?', style: GoogleFonts.inter(fontSize: 16, fontWeight: FontWeight.w600)),
          ],
        ),
        content: Text(
          'This will remove all installed sources from Shiori, resetting to zero active extensions.',
          style: GoogleFonts.inter(fontSize: 13, color: AppColors.muted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              _service.uninstallAll();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('All sources uninstalled')),
              );
            },
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            child: const Text('Uninstall All'),
          ),
        ],
      ),
    );
  }

  void _showExtensionDetails(MangaExtension ext) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => DraggableScrollableSheet(
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
                  color: AppColors.surfaceHigh,
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
                        style: GoogleFonts.inter(fontSize: 17, fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: AppColors.primary.withValues(alpha: .2),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              ext.lang,
                              style: GoogleFonts.inter(fontSize: 10, fontWeight: FontWeight.w600, color: AppColors.primary),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text('v${ext.version}', style: GoogleFonts.inter(fontSize: 12, color: AppColors.muted)),
                          if (ext.isNsfw) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                              decoration: BoxDecoration(
                                color: Colors.redAccent.withValues(alpha: .2),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                '18+',
                                style: GoogleFonts.inter(fontSize: 9, fontWeight: FontWeight.w700, color: Colors.redAccent),
                              ),
                            ),
                          ],
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
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('PACKAGE ID', style: GoogleFonts.inter(fontSize: 10, fontWeight: FontWeight.w700, color: AppColors.muted)),
                  const SizedBox(height: 2),
                  SelectableText(
                    ext.pkg,
                    style: GoogleFonts.robotoMono(fontSize: 11, color: AppColors.text),
                  ),
                  if (ext.sourceNames.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Text('INCLUDED SOURCES (${ext.sourceNames.length})', style: GoogleFonts.inter(fontSize: 10, fontWeight: FontWeight.w700, color: AppColors.muted)),
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
                        child: Text(s, style: GoogleFonts.inter(fontSize: 11, color: AppColors.text)),
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

                if (ext.isInstalled) {
                  return Column(
                    children: [
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: () {
                            Navigator.pop(ctx);
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => SourceCatalogScreen(
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
                            backgroundColor: AppColors.primary,
                            foregroundColor: AppColors.onPrimary,
                            padding: const EdgeInsets.symmetric(vertical: 14),
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
                          label: Text('Uninstall from Shiori', style: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.redAccent)),
                          style: OutlinedButton.styleFrom(
                            side: const BorderSide(color: Colors.redAccent),
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                        ),
                      ),
                    ],
                  );
                }

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
                            'Downloading in-app... ${(progress * 100).toInt()}%',
                            style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.primary),
                          ),
                        ),
                      ],
                    ),
                  );
                }

                return SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: () async {
                      ScaffoldMessenger.of(ctx).showSnackBar(
                        SnackBar(
                          content: Text('Downloading ${ext.name} in-app...'),
                          duration: const Duration(seconds: 1),
                        ),
                      );
                      final ok = await _service.downloadAndInstallExtension(ext);
                      if (ctx.mounted) {
                        Navigator.pop(ctx);
                      }
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(ok
                                ? 'Installed ${ext.name} in-app! Added to Browse Sources.'
                                : 'Failed to install ${ext.name}.'),
                            duration: const Duration(seconds: 2),
                          ),
                        );
                      }
                    },
                    icon: const Icon(Icons.download_rounded, size: 20),
                    label: Text('Install In-App (${ext.lang} • v${ext.version})'),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      foregroundColor: AppColors.onPrimary,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildIcon(MangaExtension ext, {double size = 42}) {
    if (ext.iconUrl.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: CachedNetworkImage(
          imageUrl: ext.iconUrl,
          width: size,
          height: size,
          fit: BoxFit.cover,
          placeholder: (ctx, url) => Container(
            width: size,
            height: size,
            color: AppColors.surfaceHigh,
            child: const Center(child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))),
          ),
          errorWidget: (ctx, url, err) => _buildLetterAvatar(ext, size),
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
          style: GoogleFonts.inter(fontSize: size * 0.45, fontWeight: FontWeight.w700, color: color),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final allExts = _service.extensions;

    final filtered = allExts.where((ext) {
      if (_selectedLang != 'ALL' && ext.lang != _selectedLang) {
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
    }).toList();

    final installed = filtered.where((e) => e.isInstalled).toList();
    final available = filtered.where((e) => !e.isInstalled).toList();

    final q = _query.toLowerCase();
    final matchDirectSources = SourceManager.directSources.where((ds) {
      final matchLang = _selectedLang == 'ALL' ||
          ds.lang.toUpperCase() == _selectedLang ||
          ds.lang == 'ALL';
      final matchQuery = q.isEmpty ||
          ds.name.toLowerCase().contains(q) ||
          ds.id.toLowerCase().contains(q);
      return matchLang && matchQuery;
    }).toList();

    final body = Column(
      children: [
        if (widget.isEmbedded)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    allExts.isNotEmpty ? '${allExts.length} community extensions available' : 'Keiyoushi Repository',
                    style: GoogleFonts.inter(fontSize: 12, color: AppColors.muted),
                  ),
                ),
                IconButton(
                  icon: _service.isLoading
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.primary))
                      : const Icon(Icons.refresh_rounded, size: 20, color: AppColors.text),
                  tooltip: 'Refresh Repository',
                  onPressed: _service.isLoading ? null : () => _service.fetchExtensions(force: true),
                ),
                PopupMenuButton<String>(
                  icon: const Icon(Icons.more_vert_rounded, size: 20, color: AppColors.muted),
                  color: AppColors.surface,
                  onSelected: (val) {
                    if (val == 'repo') {
                      _addRepoDialog();
                    } else if (val == 'uninstall_all') {
                      _confirmUninstallAll();
                    }
                  },
                  itemBuilder: (ctx) => [
                    const PopupMenuItem(
                      value: 'repo',
                      child: Row(
                        children: [
                          Icon(Icons.hub_rounded, size: 18, color: AppColors.primary),
                          SizedBox(width: 10),
                          Text('Repository Settings'),
                        ],
                      ),
                    ),
                    const PopupMenuItem(
                      value: 'uninstall_all',
                      child: Row(
                        children: [
                          Icon(Icons.delete_sweep_rounded, size: 18, color: Colors.redAccent),
                          SizedBox(width: 10),
                          Text('Uninstall All Sources', style: TextStyle(color: Colors.redAccent)),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        // Search box
        Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Container(
              height: 42,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.surfaceHigh),
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
                        _searchDebounce = Timer(const Duration(milliseconds: 150), () {
                          if (mounted) setState(() => _query = v.trim());
                        });
                      },
                      style: GoogleFonts.inter(fontSize: 13, color: AppColors.text),
                      decoration: InputDecoration(
                        hintText: Platform.isIOS
                            ? 'Search sources (e.g. Asura, Dex, Flame)...'
                            : 'Search 1,400+ extensions (e.g. Asura, Dex, Flame)...',
                        hintStyle: const TextStyle(color: AppColors.muted, fontSize: 13),
                        border: InputBorder.none,
                        isDense: true,
                      ),
                    ),
                  ),
                  if (_query.isNotEmpty)
                    GestureDetector(
                      onTap: () {
                        _searchController.clear();
                        setState(() => _query = '');
                      },
                      child: const Icon(Icons.close_rounded, size: 18, color: AppColors.muted),
                    ),
                ],
              ),
            ),
          ),

          // Language Filter Chips
          SizedBox(
            height: 38,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: _commonLangs.length,
              itemBuilder: (ctx, i) {
                final lang = _commonLangs[i];
                final isSel = _selectedLang == lang;
                return Padding(
                  padding: const EdgeInsets.only(right: 6, bottom: 4),
                  child: ChoiceChip(
                    label: Text(lang),
                    selected: isSel,
                    onSelected: (val) {
                      if (val) setState(() => _selectedLang = lang);
                    },
                    selectedColor: AppColors.primary,
                    backgroundColor: AppColors.surface,
                    labelStyle: GoogleFonts.inter(
                      fontSize: 11,
                      fontWeight: isSel ? FontWeight.w700 : FontWeight.w500,
                      color: isSel ? AppColors.onPrimary : AppColors.muted,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                      side: BorderSide(color: isSel ? AppColors.primary : AppColors.surfaceHigh),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    showCheckmark: false,
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 6),

          // Main list
          Expanded(
            child: _service.isLoading && allExts.isEmpty
                ? ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    itemCount: 8,
                    itemBuilder: (ctx, i) => const ExtensionTileSkeleton(),
                  )
                : _service.error != null && allExts.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.error_outline_rounded, color: Colors.redAccent, size: 40),
                              const SizedBox(height: 12),
                              Text(_service.error!, textAlign: TextAlign.center, style: const TextStyle(color: AppColors.muted)),
                              const SizedBox(height: 16),
                              FilledButton(
                                onPressed: () => _service.fetchExtensions(force: true),
                                child: const Text('Try Again'),
                              ),
                            ],
                          ),
                        ),
                      )
                    : RefreshIndicator(
                        onRefresh: () => _service.fetchExtensions(force: true),
                        color: AppColors.primary,
                        child: CustomScrollView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          slivers: [
                            // Info Banner
                            SliverToBoxAdapter(
                              child: Container(
                                margin: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: AppColors.surface,
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(color: AppColors.surfaceHigh),
                                ),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Icon(Icons.info_outline_rounded, size: 20, color: AppColors.primary),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Text(
                                        Platform.isIOS
                                            ? 'Direct Built-in Sources: MangaDex, Asura Scans, Flame Comics, and Weeb Central are directly integrated into Shiori. Community APK extensions are not supported on iOS.'
                                            : 'All extensions install directly in-app. Browse manga catalogs and read chapters with zero external redirects.',
                                        style: GoogleFonts.inter(fontSize: 11, color: AppColors.muted, height: 1.4),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),

                            // Direct In-App Sources
                            SliverToBoxAdapter(
                              child: Builder(
                                builder: (context) {
                                  if (matchDirectSources.isEmpty) return const SizedBox.shrink();

                                  return Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 16),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        _header('DIRECT IN-APP SOURCES'),
                                        for (final ds in matchDirectSources)
                                          _buildDirectSourceTile(
                                            id: ds.id,
                                            name: ds.name,
                                            description: ds.description,
                                            lang: ds.lang,
                                            iconLetter: ds.iconLetter,
                                            iconColor: Color(ds.colorValue),
                                            isInstalled: true,
                                          ),
                                        const SizedBox(height: 12),
                                      ],
                                    ),
                                  );
                                },
                              ),
                            ),

                            // Keiyoushi Community Extensions (Android APK packages)
                            if (!Platform.isIOS && filtered.isNotEmpty) ...[
                              SliverToBoxAdapter(
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 16),
                                  child: _header('KEIYOUSHI COMMUNITY EXTENSIONS (${filtered.length})'),
                                ),
                              ),
                              SliverPadding(
                                padding: const EdgeInsets.symmetric(horizontal: 16),
                                sliver: SliverList.builder(
                                  itemCount: filtered.length,
                                  itemBuilder: (_, i) => _buildExtensionTile(filtered[i]),
                                ),
                              ),
                              const SliverToBoxAdapter(child: SizedBox(height: 24)),
                            ],

                            if (Platform.isIOS ? matchDirectSources.isEmpty : (matchDirectSources.isEmpty && installed.isEmpty && available.isEmpty))
                              SliverToBoxAdapter(
                                child: Padding(
                                  padding: const EdgeInsets.all(40),
                                  child: EmptyState(
                                    icon: Icons.search_off_rounded,
                                    title: Platform.isIOS ? 'No sources found' : 'No extensions found',
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
            Text(Platform.isIOS ? 'Sources' : 'Extensions', style: GoogleFonts.inter(fontSize: 18, fontWeight: FontWeight.w600)),
            if (allExts.isNotEmpty && !Platform.isIOS)
              Text(
                '${allExts.length} extensions available from Keiyoushi',
                style: GoogleFonts.inter(fontSize: 11, color: AppColors.muted),
              ),
            if (Platform.isIOS)
              Text(
                '4 direct sources integrated natively',
                style: GoogleFonts.inter(fontSize: 11, color: AppColors.muted),
              ),
          ],
        ),
        actions: [
          IconButton(
            icon: _service.isLoading
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.primary))
                : const Icon(Icons.refresh_rounded, color: AppColors.text),
            tooltip: Platform.isIOS ? 'Refresh Sources' : 'Refresh Repository',
            onPressed: _service.isLoading ? null : () => _service.fetchExtensions(force: true),
          ),
          if (!Platform.isIOS)
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert_rounded, color: AppColors.muted),
              color: AppColors.surface,
              onSelected: (val) {
                if (val == 'repo') {
                  _addRepoDialog();
                } else if (val == 'uninstall_all') {
                  _confirmUninstallAll();
                }
              },
              itemBuilder: (ctx) => [
                const PopupMenuItem(
                  value: 'repo',
                  child: Row(
                    children: [
                      Icon(Icons.hub_rounded, size: 18, color: AppColors.primary),
                      SizedBox(width: 10),
                      Text('Repository Settings'),
                    ],
                  ),
                ),
                const PopupMenuItem(
                  value: 'uninstall_all',
                  child: Row(
                    children: [
                      Icon(Icons.delete_sweep_rounded, size: 18, color: Colors.redAccent),
                      SizedBox(width: 10),
                      Text('Uninstall All Sources', style: TextStyle(color: Colors.redAccent)),
                    ],
                  ),
                ),
              ],
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
        style: GoogleFonts.inter(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 1,
          color: AppColors.muted,
        ),
      ),
    );
  }

  Widget _buildDirectSourceTile({
    required String id,
    required String name,
    required String description,
    required String lang,
    required String iconLetter,
    required Color iconColor,
    required bool isInstalled,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.surfaceHigh),
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: iconColor.withValues(alpha: .18),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: iconColor.withValues(alpha: .4)),
              ),
              child: Center(
                child: Text(
                  iconLetter,
                  style: GoogleFonts.inter(fontSize: 20, fontWeight: FontWeight.w700, color: iconColor),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w600),
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
                          lang,
                          style: GoogleFonts.inter(fontSize: 9, fontWeight: FontWeight.w600, color: AppColors.primary),
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                        decoration: BoxDecoration(
                          color: Colors.greenAccent.withValues(alpha: .15),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          'DIRECT',
                          style: GoogleFonts.inter(fontSize: 8, fontWeight: FontWeight.w700, color: Colors.greenAccent),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    description,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.inter(fontSize: 11, color: AppColors.muted),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (isInstalled)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.all(6),
                    constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                    icon: const Icon(Icons.explore_outlined, size: 20, color: AppColors.primary),
                    tooltip: 'Browse $name Catalog',
                    onPressed: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => SourceCatalogScreen(
                            sourceId: id,
                            sourceName: name,
                            sourceLang: lang,
                          ),
                        ),
                      );
                    },
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.all(6),
                    constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                    icon: const Icon(Icons.delete_outline_rounded, size: 18, color: Colors.redAccent),
                    tooltip: 'Uninstall $name',
                    onPressed: () {
                      _service.uninstallPackage(id);
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('Uninstalled $name'),
                          duration: const Duration(seconds: 1),
                        ),
                      );
                    },
                  ),
                ],
              )
            else
              FilledButton(
                onPressed: () {
                  _service.installPackageByNameOrId(id);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Installed $name! Added to Browse Sources.'),
                      duration: const Duration(seconds: 2),
                    ),
                  );
                },
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: AppColors.onPrimary,
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  minimumSize: const Size(0, 32),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                child: Text('Install', style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w600)),
              ),
          ],
        ),
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
            border: Border.all(color: AppColors.surfaceHigh),
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
                      style: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w600),
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
                            style: GoogleFonts.inter(fontSize: 9, fontWeight: FontWeight.w600, color: AppColors.primary),
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
                              style: GoogleFonts.inter(fontSize: 8, fontWeight: FontWeight.w700, color: Colors.redAccent),
                            ),
                          ),
                        Text(
                          'v${ext.version}',
                          style: GoogleFonts.inter(fontSize: 10, color: AppColors.muted),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      ext.sourceNames.isNotEmpty ? ext.sourceNames.take(3).join(', ') : ext.pkg,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(fontSize: 11, color: AppColors.muted),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              // Action button:
              Builder(
                builder: (bCtx) {
                  if (ext.isInstalled) {
                    return Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.all(6),
                          constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                          icon: const Icon(Icons.explore_outlined, size: 20, color: AppColors.primary),
                          tooltip: 'Browse ${ext.name} Catalog',
                          onPressed: () {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => SourceCatalogScreen(
                                  sourceId: ext.pkg,
                                  sourceName: ext.name,
                                  sourceLang: ext.lang,
                                ),
                              ),
                            );
                          },
                        ),
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.all(6),
                          constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
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
                            style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.w700, color: AppColors.primary),
                          ),
                        ],
                      ),
                    );
                  }

                  return FilledButton.icon(
                    onPressed: () async {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('Downloading ${ext.name} in-app...'),
                          duration: const Duration(seconds: 1),
                        ),
                      );
                      final ok = await _service.downloadAndInstallExtension(ext);
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(ok
                                ? 'Installed ${ext.name} in-app! Added to Browse Sources.'
                                : 'Failed to install ${ext.name}.'),
                            duration: const Duration(seconds: 2),
                          ),
                        );
                      }
                    },
                    icon: const Icon(Icons.download_rounded, size: 14),
                    label: Text('Install', style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.w600)),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      foregroundColor: AppColors.onPrimary,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                      minimumSize: const Size(0, 32),
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
