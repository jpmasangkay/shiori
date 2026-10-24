import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../services/api_service.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'reader_screen.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  List<Map<String, dynamic>> _history = [];
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _fetch();
    ApiService.instance.addListener(_fetch);
  }

  @override
  void dispose() {
    ApiService.instance.removeListener(_fetch);
    super.dispose();
  }

  Future<void> _fetch() async {
    setState(() => _loading = true);
    try {
      final items = await ApiService.instance.getHistory();
      if (mounted) {
        setState(() {
          _history = items;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const AppTopBar(
          title: 'History',
          branded: true,
        ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator(color: AppColors.primary))
              : _history.isEmpty
                  ? _buildEmptyState()
                  : RefreshIndicator(
                      color: AppColors.primary,
                      backgroundColor: AppColors.surface,
                      onRefresh: _fetch,
                      child: ListView.builder(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        itemCount: _history.length,
                        itemBuilder: (_, i) => _buildHistoryRow(_history[i]),
                      ),
                    ),
        ),
      ],
    );
  }

  Widget _buildEmptyState() {
    final loggedIn = ApiService.instance.isLoggedIn;
    return EmptyState(
      icon: Icons.history_toggle_off_rounded,
      title: loggedIn ? 'No reading history yet' : 'No reading history',
      message: loggedIn
          ? 'Chapters you read will appear here so you can pick up where you left off.'
          : 'Sign in from the More tab to keep your reading history across devices.',
    );
  }

  Widget _buildHistoryRow(Map<String, dynamic> item) {
    final title = item['mangaTitle'] ?? 'Untitled';
    final chNum = item['chapterNumber'] ?? '';
    final page = item['page'] ?? 1;
    final total = item['totalPages'] ?? 0;
    final subtitle = 'Chapter $chNum · Page $page${total > 0 ? ' / $total' : ''}';

    return InkWell(
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => ReaderScreen(
              chapterId: item['chapterId']?.toString() ?? '',
              mangaId: item['mangaId']?.toString() ?? '',
              mangaTitle: title,
              coverUrl: item['cover'],
              chapterNumber: chNum.toString(),
            ),
          ),
        ).then((_) => _fetch());
      },
      child: Container(
        height: 64,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        child: Row(
          children: [
            SizedBox(
              width: 44,
              height: 56,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: CoverImage(imageUrl: item['cover'], saturation: .7),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: GoogleFonts.inter(fontSize: 11, color: AppColors.primary),
                  ),
                ],
              ),
            ),
            const Icon(Icons.play_circle_outline_rounded, color: AppColors.primary, size: 28),
          ],
        ),
      ),
    );
  }
}
