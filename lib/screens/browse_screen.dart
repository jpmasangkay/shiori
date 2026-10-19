import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../models/manga_models.dart';
import '../services/api_service.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'detail_screen.dart';

class BrowseScreen extends StatefulWidget {
  const BrowseScreen({super.key});

  @override
  State<BrowseScreen> createState() => _BrowseScreenState();
}

class _BrowseScreenState extends State<BrowseScreen> {
  final _searchController = TextEditingController();
  Timer? _debounce;
  String _selectedType = 'all'; // all, manga, manhwa, manhua
  String _selectedOrder = 'popular'; // popular, latest, rating, new
  List<MangaItem> _items = [];
  bool _loading = true;
  String? _error;
  int _page = 1;

  static const _types = [
    ('all', 'All'),
    ('manhwa', '🇰🇷 Manhwa'),
    ('manga', '🇯🇵 Manga'),
    ('manhua', '🇨🇳 Manhua'),
  ];

  static const _orders = [
    ('popular', 'Most Popular'),
    ('latest', 'Latest Updates'),
    ('rating', 'Highest Rated'),
    ('new', 'Recently Added'),
  ];

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged(String text) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () {
      setState(() {
        _page = 1;
      });
      _fetch();
    });
  }

  Future<void> _fetch() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final results = await ApiService.instance.searchManga(
        query: _searchController.text.trim(),
        type: _selectedType == 'all' ? null : _selectedType,
        order: _selectedOrder,
        page: _page,
        limit: 24,
      );
      if (mounted) {
        setState(() {
          _items = results;
          _loading = false;
        });
      }
    } catch (err) {
      if (mounted) {
        setState(() {
          _error = err.toString().replaceFirst('Exception: ', '');
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        AppTopBar(
          title: 'Browse',
          branded: true,
          actions: [
            BarIcon(
              Icons.tune_rounded,
              label: 'Filter sort',
              onTap: _showSortDialog,
            ),
          ],
        ),
        // Search bar
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 4, 14, 8),
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
                    onChanged: _onSearchChanged,
                    style: GoogleFonts.inter(fontSize: 13, color: AppColors.text),
                    decoration: const InputDecoration(
                      hintText: 'Search manga, manhwa, manhua...',
                      hintStyle: TextStyle(color: AppColors.muted, fontSize: 13),
                      border: InputBorder.none,
                      isDense: true,
                    ),
                  ),
                ),
                if (_searchController.text.isNotEmpty)
                  GestureDetector(
                    onTap: () {
                      _searchController.clear();
                      _fetch();
                    },
                    child: const Icon(Icons.close_rounded, size: 18, color: AppColors.muted),
                  ),
              ],
            ),
          ),
        ),
        // Type categories
        SizedBox(
          height: 38,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: [
              for (final (typeKey, typeLabel) in _types)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(typeLabel),
                    selected: _selectedType == typeKey,
                    onSelected: (sel) {
                      if (sel) {
                        setState(() {
                          _selectedType = typeKey;
                          _page = 1;
                        });
                        _fetch();
                      }
                    },
                    backgroundColor: AppColors.surface,
                    selectedColor: AppColors.active,
                    labelStyle: GoogleFonts.inter(
                      fontSize: 12,
                      color: _selectedType == typeKey ? AppColors.primary : AppColors.muted,
                      fontWeight: _selectedType == typeKey ? FontWeight.w600 : FontWeight.normal,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
                      side: BorderSide(
                        color: _selectedType == typeKey ? AppColors.primary : Colors.transparent,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        // Content
        Expanded(child: _buildGrid()),
      ],
    );
  }

  Widget _buildGrid() {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: AppColors.primary),
      );
    }

    if (_error != null && _items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off_rounded, size: 44, color: AppColors.muted),
              const SizedBox(height: 12),
              Text(
                'Could not load catalog',
                style: GoogleFonts.inter(fontSize: 15, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 6),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(fontSize: 12, color: AppColors.muted),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _fetch,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('Try Again'),
                style: FilledButton.styleFrom(backgroundColor: AppColors.surfaceHigh),
              ),
            ],
          ),
        ),
      );
    }

    if (_items.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.search_off_rounded, size: 44, color: AppColors.muted),
            const SizedBox(height: 10),
            Text(
              'No titles found',
              style: GoogleFonts.inter(fontSize: 14, color: AppColors.muted),
            ),
          ],
        ),
      );
    }

    final width = MediaQuery.sizeOf(context).width;
    final cols = (width / 115).clamp(2, 6).floor();

    return RefreshIndicator(
      color: AppColors.primary,
      backgroundColor: AppColors.surface,
      onRefresh: _fetch,
      child: GridView.builder(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 20),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: cols,
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
          childAspectRatio: 2 / 3,
        ),

        itemCount: _items.length,
        itemBuilder: (_, i) {
          final manga = _items[i];
          return InkWell(
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => DetailScreen(manga: manga)),
              );
            },
            borderRadius: BorderRadius.circular(6),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  const ColoredBox(color: AppColors.surfaceHigh),
                  CoverImage(i, imageUrl: manga.cover, saturation: .75),
                  const Align(
                    alignment: Alignment.bottomCenter,
                    child: FractionallySizedBox(
                      heightFactor: .55,
                      widthFactor: 1,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [Colors.transparent, Color.fromRGBO(5, 6, 9, .95)],
                          ),
                        ),
                      ),
                    ),
                  ),
                  // Type badge (Manhwa/Manga/Manhua)
                  Positioned(
                    top: 5,
                    left: 5,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                      decoration: BoxDecoration(
                        color: AppColors.surfaceHigh.withValues(alpha: .9),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        manga.type.toUpperCase(),
                        style: GoogleFonts.inter(fontSize: 9, fontWeight: FontWeight.w700, color: AppColors.primary),
                      ),
                    ),
                  ),
                  // Title
                  Positioned(
                    left: 7,
                    right: 7,
                    bottom: 7,
                    child: Text(
                      manga.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        height: 16 / 12,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _showSortDialog() {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                child: Text(
                  'SORT BY',
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1,
                    color: AppColors.muted,
                  ),
                ),
              ),
              for (final (orderKey, orderLabel) in _orders)
                ListTile(
                  leading: Icon(
                    _selectedOrder == orderKey ? Icons.check_circle_rounded : Icons.radio_button_unchecked,
                    color: _selectedOrder == orderKey ? AppColors.primary : AppColors.muted,
                  ),
                  title: Text(orderLabel, style: GoogleFonts.inter(fontSize: 14)),
                  onTap: () {
                    Navigator.pop(context);
                    if (_selectedOrder != orderKey) {
                      setState(() {
                        _selectedOrder = orderKey;
                        _page = 1;
                      });
                      _fetch();
                    }
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }
}
