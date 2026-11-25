import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/manga_models.dart';
import '../services/api_service.dart';
import '../services/download_service.dart';
import '../services/extension_bridge.dart';
import '../services/extension_service.dart';
import '../services/local_database.dart';
import '../services/platform_bridge.dart';
import '../services/privacy_service.dart';
import '../services/reader_settings.dart';
import '../services/tracker_service.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/skeleton.dart';

enum ReaderMode {
  automatic, // ⚡ Automatic: Detects based on comic type (Manga: RTL, Manhwa: Webtoon, Other: LTR)
  rightToLeft, // 🇯🇵 Standard Manga: Right to Left
  webtoon, // 🇰🇷 Manhwa / Webtoon: Continuous vertical scroll
  leftToRight, // 🇨🇳 Manhua / Western: Left to Right
}

extension ReaderModeInfo on ReaderMode {
  String get label => switch (this) {
    ReaderMode.automatic => 'Automatic',
    ReaderMode.rightToLeft => 'RTL (Manga)',
    ReaderMode.webtoon => 'Webtoon',
    ReaderMode.leftToRight => 'Left-to-Right',
  };

  String get shortLabel => switch (this) {
    ReaderMode.automatic => 'Auto',
    ReaderMode.rightToLeft => 'RTL',
    ReaderMode.webtoon => 'Webtoon',
    ReaderMode.leftToRight => 'LTR',
  };

  IconData get icon => switch (this) {
    ReaderMode.automatic => Icons.auto_awesome_rounded,
    ReaderMode.rightToLeft => Icons.arrow_back_rounded,
    ReaderMode.webtoon => Icons.swap_vert_rounded,
    ReaderMode.leftToRight => Icons.arrow_forward_rounded,
  };
}

class ReaderScreen extends StatefulWidget {
  const ReaderScreen({
    super.key,
    this.chapterId,
    required this.mangaId,
    required this.mangaTitle,
    this.chapterNumber,
    this.chapterTitle,
    this.coverUrl,
    this.chapters = const [],
    this.initialIndex = 0,
    this.initialPage,
    this.mangaType,
    this.tags,
  });

  final String? chapterId;
  final String mangaId;
  final String mangaTitle;
  final String? chapterNumber;
  final String? chapterTitle;
  final String? coverUrl;
  final List<ChapterItem> chapters;
  final int initialIndex;
  final int? initialPage;
  final String? mangaType;
  final List<String>? tags;

  /// Resolves the automatic reading mode based on comic metadata:
  /// - Manga -> Right to Left (RTL paged)
  /// - Manhwa / Manhua / Webtoon -> Webtoon (continuous vertical scroll)
  /// - Other / Else (e.g. Western comic, unknown) -> Left to Right (LTR paged)
  static ReaderMode resolveAutomaticMode({
    String? type,
    String? mangaId,
    String? title,
    List<String>? tags,
  }) {
    final cleanType = type?.trim().toLowerCase() ?? '';
    final cleanId = mangaId?.trim().toLowerCase() ?? '';
    final cleanTitle = title?.trim().toLowerCase() ?? '';
    final lowerTags =
        tags?.map((t) => t.trim().toLowerCase()).toList() ?? const [];

    bool hasKeyword(String keyword) {
      if (cleanType == keyword || cleanType.contains(keyword)) return true;
      if (lowerTags.any((t) => t == keyword || t.contains(keyword)))
        return true;
      if (cleanTitle.contains('[$keyword]') ||
          cleanTitle.contains('($keyword)'))
        return true;
      return false;
    }

    // 1. Manhwa / Manhua / Webtoon: continuous vertical strip scroll
    final isVerticalStrip =
        hasKeyword('manhwa') ||
        hasKeyword('manwha') ||
        hasKeyword('manhua') ||
        hasKeyword('webtoon') ||
        hasKeyword('korean') ||
        hasKeyword('chinese') ||
        cleanId.startsWith('asura:') ||
        cleanId.startsWith('flame:');

    if (isVerticalStrip) {
      return ReaderMode.webtoon;
    }

    // 2. Explicit other comic formats (Western comic / Webcomic)
    final isOtherExplicit =
        hasKeyword('comic') || hasKeyword('western') || hasKeyword('webcomic');

    if (isOtherExplicit) {
      return ReaderMode.leftToRight;
    }

    // 3. Manga: Japanese standard right-to-left
    final isManga =
        hasKeyword('manga') ||
        hasKeyword('japanese') ||
        cleanId.startsWith('pill:') ||
        cleanId.startsWith('katana:') ||
        cleanId.startsWith('mread:');

    if (isManga) {
      return ReaderMode.rightToLeft;
    }

    // 4. Default fallback: other else -> left to right
    return ReaderMode.leftToRight;
  }

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen>
    with SingleTickerProviderStateMixin {
  late List<ChapterItem> _chapters;
  late int _currentChapterIndex;

  // Pages cache keyed by chapter ID
  final Map<String, List<String>> _pagesCache = {};
  final Map<String, List<String>> _dataSaverCache = {};
  final Set<String> _loadingChapterIds = {};
  final Map<String, String> _chapterErrors = {};
  final Set<String> _prefetchedUrls = {};

  // Strict read-all-pages tracking: 1-based page numbers genuinely viewed by the user.
  final Map<String, Set<int>> _viewedPagesByChapter = {};
  final Map<String, int> _lastNaturalWebtoonPage = {};

  // Webtoon continuous feed. Always an ascending, contiguous run of chapter
  // indices so chapters can never appear out of order or be skipped.
  final List<int> _webtoonLoadedIndices = [];
  final Map<String, _PageSlot> _pageSlots = {};
  final GlobalKey _listKey = GlobalKey();
  DateTime _trackingPausedUntil = DateTime.fromMillisecondsSinceEpoch(0);
  double? _webtoonScrollAnchorPx;

  int _totalPages = 1;
  int _page = 1;
  late final ValueNotifier<int> _pageNotifier;
  late final ValueNotifier<String> _clockNotifier;
  Timer? _clockTimer;
  final Set<String> _finishedChapterIds = {};
  Timer? _progressDebounceTimer;
  DateTime _lastTrackTime = DateTime.fromMillisecondsSinceEpoch(0);
  bool _chrome = true;
  bool _advancing = false;
  bool _showTapZoneOverlay = false;
  Timer? _tapZoneOverlayTimer;

  ReaderMode _selectedMode = ReaderMode.automatic;
  late ReaderMode _resolvedAutoMode;

  ReaderMode get _effectiveMode =>
      _selectedMode == ReaderMode.automatic ? _resolvedAutoMode : _selectedMode;
  ReaderMode get _mode => _effectiveMode;

  ReaderMode get selectedMode => _selectedMode;
  ReaderMode get effectiveMode => _effectiveMode;

  BoxFit _fitMode = ReaderSettings.instance.fitMode;
  bool _enableTapZones = ReaderSettings.instance.enableTapZones;
  bool _invertTapZones = ReaderSettings.instance.invertTapZones;
  bool _webtoonTapScroll = ReaderSettings.instance.webtoonTapScroll;
  bool _skipDuplicateChapters = ReaderSettings.instance.skipDuplicateChapters;
  ReaderOrientation _orientation = ReaderSettings.instance.orientation;
  double _brightness = ReaderSettings.instance.brightness;
  double _tint = ReaderSettings.instance.tint;
  bool _dataSaver = ReaderSettings.instance.dataSaver;
  bool _immersiveFullscreen = ReaderSettings.instance.immersiveFullscreen;
  bool _keepScreenOn = ReaderSettings.instance.keepScreenOn;
  bool _volumeKeyNav = ReaderSettings.instance.volumeKeyNavigation;
  bool _invertVolumeKeys = ReaderSettings.instance.invertVolumeKeys;
  bool _showStatusBar = ReaderSettings.instance.showReadingStatusBar;
  ReaderBackground _background = ReaderSettings.instance.background;
  bool _cropBorders = ReaderSettings.instance.cropBorders;
  bool _dualPageSpread = ReaderSettings.instance.dualPageSpread;
  bool _splitWidePages = ReaderSettings.instance.splitWidePages;
  double _webtoonSidePadding = ReaderSettings.instance.webtoonSidePadding;
  bool _grayscaleFilter = ReaderSettings.instance.grayscaleFilter;
  bool _invertColors = ReaderSettings.instance.invertColors;
  double _autoScrollSpeed = ReaderSettings.instance.autoScrollSpeed;
  bool _autoScrolling = false;
  Timer? _autoScrollTimer;
  Timer? _autoAdvanceTimer;
  StreamSubscription<String>? _volumeKeySub;
  bool _isPageZoomed = false;
  final TransformationController _webtoonTransformController =
      TransformationController();
  late final AnimationController _webtoonZoomAnimController =
      AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 180),
      );
  Animation<Matrix4>? _webtoonZoomAnim;
  TapDownDetails? _webtoonDoubleTapDetails;
  bool _isWebtoonZoomed = false;
  final DateTime _sessionStartedAt = DateTime.now();
  int _sessionPagesTurned = 0;
  int? _pendingInitialPage;

  final _scrollController = ScrollController();
  late PageController _pageController;

  ChapterItem get _currentChapter {
    if (_chapters.isEmpty) {
      return ChapterItem(
        id: widget.chapterId ?? '',
        number: widget.chapterNumber,
        title: widget.chapterTitle ?? 'Chapter',
      );
    }
    final idx = _currentChapterIndex.clamp(0, _chapters.length - 1);
    return _chapters[idx];
  }

  String get _chapterLabel {
    final c = _currentChapter;
    final n = c.number;
    return (n != null && n.isNotEmpty)
        ? 'Chapter $n'
        : (c.title.isNotEmpty ? c.title : 'Chapter');
  }

  String get _effectiveMangaTitle {
    final t = widget.mangaTitle.trim();
    if (t.isNotEmpty &&
        t != 'Untitled' &&
        !t.startsWith('ext:') &&
        t != widget.mangaId) {
      return t;
    }
    final known =
        ApiService.instance.libraryRepo.knownManga[widget.mangaId] ??
        ApiService.instance.libraryRepo.localLibrary[widget.mangaId];
    if (known != null &&
        known.displayTitle.isNotEmpty &&
        known.displayTitle != 'Untitled') {
      return known.displayTitle;
    }
    return MangaItem.cleanTitleFromIdOrSlug(
      widget.mangaId.isNotEmpty ? widget.mangaId : t,
    );
  }

  bool get _hasNextChapter =>
      _findAdjacentChapterIndex(_currentChapterIndex, 1) != null;
  bool get _hasPrevChapter =>
      _findAdjacentChapterIndex(_currentChapterIndex, -1) != null;

  static String? _normalizedChapterNum(ChapterItem ch) {
    final raw = ch.number?.trim();
    if (raw == null || raw.isEmpty) return null;
    final parsed = double.tryParse(raw);
    return parsed != null ? parsed.toString() : raw.toLowerCase();
  }

  /// Resolves the next (+1) or previous (-1) chapter index, optionally skipping
  /// duplicate chapter numbers uploaded by multiple scanlation groups.
  int? _findAdjacentChapterIndex(int fromIdx, int delta) {
    if (_chapters.isEmpty || delta == 0) return null;
    final curNum =
        _skipDuplicateChapters && fromIdx >= 0 && fromIdx < _chapters.length
        ? _normalizedChapterNum(_chapters[fromIdx])
        : null;
    var idx = fromIdx + delta;
    while (idx >= 0 && idx < _chapters.length) {
      if (curNum == null || _normalizedChapterNum(_chapters[idx]) != curNum) {
        return idx;
      }
      idx += delta;
    }
    return null;
  }

  void _applyOrientation(ReaderOrientation orientation) {
    switch (orientation) {
      case ReaderOrientation.free:
        SystemChrome.setPreferredOrientations(const []);
      case ReaderOrientation.portrait:
        SystemChrome.setPreferredOrientations(const [
          DeviceOrientation.portraitUp,
          DeviceOrientation.portraitDown,
        ]);
      case ReaderOrientation.landscape:
        SystemChrome.setPreferredOrientations(const [
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]);
    }
  }

  // keepPage: false stops PageStorage from restoring the previous chapter's
  // page index when the PageView is rebuilt for a different chapter.
  PageController _newPageController(int initialPage) =>
      PageController(initialPage: initialPage, keepPage: false);

  void _pauseTracking([int milliseconds = 500]) {
    _trackingPausedUntil = DateTime.now().add(
      Duration(milliseconds: milliseconds),
    );
  }

  static String _formatClockNow() {
    final nowTime = TimeOfDay.now();
    return '${nowTime.hour.toString().padLeft(2, '0')}:${nowTime.minute.toString().padLeft(2, '0')}';
  }

  void _recordPagesViewed(String chapterId, Iterable<int> pageNumbers) {
    if (chapterId.isEmpty) return;
    final pages = _pagesCache[chapterId];
    final maxPage = pages?.length ?? 0;
    final set = _viewedPagesByChapter.putIfAbsent(chapterId, () => <int>{});
    for (final p in pageNumbers) {
      if (p >= 1 && (maxPage == 0 || p <= maxPage)) {
        set.add(p);
      }
    }
  }

  /// True ONLY when every single page (1..total) of [chapterId] has been
  /// genuinely viewed by the user. Prevents premature mark-as-read on 85%,
  /// skipping chapters, prefetching webtoon chapters, or scrubber jumps.
  bool _hasReadAllPages(String chapterId) {
    if (chapterId.isEmpty) return false;
    final pages = _pagesCache[chapterId];
    if (pages == null || pages.isEmpty) return false;
    final viewed = _viewedPagesByChapter[chapterId];
    if (viewed == null || viewed.length < pages.length) return false;
    for (var p = 1; p <= pages.length; p++) {
      if (!viewed.contains(p)) return false;
    }
    return true;
  }

  bool _isDualSpreadActive() {
    if (!_dualPageSpread || _mode == ReaderMode.webtoon) return false;
    final size = MediaQuery.sizeOf(context);
    return size.width >= 720 && size.width > size.height;
  }

  void _flashTapZoneOverlay() {
    _tapZoneOverlayTimer?.cancel();
    setState(() => _showTapZoneOverlay = true);
    _tapZoneOverlayTimer = Timer(const Duration(milliseconds: 1400), () {
      if (mounted) setState(() => _showTapZoneOverlay = false);
    });
  }

  void _handleWebtoonDoubleTap() {
    final currentScale = _webtoonTransformController.value.getMaxScaleOnAxis();
    final Matrix4 target;
    if (currentScale > 1.08) {
      target = Matrix4.identity();
    } else {
      const targetScale = 2.2;
      final position = _webtoonDoubleTapDetails?.localPosition ?? Offset.zero;
      final size = MediaQuery.sizeOf(context);
      final tx = (-position.dx * (targetScale - 1.0)).clamp(
        -(size.width * (targetScale - 1.0)),
        0.0,
      );
      final ty = (-position.dy * (targetScale - 1.0)).clamp(
        -(size.height * (targetScale - 1.0)),
        0.0,
      );
      target = Matrix4.identity()
        ..translateByDouble(tx, ty, 0.0, 1.0)
        ..scaleByDouble(targetScale, targetScale, 1.0, 1.0);
    }
    _webtoonZoomAnim =
        Matrix4Tween(
          begin: _webtoonTransformController.value,
          end: target,
        ).animate(
          CurvedAnimation(
            parent: _webtoonZoomAnimController,
            curve: Curves.easeOutCubic,
          ),
        );
    _webtoonZoomAnimController
      ..reset()
      ..forward();
  }

  @override
  void initState() {
    super.initState();
    _pageNotifier = ValueNotifier<int>(_page);
    _clockNotifier = ValueNotifier<String>(_formatClockNow());
    _clockTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (!mounted) return;
      final next = _formatClockNow();
      if (next != _clockNotifier.value) {
        _clockNotifier.value = next;
      }
    });
    _webtoonZoomAnimController.addListener(() {
      final anim = _webtoonZoomAnim;
      if (anim != null) {
        _webtoonTransformController.value = anim.value;
      }
    });
    _pageController = _newPageController(0);
    SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle.light);

    // 1. Initial resolution of automatic reading direction based on metadata
    final cached =
        ApiService.instance.libraryRepo.knownManga[widget.mangaId] ??
        ApiService.instance.libraryRepo.localLibrary[widget.mangaId];

    _resolvedAutoMode = ReaderScreen.resolveAutomaticMode(
      type: widget.mangaType ?? cached?.type,
      mangaId: widget.mangaId,
      title: widget.mangaTitle.isNotEmpty
          ? widget.mangaTitle
          : (cached?.title ?? ''),
      tags: widget.tags ?? cached?.tags,
    );

    // 2. Load preferences synchronously from ReaderSettings
    final savedModeStr = ReaderSettings.instance.getReadingDirectionForManga(
      widget.mangaId,
    );
    final saved = ReaderMode.values.cast<ReaderMode?>().firstWhere(
      (m) => m?.name == savedModeStr,
      orElse: () => null,
    );
    if (saved != null) {
      _selectedMode = saved;
    }
    _fitMode = ReaderSettings.instance.fitMode;
    _enableTapZones = ReaderSettings.instance.enableTapZones;
    _invertTapZones = ReaderSettings.instance.invertTapZones;
    _webtoonTapScroll = ReaderSettings.instance.webtoonTapScroll;
    _skipDuplicateChapters = ReaderSettings.instance.skipDuplicateChapters;
    _orientation = ReaderSettings.instance.orientation;
    _brightness = ReaderSettings.instance.brightness;
    _tint = ReaderSettings.instance.tint;
    _dataSaver = ReaderSettings.instance.dataSaver;
    _immersiveFullscreen = ReaderSettings.instance.immersiveFullscreen;
    _keepScreenOn = ReaderSettings.instance.keepScreenOn;
    _volumeKeyNav = ReaderSettings.instance.volumeKeyNavigation;
    _invertVolumeKeys = ReaderSettings.instance.invertVolumeKeys;
    _showStatusBar = ReaderSettings.instance.showReadingStatusBar;
    _background = ReaderSettings.instance.background;
    _cropBorders = ReaderSettings.instance.cropBorders;
    _dualPageSpread = ReaderSettings.instance.dualPageSpread;
    _splitWidePages = ReaderSettings.instance.splitWidePages;
    _webtoonSidePadding = ReaderSettings.instance.webtoonSidePadding;
    _grayscaleFilter = ReaderSettings.instance.grayscaleFilter;
    _invertColors = ReaderSettings.instance.invertColors;
    _autoScrollSpeed = ReaderSettings.instance.autoScrollSpeed;

    _webtoonTransformController.addListener(_onWebtoonTransformChanged);
    unawaited(PlatformBridge.instance.setKeepScreenOn(_keepScreenOn));
    unawaited(PlatformBridge.instance.setVolumeKeyIntercept(_volumeKeyNav));
    _volumeKeySub = PlatformBridge.instance.volumeKeyStream.listen(
      _onVolumeKey,
    );
    if (_orientation != ReaderOrientation.free) {
      _applyOrientation(_orientation);
    }
    if (_immersiveFullscreen) {
      SystemChrome.setEnabledSystemUIMode(
        _chrome ? SystemUiMode.edgeToEdge : SystemUiMode.immersiveSticky,
      );
    }

    // Async re-check in case ReaderSettings was initialized concurrently
    SharedPreferences.getInstance().then((prefs) {
      if (mounted) {
        final asyncSavedStr = prefs.getString(
          'reader_direction_${widget.mangaId}',
        );
        ReaderMode? asyncSaved;
        if (asyncSavedStr != null) {
          asyncSaved = ReaderMode.values.cast<ReaderMode?>().firstWhere(
            (m) => m?.name == asyncSavedStr,
            orElse: () => null,
          );
        }

        final oldEffective = _effectiveMode;
        setState(() {
          _enableTapZones =
              prefs.getBool('reader_enable_tap_zones') ??
              ReaderSettings.instance.enableTapZones;
          _invertTapZones =
              prefs.getBool('reader_invert_tap_zones') ??
              ReaderSettings.instance.invertTapZones;
          _brightness =
              prefs.getDouble('reader_brightness') ??
              ReaderSettings.instance.brightness;
          _tint =
              prefs.getDouble('reader_tint') ?? ReaderSettings.instance.tint;
          final fitStr = prefs.getString('reader_fit_mode');
          if (fitStr == 'contain') {
            _fitMode = BoxFit.contain;
          } else if (fitStr == 'fitWidth') {
            _fitMode = BoxFit.fitWidth;
          }
          if (asyncSaved != null) {
            _selectedMode = asyncSaved;
          }
        });

        if (_effectiveMode != oldEffective) {
          final oldCtrl = _pageController;
          _pageController = _newPageController(_page - 1);
          _webtoonLoadedIndices
            ..clear()
            ..add(_currentChapterIndex);
          _pageSlots.clear();
          WidgetsBinding.instance.addPostFrameCallback((_) {
            oldCtrl.dispose();
            if (mounted && _effectiveMode == ReaderMode.webtoon && _page > 1) {
              _scrollToWebtoonPage(_page);
            }
          });
        }
      }
    });

    // 3. Asynchronous refinement if metadata was not yet in cache
    if ((widget.mangaType == null || widget.mangaType!.isEmpty) &&
        cached == null &&
        widget.mangaId.isNotEmpty) {
      ApiService.instance
          .getManga(widget.mangaId)
          .then((m) {
            if (!mounted) return;
            final updatedAuto = ReaderScreen.resolveAutomaticMode(
              type: m.type,
              mangaId: m.id,
              title: m.title,
              tags: m.tags,
            );
            if (updatedAuto != _resolvedAutoMode) {
              final oldEffective = _effectiveMode;
              setState(() {
                _resolvedAutoMode = updatedAuto;
              });
              if (_selectedMode == ReaderMode.automatic &&
                  _effectiveMode != oldEffective) {
                final oldCtrl = _pageController;
                setState(() {
                  _pageController = _newPageController(_page - 1);
                  _webtoonLoadedIndices
                    ..clear()
                    ..add(_currentChapterIndex);
                  _pageSlots.clear();
                });
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  oldCtrl.dispose();
                  if (mounted &&
                      _effectiveMode == ReaderMode.webtoon &&
                      _page > 1) {
                    _scrollToWebtoonPage(_page);
                  }
                });
              }
            }
          })
          .catchError((_) {});
    }

    // Setup chapters list — always normalize to chronological ascending order
    // so Next/Prev chapter navigation works identically from Library, History,
    // Updates, Downloads, and Detail screens.
    if (widget.chapters.isNotEmpty) {
      final requestedId =
          (widget.chapterId != null && widget.chapterId!.isNotEmpty)
          ? widget.chapterId!
          : widget
                .chapters[widget.initialIndex.clamp(
                  0,
                  widget.chapters.length - 1,
                )]
                .id;
      _chapters = sortChaptersChronologically(widget.chapters);
      final matchIdx = _chapters.indexWhere((c) => c.id == requestedId);
      _currentChapterIndex = matchIdx >= 0
          ? matchIdx
          : widget.initialIndex.clamp(0, _chapters.length - 1);
    } else {
      final fallback = ChapterItem(
        id: widget.chapterId ?? '',
        number: widget.chapterNumber,
        title: widget.chapterTitle ?? '',
      );
      _chapters = [fallback];
      _currentChapterIndex = 0;

      // Background-hydrate the full chapter list when opened from Updates/History
      // with no cached chapters so Next/Prev chapter navigation works seamlessly.
      if (widget.mangaId.isNotEmpty) {
        ApiService.instance
            .getChapters(widget.mangaId)
            .then((fetched) {
              if (!mounted || fetched.isEmpty) return;
              final ordered = sortChaptersChronologically(fetched);
              final curId = _currentChapter.id;
              var matchIdx = ordered.indexWhere((c) => c.id == curId);
              if (matchIdx < 0 && _currentChapter.number != null) {
                matchIdx = ordered.indexWhere(
                  (c) => c.number == _currentChapter.number,
                );
              }
              if (matchIdx < 0) return;
              setState(() {
                _chapters = ordered;
                _currentChapterIndex = matchIdx;
                _webtoonLoadedIndices
                  ..clear()
                  ..add(matchIdx);
                _pageSlots.clear();
              });
              final nextIdx = _findAdjacentChapterIndex(matchIdx, 1);
              if (nextIdx != null) {
                _loadChapter(nextIdx);
              }
            })
            .catchError((_) {});
      }
    }

    _webtoonLoadedIndices.add(_currentChapterIndex);

    // Resolve saved page progress if resuming an unfinished chapter
    int startPage = widget.initialPage ?? 1;
    if (widget.initialPage == null && widget.mangaId.isNotEmpty) {
      final curChId = _currentChapter.id;
      final savedPage = ApiService.instance.getSavedPageForChapter(
        widget.mangaId,
        curChId,
      );
      if (savedPage != null && savedPage > 1) {
        startPage = savedPage;
      }
    }
    if (startPage > 1) {
      _page = startPage;
      _pageNotifier.value = startPage;
      _pendingInitialPage = startPage;
    }

    _loadChapter(_currentChapterIndex);
  }

  void _setEnableTapZones(bool val) {
    setState(() => _enableTapZones = val);
    ReaderSettings.instance.setEnableTapZones(val);
    if (val) _flashTapZoneOverlay();
  }

  void _setInvertTapZones(bool val) {
    setState(() => _invertTapZones = val);
    ReaderSettings.instance.setInvertTapZones(val);
    if (_enableTapZones) _flashTapZoneOverlay();
  }

  void _setBrightness(double val) {
    final clamped = val.clamp(0.1, 1.0);
    setState(() => _brightness = clamped);
    ReaderSettings.instance.setBrightness(clamped);
  }

  void _setTint(double val) {
    final clamped = val.clamp(0.0, 1.0);
    setState(() => _tint = clamped);
    ReaderSettings.instance.setTint(clamped);
  }

  void _setDataSaver(bool val) {
    setState(() => _dataSaver = val);
    ReaderSettings.instance.setDataSaver(val);
  }

  void _onWebtoonTransformChanged() {
    final zoomed = _webtoonTransformController.value.getMaxScaleOnAxis() > 1.05;
    if (zoomed != _isWebtoonZoomed && mounted) {
      setState(() => _isWebtoonZoomed = zoomed);
    }
  }

  void _onVolumeKey(String dir) {
    if (!mounted || !_volumeKeyNav) return;
    final goNext = _invertVolumeKeys ? (dir == 'up') : (dir == 'down');
    if (_mode == ReaderMode.webtoon) {
      if (_scrollController.hasClients) {
        final step = MediaQuery.sizeOf(context).height * 0.75;
        final target = (_scrollController.offset + (goNext ? step : -step))
            .clamp(0.0, _scrollController.position.maxScrollExtent);
        _scrollController.animateTo(
          target,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
        );
      }
    } else {
      if (goNext) {
        _nextPage();
      } else {
        _prevPage();
      }
    }
  }

  void _toggleAutoScroll([bool? force]) {
    final next = force ?? !_autoScrolling;
    _autoScrollTimer?.cancel();
    _autoAdvanceTimer?.cancel();
    _autoScrollTimer = null;
    if (!next) {
      if (mounted) setState(() => _autoScrolling = false);
      return;
    }
    setState(() => _autoScrolling = true);
    if (_mode == ReaderMode.webtoon) {
      _autoScrollTimer = Timer.periodic(const Duration(milliseconds: 32), (_) {
        if (!mounted || !_autoScrolling || !_scrollController.hasClients)
          return;
        final max = _scrollController.position.maxScrollExtent;
        final cur = _scrollController.offset;
        if (cur >= max - 2) {
          _toggleAutoScroll(false);
          return;
        }
        // Speed 1.0x ~= 75 px/sec (2.4 px per 32ms frame)
        _scrollController.jumpTo(
          (cur + 2.4 * _autoScrollSpeed).clamp(0.0, max),
        );
      });
    } else {
      final intervalMs = (5000 / _autoScrollSpeed).round().clamp(1200, 18000);
      _autoScrollTimer = Timer.periodic(Duration(milliseconds: intervalMs), (
        _,
      ) {
        if (!mounted || !_autoScrolling) return;
        _nextPage();
      });
    }
  }

  void _toggleChrome() {
    final nextChrome = !_chrome;
    setState(() => _chrome = nextChrome);
    if (_immersiveFullscreen) {
      SystemChrome.setEnabledSystemUIMode(
        nextChrome ? SystemUiMode.edgeToEdge : SystemUiMode.immersiveSticky,
      );
    }
  }

  void _showChaptersDrawer() {
    var descending = false;
    var didAutoScroll = false;

    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.62,
          minChildSize: 0.35,
          maxChildSize: 0.88,
          builder: (_, scrollCtrl) {
            if (!didAutoScroll && _chapters.length > 6) {
              didAutoScroll = true;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!scrollCtrl.hasClients) return;
                final visualIdx = descending
                    ? (_chapters.length - 1 - _currentChapterIndex)
                    : _currentChapterIndex;
                final targetOffset =
                    ((visualIdx - 2).clamp(0, _chapters.length - 1)) * 58.0;
                scrollCtrl.jumpTo(
                  targetOffset.clamp(0.0, scrollCtrl.position.maxScrollExtent),
                );
              });
            }
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 14, 8, 8),
                  child: Row(
                    children: [
                      Text(
                        'CHAPTERS (${_chapters.length})',
                        style: AppText.sectionHeader,
                      ),
                      const Spacer(),
                      IconButton(
                        tooltip: descending
                            ? 'Sort oldest first'
                            : 'Sort latest first',
                        icon: Icon(
                          descending
                              ? Icons.south_rounded
                              : Icons.north_rounded,
                          size: 18,
                          color: AppColors.primary,
                        ),
                        onPressed: () {
                          setSheetState(() {
                            descending = !descending;
                            didAutoScroll = false;
                          });
                        },
                      ),
                      IconButton(
                        tooltip: 'Close',
                        icon: Icon(Icons.close_rounded, color: AppColors.muted),
                        onPressed: () => Navigator.of(ctx).pop(),
                      ),
                    ],
                  ),
                ),
                Divider(color: AppColors.outline, height: 1),
                Expanded(
                  child: ListView.builder(
                    controller: scrollCtrl,
                    itemExtent: 58,
                    itemCount: _chapters.length,
                    itemBuilder: (_, visualIdx) {
                      final idx = descending
                          ? (_chapters.length - 1 - visualIdx)
                          : visualIdx;
                      final ch = _chapters[idx];
                      final isCurrent = idx == _currentChapterIndex;
                      final isRead = ApiService.instance.isChapterRead(
                        widget.mangaId,
                        ch.id,
                      );
                      final savedPage = !isRead
                          ? ApiService.instance.getSavedPageForChapter(
                              widget.mangaId,
                              ch.id,
                            )
                          : null;
                      return ListTile(
                        dense: true,
                        selected: isCurrent,
                        selectedTileColor: AppColors.active.withValues(
                          alpha: 0.5,
                        ),
                        leading: Icon(
                          isCurrent
                              ? Icons.play_arrow_rounded
                              : (isRead
                                    ? Icons.check_circle_outline_rounded
                                    : Icons.circle_outlined),
                          size: 18,
                          color: isCurrent
                              ? AppColors.primary
                              : (isRead ? AppColors.read : AppColors.muted),
                        ),
                        title: Text(
                          ch.displayTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.bodyMedium.copyWith(
                            color: isCurrent
                                ? AppColors.primary
                                : (isRead ? AppColors.read : AppColors.text),
                          ),
                        ),
                        subtitle: (savedPage != null || ch.group.isNotEmpty)
                            ? Text(
                                [
                                  if (savedPage != null) 'Page $savedPage',
                                  if (ch.group.isNotEmpty) ch.group,
                                ].join(' · '),
                                style: AppText.caption,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              )
                            : null,
                        onTap: () {
                          Navigator.of(ctx).pop();
                          if (idx != _currentChapterIndex) {
                            _switchToChapter(idx);
                          }
                        },
                      );
                    },
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Future<void> _showPageContextMenu(
    String pageUrl,
    int pageNumber,
    VoidCallback onReload,
  ) async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Row(
                children: [
                  Text(
                    'PAGE $pageNumber OPTIONS',
                    style: AppText.sectionHeader,
                  ),
                ],
              ),
            ),
            ListTile(
              leading: Icon(Icons.save_alt_rounded, color: AppColors.primary),
              title: Text('Save Page to Device', style: AppText.bodyMedium),
              onTap: () async {
                Navigator.of(ctx).pop();
                await _exportSinglePage(pageUrl, pageNumber, share: false);
              },
            ),
            ListTile(
              leading: Icon(Icons.share_rounded, color: AppColors.primary),
              title: Text('Share Page', style: AppText.bodyMedium),
              onTap: () async {
                Navigator.of(ctx).pop();
                await _exportSinglePage(pageUrl, pageNumber, share: true);
              },
            ),
            ListTile(
              leading: Icon(Icons.refresh_rounded, color: AppColors.muted),
              title: Text('Reload Page Image', style: AppText.bodyMedium),
              onTap: () {
                Navigator.of(ctx).pop();
                onReload();
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _exportSinglePage(
    String pageUrl,
    int pageNumber, {
    required bool share,
  }) async {
    try {
      Uint8List? bytes;
      if (pageUrl.startsWith('file://')) {
        bytes = await File(pageUrl.replaceFirst('file://', '')).readAsBytes();
      } else {
        bytes =
            ImageReferers.getCachedNativeBytes(pageUrl) ??
            await ImageReferers.fetchNativeBytes(pageUrl);
        if (bytes == null) {
          final headers = imageHeadersForUrl(pageUrl, mangaId: widget.mangaId);
          final res = await http
              .get(Uri.parse(pageUrl), headers: headers)
              .timeout(const Duration(seconds: 15));
          if (res.statusCode == 200) bytes = res.bodyBytes;
        }
      }
      if (bytes == null || bytes.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not read page image bytes.')),
          );
        }
        return;
      }
      final safeName =
          '${_effectiveMangaTitle.replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '_')}_p$pageNumber.jpg';
      if (share) {
        final tmp = await getTemporaryDirectory();
        final outFile = File('${tmp.path}/$safeName');
        await outFile.writeAsBytes(bytes, flush: true);
        await PlatformBridge.instance.shareFile(
          filePath: outFile.path,
          mimeType: 'image/jpeg',
          subject: '$_effectiveMangaTitle - Page $pageNumber',
        );
      } else {
        final saved = await PlatformBridge.instance.saveFile(
          fileName: safeName,
          bytes: bytes,
          mimeType: 'image/jpeg',
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                saved != null ? 'Saved $safeName' : 'Save cancelled',
              ),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Page export failed: $e')));
      }
    }
  }

  void _showDisplaySheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(ctx).height * 0.82,
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('DISPLAY & COMFORT', style: AppText.sectionHeader),
                      if (_brightness < 0.99 ||
                          _tint > 0.01 ||
                          _grayscaleFilter ||
                          _invertColors)
                        TextButton(
                          onPressed: () {
                            _setBrightness(1.0);
                            _setTint(0.0);
                            setState(() {
                              _grayscaleFilter = false;
                              _invertColors = false;
                            });
                            ReaderSettings.instance.setGrayscaleFilter(false);
                            ReaderSettings.instance.setInvertColors(false);
                            setSheetState(() {});
                          },
                          child: Text(
                            'Reset',
                            style: AppText.caption.copyWith(
                              color: AppColors.primary,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Icon(
                        Icons.brightness_medium_rounded,
                        size: 20,
                        color: AppColors.muted,
                      ),
                      const SizedBox(width: 8),
                      Text('Brightness', style: AppText.bodyMedium),
                      const Spacer(),
                      Text(
                        '${(_brightness * 100).round()}%',
                        style: AppText.caption,
                      ),
                    ],
                  ),
                  SliderTheme(
                    data: SliderTheme.of(ctx).copyWith(
                      activeTrackColor: AppColors.primary,
                      thumbColor: AppColors.primary,
                      inactiveTrackColor: AppColors.outline,
                    ),
                    child: Slider(
                      min: 0.1,
                      max: 1.0,
                      value: _brightness.clamp(0.1, 1.0),
                      onChanged: (val) {
                        _setBrightness(val);
                        setSheetState(() {});
                      },
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Icon(
                        Icons.wb_sunny_rounded,
                        size: 20,
                        color: Color(0xFFFFA726),
                      ),
                      const SizedBox(width: 8),
                      Text('Eye-Care Warm Tint', style: AppText.bodyMedium),
                      const Spacer(),
                      Text('${(_tint * 100).round()}%', style: AppText.caption),
                    ],
                  ),
                  SliderTheme(
                    data: SliderTheme.of(ctx).copyWith(
                      activeTrackColor: const Color(0xFFFFA726),
                      thumbColor: const Color(0xFFFFA726),
                      inactiveTrackColor: AppColors.outline,
                    ),
                    child: Slider(
                      min: 0.0,
                      max: 1.0,
                      value: _tint,
                      onChanged: (val) {
                        _setTint(val);
                        setSheetState(() {});
                      },
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text('BACKGROUND COLOR', style: AppText.sectionHeader),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final bg in ReaderBackground.values)
                        ChoiceChip(
                          label: Text(bg.label, style: AppText.chip),
                          selected: _background == bg,
                          avatar: Container(
                            width: 14,
                            height: 14,
                            decoration: BoxDecoration(
                              color: bg.color,
                              shape: BoxShape.circle,
                              border: Border.all(color: AppColors.outline),
                            ),
                          ),
                          onSelected: (_) {
                            setState(() => _background = bg);
                            ReaderSettings.instance.setBackground(bg);
                            setSheetState(() {});
                          },
                        ),
                    ],
                  ),
                  Divider(color: AppColors.outline, height: 24),
                  Row(
                    children: [
                      Icon(
                        Icons.play_circle_outline_rounded,
                        size: 20,
                        color: AppColors.primary,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'Auto-Scroll (${_autoScrollSpeed.toStringAsFixed(1)}x)',
                        style: AppText.bodyMedium,
                      ),
                      const Spacer(),
                      FilledButton.tonal(
                        onPressed: () {
                          _toggleAutoScroll();
                          setSheetState(() {});
                        },
                        child: Text(_autoScrolling ? 'Stop' : 'Start'),
                      ),
                    ],
                  ),
                  Slider(
                    min: 0.25,
                    max: 4.0,
                    divisions: 15,
                    value: _autoScrollSpeed,
                    onChanged: (v) {
                      setState(() => _autoScrollSpeed = v);
                      ReaderSettings.instance.setAutoScrollSpeed(v);
                      if (_autoScrolling) _toggleAutoScroll(true);
                      setSheetState(() {});
                    },
                  ),
                  if (_mode == ReaderMode.webtoon) ...[
                    Row(
                      children: [
                        Icon(
                          Icons.padding_rounded,
                          size: 20,
                          color: AppColors.muted,
                        ),
                        const SizedBox(width: 8),
                        Text('Webtoon Side Padding', style: AppText.bodyMedium),
                        const Spacer(),
                        Text(
                          '${(_webtoonSidePadding * 100).round()}%',
                          style: AppText.caption,
                        ),
                      ],
                    ),
                    Slider(
                      min: 0.0,
                      max: 0.25,
                      divisions: 10,
                      value: _webtoonSidePadding,
                      onChanged: (v) {
                        setState(() => _webtoonSidePadding = v);
                        ReaderSettings.instance.setWebtoonSidePadding(v);
                        setSheetState(() {});
                      },
                    ),
                  ],
                  Divider(color: AppColors.outline, height: 16),
                  Row(
                    children: [
                      Icon(
                        Icons.screen_rotation_rounded,
                        size: 20,
                        color: AppColors.muted,
                      ),
                      const SizedBox(width: 8),
                      Text('Screen Orientation', style: AppText.bodyMedium),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final ori in ReaderOrientation.values)
                        ChoiceChip(
                          label: Text(ori.label),
                          selected: _orientation == ori,
                          onSelected: (_) {
                            setState(() => _orientation = ori);
                            ReaderSettings.instance.setOrientation(ori);
                            _applyOrientation(ori);
                            setSheetState(() {});
                          },
                          selectedColor: AppColors.active,
                          backgroundColor: AppColors.surfaceHigh,
                          labelStyle: AppText.chip.copyWith(
                            color: _orientation == ori
                                ? AppColors.primary
                                : AppColors.muted,
                          ),
                          showCheckmark: false,
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _webtoonTapScroll,
                    activeThumbColor: AppColors.primary,
                    title: Text(
                      'Webtoon Tap-to-Scroll',
                      style: AppText.bodyMedium,
                    ),
                    subtitle: Text(
                      'Tap top/bottom edges to scroll smoothly in Webtoon mode',
                      style: AppText.caption,
                    ),
                    onChanged: (val) {
                      setState(() => _webtoonTapScroll = val);
                      ReaderSettings.instance.setWebtoonTapScroll(val);
                      setSheetState(() {});
                    },
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _skipDuplicateChapters,
                    activeThumbColor: AppColors.primary,
                    title: Text(
                      'Skip Duplicate Chapters',
                      style: AppText.bodyMedium,
                    ),
                    subtitle: Text(
                      'Skip duplicate chapter numbers from other scanlators',
                      style: AppText.caption,
                    ),
                    onChanged: (val) {
                      setState(() => _skipDuplicateChapters = val);
                      ReaderSettings.instance.setSkipDuplicateChapters(val);
                      setSheetState(() {});
                    },
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _keepScreenOn,
                    activeThumbColor: AppColors.primary,
                    title: Text('Keep Screen On', style: AppText.bodyMedium),
                    onChanged: (val) {
                      setState(() => _keepScreenOn = val);
                      ReaderSettings.instance.setKeepScreenOn(val);
                      PlatformBridge.instance.setKeepScreenOn(val);
                      setSheetState(() {});
                    },
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _volumeKeyNav,
                    activeThumbColor: AppColors.primary,
                    title: Text(
                      'Volume Keys Turn Pages',
                      style: AppText.bodyMedium,
                    ),
                    onChanged: (val) {
                      setState(() => _volumeKeyNav = val);
                      ReaderSettings.instance.setVolumeKeyNavigation(val);
                      PlatformBridge.instance.setVolumeKeyIntercept(val);
                      setSheetState(() {});
                    },
                  ),
                  if (_volumeKeyNav)
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _invertVolumeKeys,
                      activeThumbColor: AppColors.primary,
                      title: Text(
                        'Invert Volume Keys',
                        style: AppText.bodyMedium,
                      ),
                      onChanged: (val) {
                        setState(() => _invertVolumeKeys = val);
                        ReaderSettings.instance.setInvertVolumeKeys(val);
                        setSheetState(() {});
                      },
                    ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _cropBorders,
                    activeThumbColor: AppColors.primary,
                    title: Text('Crop Page Borders', style: AppText.bodyMedium),
                    subtitle: Text(
                      'Trim excess white/black scanner margins',
                      style: AppText.caption,
                    ),
                    onChanged: (val) {
                      setState(() => _cropBorders = val);
                      ReaderSettings.instance.setCropBorders(val);
                      setSheetState(() {});
                    },
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _dualPageSpread,
                    activeThumbColor: AppColors.primary,
                    title: Text(
                      'Double-Page Spread (Landscape)',
                      style: AppText.bodyMedium,
                    ),
                    onChanged: (val) {
                      setState(() => _dualPageSpread = val);
                      ReaderSettings.instance.setDualPageSpread(val);
                      setSheetState(() {});
                    },
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _splitWidePages,
                    activeThumbColor: AppColors.primary,
                    title: Text(
                      'Split Wide Spreads (Portrait)',
                      style: AppText.bodyMedium,
                    ),
                    subtitle: Text(
                      'Fit wide 2-page manga spreads cleanly in portrait',
                      style: AppText.caption,
                    ),
                    onChanged: (val) {
                      setState(() => _splitWidePages = val);
                      ReaderSettings.instance.setSplitWidePages(val);
                      setSheetState(() {});
                    },
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _showStatusBar,
                    activeThumbColor: AppColors.primary,
                    title: Text(
                      'Show Minimal Status Overlay',
                      style: AppText.bodyMedium,
                    ),
                    subtitle: Text(
                      'Display page number & clock when bars are hidden',
                      style: AppText.caption,
                    ),
                    onChanged: (val) {
                      setState(() => _showStatusBar = val);
                      ReaderSettings.instance.setShowReadingStatusBar(val);
                      setSheetState(() {});
                    },
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _immersiveFullscreen,
                    activeThumbColor: AppColors.primary,
                    title: Text(
                      'Immersive Fullscreen',
                      style: AppText.bodyMedium,
                    ),
                    onChanged: (val) {
                      setState(() => _immersiveFullscreen = val);
                      ReaderSettings.instance.setImmersiveFullscreen(val);
                      SystemChrome.setEnabledSystemUIMode(
                        val && !_chrome
                            ? SystemUiMode.immersiveSticky
                            : SystemUiMode.edgeToEdge,
                      );
                      setSheetState(() {});
                    },
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _grayscaleFilter,
                    activeThumbColor: AppColors.primary,
                    title: Text(
                      'Grayscale Filter (E-Ink Style)',
                      style: AppText.bodyMedium,
                    ),
                    onChanged: (val) {
                      setState(() => _grayscaleFilter = val);
                      ReaderSettings.instance.setGrayscaleFilter(val);
                      setSheetState(() {});
                    },
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _invertColors,
                    activeThumbColor: AppColors.primary,
                    title: Text(
                      'Invert Colors (Night Reading)',
                      style: AppText.bodyMedium,
                    ),
                    onChanged: (val) {
                      setState(() => _invertColors = val);
                      ReaderSettings.instance.setInvertColors(val);
                      setSheetState(() {});
                    },
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _dataSaver,
                    activeThumbColor: AppColors.primary,
                    title: Text(
                      'Data Saver (Slow Internet)',
                      style: AppText.bodyMedium,
                    ),
                    subtitle: Text(
                      'Prefer compressed images & reduce prefetch bandwidth',
                      style: AppText.caption,
                    ),
                    onChanged: (val) {
                      _setDataSaver(val);
                      setSheetState(() {});
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _clockTimer?.cancel();
    _tapZoneOverlayTimer?.cancel();
    _autoScrollTimer?.cancel();
    _autoAdvanceTimer?.cancel();
    _volumeKeySub?.cancel();
    _webtoonZoomAnimController.dispose();
    _webtoonTransformController.removeListener(_onWebtoonTransformChanged);
    _webtoonTransformController.dispose();
    unawaited(PlatformBridge.instance.setKeepScreenOn(false));
    unawaited(PlatformBridge.instance.setVolumeKeyIntercept(false));
    if (_orientation != ReaderOrientation.free) {
      SystemChrome.setPreferredOrientations(const []);
    }
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _flushProgress();
    if (!PrivacyService.instance.incognitoMode &&
        LocalDatabase.instance.isAvailable) {
      final elapsedSec = DateTime.now().difference(_sessionStartedAt).inSeconds;
      if (elapsedSec >= 3 || _sessionPagesTurned > 0) {
        unawaited(
          LocalDatabase.instance.recordReadingSession(
            mangaId: widget.mangaId,
            chapterId: _currentChapter.id,
            durationSeconds: elapsedSec,
            pagesRead: _sessionPagesTurned,
            startedAt: _sessionStartedAt,
          ),
        );
      }
    }
    _scrollController.dispose();
    _pageController.dispose();
    _pageNotifier.dispose();
    _clockNotifier.dispose();
    super.dispose();
  }

  /// Loads a chapter's pages. A chapter that fails to load (or has no pages) is
  /// recorded in [_chapterErrors] so the reader can show a Retry tile instead
  /// of silently skipping over it.
  Future<void> _loadChapter(int idx, {bool forceRefresh = false}) async {
    if (idx < 0 || idx >= _chapters.length) return;
    final chapter = _chapters[idx];
    if (!forceRefresh && _pagesCache.containsKey(chapter.id)) return;
    if (_loadingChapterIds.contains(chapter.id)) return;

    if (chapter.id.isEmpty) {
      setState(
        () => _chapterErrors[chapter.id] = 'This chapter is not available.',
      );
      return;
    }

    setState(() {
      if (forceRefresh) {
        _pagesCache.remove(chapter.id);
        _dataSaverCache.remove(chapter.id);
      }
      _chapterErrors.remove(chapter.id);
      _loadingChapterIds.add(chapter.id);
    });

    try {
      final res = await ApiService.instance.getChapterPages(
        chapter.id,
        forceRefresh: forceRefresh,
      );
      if (res.pages.isEmpty)
        throw Exception('No pages found for this chapter.');
      final useSaverFirst =
          _dataSaver && res.dataSaver.length == res.pages.length;
      final primaryPages = useSaverFirst ? res.dataSaver : res.pages;
      final backupPages = useSaverFirst ? res.pages : res.dataSaver;
      _pagesCache[chapter.id] = primaryPages;
      _dataSaverCache[chapter.id] = backupPages;
      _loadingChapterIds.remove(chapter.id);
      if (!mounted) return;

      final prefetchWin = _dataSaver ? 2 : 6;
      int targetStartPage = 1;
      if (idx == _currentChapterIndex) {
        final pending = _pendingInitialPage;
        _pendingInitialPage = null;
        if (pending != null && pending > 1) {
          targetStartPage = pending.clamp(1, primaryPages.length);
        } else {
          targetStartPage = _page.clamp(1, primaryPages.length);
        }
      }

      setState(() {
        if (idx == _currentChapterIndex) {
          _totalPages = primaryPages.length;
          _page = targetStartPage;
          _pageNotifier.value = targetStartPage;
          if (targetStartPage > 1 && _mode != ReaderMode.webtoon) {
            final oldCtrl = _pageController;
            final initialSpread = _isDualSpreadActive()
                ? ((targetStartPage - 1) ~/ 2)
                : (targetStartPage - 1);
            _pageController = _newPageController(initialSpread);
            WidgetsBinding.instance.addPostFrameCallback(
              (_) => oldCtrl.dispose(),
            );
          }
        }
      });

      if (idx == _currentChapterIndex) {
        // Seed pages 1..targetStartPage as viewed (if resuming from a saved
        // mid-chapter position, the user already read pages 1..targetStartPage;
        // otherwise only page 1 is viewed so far).
        final initialViewed = <int>[
          for (var p = 1; p <= targetStartPage; p++) p,
        ];
        if (_isDualSpreadActive() && targetStartPage < primaryPages.length) {
          initialViewed.add(targetStartPage + 1);
        }
        _recordPagesViewed(chapter.id, initialViewed);
        _lastNaturalWebtoonPage[chapter.id] = targetStartPage;
      }

      _precacheSlidingWindow(
        primaryPages,
        targetStartPage - 1,
        window: prefetchWin,
      );

      if (idx == _currentChapterIndex) {
        if (_mode == ReaderMode.webtoon) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            if (targetStartPage > 1) {
              _scrollToWebtoonPage(targetStartPage);
            } else {
              _recordVisibleWebtoonSlots();
            }
          });
        }
        _syncProgress(_page);
        _precacheRange(primaryPages, targetStartPage - 1, prefetchWin);
        // Prefetch the next chapter so continuing to read has no loading gap.
        final nextIdx = _findAdjacentChapterIndex(idx, 1);
        if (nextIdx != null) _loadChapter(nextIdx);
      } else if (idx == _currentChapterIndex + 1) {
        _precacheRange(primaryPages, 0, _dataSaver ? 1 : 3);
      }
    } catch (err) {
      _loadingChapterIds.remove(chapter.id);
      if (!mounted) return;
      setState(
        () => _chapterErrors[chapter.id] = err.toString().replaceFirst(
          'Exception: ',
          '',
        ),
      );
    }
  }

  Future<void> _reloadChapterPages(int idx) async {
    if (idx < 0 || idx >= _chapters.length) return;
    final chapter = _chapters[idx];
    final oldPages = _pagesCache[chapter.id] ?? const <String>[];
    for (final u in oldPages) {
      _prefetchedUrls.remove(u);
      if (u.startsWith('http')) {
        CachedNetworkImageProvider(u).evict().catchError((_) => false);
      }
    }
    await _loadChapter(idx, forceRefresh: true);
  }

  List<String> _fallbackUrlsFor(
    String chapterId,
    int pageIndex,
    String primaryUrl,
  ) {
    final fallbacks = <String>[];
    // If primaryUrl is a MangaDex@Home volunteer node, add official uploads.mangadex.org origin
    if (primaryUrl.contains('/data/') &&
        !primaryUrl.startsWith('https://uploads.mangadex.org/')) {
      final idx = primaryUrl.indexOf('/data/');
      if (idx != -1) {
        fallbacks.add(
          'https://uploads.mangadex.org${primaryUrl.substring(idx)}',
        );
      }
    }
    final savers = _dataSaverCache[chapterId];
    if (savers != null && pageIndex >= 0 && pageIndex < savers.length) {
      final saverUrl = savers[pageIndex];
      if (saverUrl.isNotEmpty &&
          saverUrl != primaryUrl &&
          !fallbacks.contains(saverUrl)) {
        fallbacks.add(saverUrl);
      }
    }
    return fallbacks;
  }

  int _computeDecodeWidth(BuildContext context) {
    final mq = MediaQuery.of(context);
    return (mq.size.width * mq.devicePixelRatio * 1.35).round().clamp(
      720,
      1600,
    );
  }

  void _precacheRange(List<String> pages, int start, int count) {
    if (!mounted || pages.isEmpty) return;
    final decodeWidth = _computeDecodeWidth(context);
    final end = math.min(pages.length, start + count);
    for (var i = math.max(0, start); i < end; i++) {
      final p = pages[i];
      if (!_prefetchedUrls.add(p)) continue;
      if (p.startsWith('file://')) {
        precacheImage(
          ResizeImage.resizeIfNeeded(
            decodeWidth,
            null,
            FileImage(File(p.replaceFirst('file://', ''))),
          ),
          context,
          onError: (_, _) {},
        );
      } else if (p.startsWith('http')) {
        // If this extension uses the native OkHttp loader, prefetch bytes directly
        // into the native + disk cache instead of double-fetching via CachedNetworkImage.
        final hasNative = ImageReferers.hasNativeLoader(
          p,
          mangaId: widget.mangaId,
        );
        if (hasNative && ImageReferers.prefersNative(p)) {
          unawaited(ImageReferers.fetchNativeBytes(p));
          continue;
        }
        if (hasNative) {
          unawaited(ImageReferers.fetchNativeBytes(p));
        }
        // Match _ReaderPageImage's exact ResizeImage(width: decodeWidth) cache key so
        // prefetched bitmaps hit ImageCache directly instead of decoding twice and
        // evicting previous pages when scrolling back.
        precacheImage(
          ResizeImage.resizeIfNeeded(
            decodeWidth,
            null,
            CachedNetworkImageProvider(p, headers: imageHeadersForUrl(p)),
          ),
          context,
          onError: (_, _) {},
        );
      }
    }
  }

  void _precacheSlidingWindow(
    List<String> pages,
    int currentIndex, {
    int window = 6,
  }) {
    if (!mounted || pages.isEmpty) return;
    final start = math.max(0, currentIndex - 3);
    final count = window + 4;
    _precacheRange(pages, start, count);
  }

  void _syncProgress(int currentPage) {
    if (widget.mangaId.isEmpty) return;
    final chapter = _currentChapter;
    if (chapter.id.isEmpty) return;

    final pages = _pagesCache[chapter.id];
    final actualTotal = pages?.length ?? _totalPages;
    // Mark as read ONLY when the user has genuinely viewed every page of this chapter.
    final isFinished = _hasReadAllPages(chapter.id);
    if (isFinished) {
      _onChapterFinished(_currentChapterIndex);
    }

    _progressDebounceTimer?.cancel();
    _progressDebounceTimer = Timer(const Duration(milliseconds: 350), () {
      if (!mounted) return;
      ApiService.instance.saveProgress(
        mangaId: widget.mangaId,
        chapterId: chapter.id,
        mangaTitle: _effectiveMangaTitle,
        cover: widget.coverUrl,
        chapterNumber: chapter.number,
        chapterTitle: chapter.title,
        page: currentPage,
        totalPages: actualTotal,
        completed: isFinished,
      );
    });
  }

  void _flushProgress() {
    _progressDebounceTimer?.cancel();
    _progressDebounceTimer = null;
    if (widget.mangaId.isEmpty) return;
    final chapter = _currentChapter;
    if (chapter.id.isEmpty) return;

    final pages = _pagesCache[chapter.id];
    final actualTotal = pages?.length ?? _totalPages;
    final isFinished = _hasReadAllPages(chapter.id);
    if (isFinished) {
      _onChapterFinished(_currentChapterIndex);
    }

    ApiService.instance.saveProgress(
      mangaId: widget.mangaId,
      chapterId: chapter.id,
      mangaTitle: _effectiveMangaTitle,
      cover: widget.coverUrl,
      chapterNumber: chapter.number,
      chapterTitle: chapter.title,
      page: _page,
      totalPages: actualTotal,
      completed: isFinished,
    );
  }

  void _onChapterFinished(int finishedIdx) {
    if (finishedIdx < 0 || finishedIdx >= _chapters.length) return;
    final finished = _chapters[finishedIdx];
    if (finished.id.isEmpty) return;
    if (!_finishedChapterIds.add(finished.id))
      return; // Avoid duplicate triggers

    // Automatically mark the finished chapter as read
    ApiService.instance.markChapterRead(
      widget.mangaId,
      finished.id,
      read: true,
    );
    // Clean up downloaded chapter if auto-delete after reading is enabled
    DownloadService.instance.onChapterFinishedReading(finished.id);
    // Auto sync reading progress to AniList Tracker
    TrackerService.instance.onChapterFinished(
      mangaTitle: _effectiveMangaTitle,
      chapterNumber: finished.number,
      mangaId: widget.mangaId,
    );
  }

  /// Jump to another chapter (bottom bar buttons / transition card / drawer).
  /// Never marks the previous chapter read unless every page was actually read!
  void _switchToChapter(int newIndex) {
    if (newIndex < 0 ||
        newIndex >= _chapters.length ||
        newIndex == _currentChapterIndex)
      return;
    final prevChapter = _chapters[_currentChapterIndex];
    if (_hasReadAllPages(prevChapter.id)) {
      _onChapterFinished(_currentChapterIndex);
    }
    // Persist where the user left off on the previous chapter before switching
    _flushProgress();

    final chapter = _chapters[newIndex];
    final cached = _pagesCache[chapter.id];
    final oldController = _pageController;
    final savedPage =
        ApiService.instance.getSavedPageForChapter(
          widget.mangaId,
          chapter.id,
        ) ??
        1;
    final startPage = cached != null
        ? savedPage.clamp(1, math.max(1, cached.length)).toInt()
        : savedPage;
    final initialSpread = _isDualSpreadActive()
        ? ((startPage - 1) ~/ 2)
        : (startPage - 1);

    _pauseTracking(600);
    _isPageZoomed = false;
    _webtoonTransformController.value = Matrix4.identity();
    _isWebtoonZoomed = false;
    _webtoonScrollAnchorPx = null;

    setState(() {
      _currentChapterIndex = newIndex;
      _page = startPage;
      _totalPages = cached?.length ?? 1;
      _pendingInitialPage = cached == null && startPage > 1 ? startPage : null;
      _chapterErrors.remove(chapter.id);
      _webtoonLoadedIndices
        ..clear()
        ..add(newIndex);
      _pageSlots.clear();
      _pageController = _newPageController(initialSpread);
    });
    _pageNotifier.value = startPage;
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => oldController.dispose(),
    );

    if (_scrollController.hasClients) _scrollController.jumpTo(0);

    if (cached != null) {
      final initialViewed = <int>[for (var p = 1; p <= startPage; p++) p];
      if (_isDualSpreadActive() && startPage < cached.length) {
        initialViewed.add(startPage + 1);
      }
      _recordPagesViewed(chapter.id, initialViewed);
      _lastNaturalWebtoonPage[chapter.id] = startPage;
      if (_mode == ReaderMode.webtoon) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          if (startPage > 1) {
            _scrollToWebtoonPage(startPage);
          } else {
            _recordVisibleWebtoonSlots();
          }
        });
      }
      _syncProgress(startPage);
      _precacheRange(cached, startPage - 1, 6);
      final nextIdx = _findAdjacentChapterIndex(newIndex, 1);
      if (nextIdx != null) _loadChapter(nextIdx);
    } else {
      _loadChapter(newIndex);
    }
  }

  // ---- Webtoon feed tracking ----

  /// Records every mounted webtoon page slot currently visible in (or scrolled
  /// above) the viewport as viewed, and marks a chapter read ONLY when all of
  /// its pages have been viewed.
  void _recordVisibleWebtoonSlots() {
    final listBox = _listKey.currentContext?.findRenderObject();
    if (listBox is! RenderBox || !listBox.attached || !listBox.hasSize) return;
    final listHeight = listBox.size.height;
    final touchedChapters = <int>{};

    for (final slot in _pageSlots.values) {
      final box = slot.key.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.attached || !box.hasSize) continue;
      final top = box.localToGlobal(Offset.zero, ancestor: listBox).dy;
      final bottom = top + box.size.height;
      // Visible inside the viewport (or already scrolled above the top)
      if (top < listHeight && bottom > 0) {
        if (slot.chapterIndex >= 0 && slot.chapterIndex < _chapters.length) {
          final chId = _chapters[slot.chapterIndex].id;
          _recordPagesViewed(chId, [slot.pageIndex + 1]);
          touchedChapters.add(slot.chapterIndex);
        }
      }
    }

    for (final chIdx in touchedChapters) {
      final ch = _chapters[chIdx];
      if (_hasReadAllPages(ch.id)) {
        _onChapterFinished(chIdx);
      }
    }
  }

  /// Appends the next chapter to the continuous feed. Never appends past a
  /// chapter that hasn't loaded, otherwise that chapter would be skipped.
  /// Prefetching the next chapter does NOT prematurely mark [last] as read!
  void _extendWebtoonFeed({bool userTappedTrigger = false}) {
    if (_webtoonLoadedIndices.isEmpty) return;
    final last = _webtoonLoadedIndices.last;
    final next = _findAdjacentChapterIndex(last, 1);
    if (next == null || next >= _chapters.length) return;
    if (!_pagesCache.containsKey(_chapters[last].id)) return;
    if (userTappedTrigger) {
      _recordVisibleWebtoonSlots();
      if (_hasReadAllPages(_chapters[last].id)) {
        _onChapterFinished(last);
      }
    }
    setState(() => _webtoonLoadedIndices.add(next));
    _loadChapter(next);
  }

  bool _onWebtoonScroll(ScrollNotification notif) {
    if (notif.depth != 0) return false;
    if (notif is! ScrollUpdateNotification && notif is! ScrollEndNotification)
      return false;

    // Auto-hide reader bars smoothly when user scrolls meaningfully in Webtoon mode
    if (_chrome &&
        notif is ScrollUpdateNotification &&
        notif.dragDetails != null) {
      _webtoonScrollAnchorPx ??= notif.metrics.pixels;
      if ((notif.metrics.pixels - _webtoonScrollAnchorPx!).abs() > 80) {
        _webtoonScrollAnchorPx = null;
        _toggleChrome();
      }
    } else if (notif is ScrollEndNotification) {
      _webtoonScrollAnchorPx = null;
    }

    if (notif.metrics.extentAfter < 2500) _extendWebtoonFeed();

    if (DateTime.now().isBefore(_trackingPausedUntil)) return false;

    final now = DateTime.now();
    // Throttle render-tree measurements to at most once per 80ms during scroll, or on scroll end
    if (notif is ScrollEndNotification ||
        now.difference(_lastTrackTime).inMilliseconds >= 80) {
      _lastTrackTime = now;
      _trackWebtoonPosition();
    }
    return false;
  }

  /// Finds the page that is actually under the reading line by measuring the
  /// mounted page widgets (page heights vary a lot, so estimating from the
  /// scroll fraction picks the wrong chapter/page).
  void _trackWebtoonPosition() {
    final listBox = _listKey.currentContext?.findRenderObject();
    if (listBox is! RenderBox || !listBox.attached || !listBox.hasSize) return;
    final listHeight = listBox.size.height;
    final anchor = listHeight * 0.4;

    _PageSlot? activeSlot;
    for (final slot in _pageSlots.values) {
      final box = slot.key.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.attached || !box.hasSize) continue;
      final top = box.localToGlobal(Offset.zero, ancestor: listBox).dy;
      final bottom = top + box.size.height;
      final chId = _chapters[slot.chapterIndex].id;

      // Record any page intersecting the viewport as viewed
      if (top < listHeight && bottom > 0) {
        _recordPagesViewed(chId, [slot.pageIndex + 1]);
      }

      if (top <= anchor && anchor < bottom) {
        activeSlot = slot;
      } else if (bottom <= anchor) {
        // User scrolled past this page naturally
        _recordPagesViewed(chId, [slot.pageIndex + 1]);
        final pages = _pagesCache[chId];
        if (pages != null &&
            pages.isNotEmpty &&
            slot.pageIndex >= pages.length - 1 &&
            _hasReadAllPages(chId)) {
          _onChapterFinished(slot.chapterIndex);
        }
      }
    }

    if (activeSlot != null) {
      _updateWebtoonPosition(activeSlot.chapterIndex, activeSlot.pageIndex);
    }
  }

  void _updateWebtoonPosition(int chapterIndex, int pageIndex) {
    final ch = _chapters[chapterIndex];
    final pages = _pagesCache[ch.id];
    if (pages == null || pages.isEmpty) return;
    final newPage = (pageIndex + 1).clamp(1, pages.length);

    // Record pages smoothly scrolled through during natural continuous scroll
    final prevNatural = _lastNaturalWebtoonPage[ch.id];
    if (prevNatural != null && newPage > prevNatural) {
      _recordPagesViewed(ch.id, [
        for (var p = prevNatural; p <= newPage; p++) p,
      ]);
    } else {
      _recordPagesViewed(ch.id, [newPage]);
    }
    _lastNaturalWebtoonPage[ch.id] = newPage;

    if (chapterIndex != _currentChapterIndex) {
      final oldIdx = _currentChapterIndex;
      if (oldIdx >= 0 && oldIdx < _chapters.length) {
        final oldCh = _chapters[oldIdx];
        if (_hasReadAllPages(oldCh.id)) {
          _onChapterFinished(oldIdx);
        }
      }
      setState(() {
        _currentChapterIndex = chapterIndex;
        _totalPages = pages.length;
        _page = newPage;
      });
      _pageNotifier.value = newPage;
      if (_hasReadAllPages(ch.id)) {
        _onChapterFinished(chapterIndex);
      }
      _syncProgress(newPage);
      _precacheSlidingWindow(pages, pageIndex, window: 6);
      final nextIdx = _findAdjacentChapterIndex(chapterIndex, 1);
      if (nextIdx != null) _loadChapter(nextIdx);
    } else if (newPage != _page) {
      _sessionPagesTurned++;
      _page = newPage;
      _pageNotifier.value = newPage;
      if (_hasReadAllPages(ch.id)) {
        _onChapterFinished(chapterIndex);
      }
      _syncProgress(newPage);
      _precacheSlidingWindow(pages, pageIndex, window: 6);
    }
  }

  void _scrollToWebtoonPage(int target) {
    if (!_scrollController.hasClients) return;
    _pauseTracking(450);

    final ctx =
        _pageSlots['p:$_currentChapterIndex:${target - 1}']?.key.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(
        ctx,
        alignment: 0.05,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeInOut,
      );
      return;
    }

    // Target page isn't built yet: step by the average height of built pages.
    var total = 0.0;
    var count = 0;
    for (final slot in _pageSlots.values) {
      final box = slot.key.currentContext?.findRenderObject();
      if (box is RenderBox && box.hasSize) {
        total += box.size.height;
        count++;
      }
    }
    final avg = count > 0 ? total / count : MediaQuery.sizeOf(context).height;
    final position = _scrollController.position;
    final dest = (position.pixels + (target - _page) * avg)
        .clamp(position.minScrollExtent, position.maxScrollExtent)
        .toDouble();
    _scrollController.animateTo(
      dest,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeInOut,
    );
  }

  void _go(int p) {
    final target = p.clamp(1, _totalPages);
    _page = target;
    _pageNotifier.value = target;
    _isPageZoomed = false;
    final chId = _currentChapter.id;
    // Jumping via scrubber only marks the destination page viewed, never skipped pages.
    _lastNaturalWebtoonPage.remove(chId);
    _recordPagesViewed(chId, [target]);
    if (_hasReadAllPages(chId)) {
      _onChapterFinished(_currentChapterIndex);
    }
    _syncProgress(target);

    if (_mode == ReaderMode.webtoon) {
      _scrollToWebtoonPage(target);
    } else if (_pageController.hasClients) {
      final pageIdx = _isDualSpreadActive()
          ? ((target - 1) ~/ 2)
          : (target - 1);
      _pageController.jumpToPage(pageIdx);
    }
  }

  void _setMode(ReaderMode mode) {
    if (mode == _selectedMode) return;
    final oldEffective = _effectiveMode;
    final oldController = _pageController;

    setState(() {
      _selectedMode = mode;
      final newEffective = _effectiveMode;
      if (newEffective != oldEffective) {
        _pageController = _newPageController(_page - 1);
        _webtoonLoadedIndices
          ..clear()
          ..add(_currentChapterIndex);
        _pageSlots.clear();
      }
    });

    ReaderSettings.instance.setReadingDirection(widget.mangaId, mode.name);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_effectiveMode != oldEffective) {
        oldController.dispose();
      }
      if (mounted && _effectiveMode == ReaderMode.webtoon && _page > 1) {
        _scrollToWebtoonPage(_page);
      }
    });

    final msg = mode == ReaderMode.automatic
        ? 'Reading Direction: Auto (${_effectiveMode.shortLabel})'
        : 'Reading Direction: ${mode.label}';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 1)),
    );
  }

  void _showModeSheet() {
    final hasPerMangaOverride = ReaderSettings.instance
        .hasPerMangaDirectionOverride(widget.mangaId);
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) => StatefulBuilder(
        builder: (sheetCtx, setSheet) => SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 8,
                  ),
                  child: Text(
                    'READING DIRECTION',
                    style: AppText.sectionHeader,
                  ),
                ),
                ListTile(
                  leading: Icon(
                    Icons.auto_awesome_rounded,
                    color: _selectedMode == ReaderMode.automatic
                        ? AppColors.primary
                        : AppColors.muted,
                  ),
                  title: Text('Automatic', style: AppText.bodyMedium),
                  subtitle: Text(
                    'Auto-detect: Manga → RTL, Manhwa/Manhua → Webtoon, Comics → LTR (${_effectiveMode.label})',
                    style: AppText.caption,
                  ),
                  trailing: _selectedMode == ReaderMode.automatic
                      ? Icon(Icons.check_rounded, color: AppColors.primary)
                      : null,
                  onTap: () {
                    Navigator.pop(sheetCtx);
                    _setMode(ReaderMode.automatic);
                  },
                ),
                ListTile(
                  leading: Icon(
                    Icons.arrow_back_rounded,
                    color: _selectedMode == ReaderMode.rightToLeft
                        ? AppColors.primary
                        : AppColors.muted,
                  ),
                  title: Text(
                    'Right to Left (Standard Manga 🇯🇵)',
                    style: AppText.bodyMedium,
                  ),
                  subtitle: Text(
                    'Swipe left for next page, auto-advances to next chapter',
                    style: AppText.caption,
                  ),
                  trailing: _selectedMode == ReaderMode.rightToLeft
                      ? Icon(Icons.check_rounded, color: AppColors.primary)
                      : null,
                  onTap: () {
                    Navigator.pop(sheetCtx);
                    _setMode(ReaderMode.rightToLeft);
                  },
                ),
                ListTile(
                  leading: Icon(
                    Icons.swap_vert_rounded,
                    color: _selectedMode == ReaderMode.webtoon
                        ? AppColors.primary
                        : AppColors.muted,
                  ),
                  title: Text(
                    'Webtoon (Manhwa / Manhua 🇰🇷🇨🇳)',
                    style: AppText.bodyMedium,
                  ),
                  subtitle: Text(
                    'Continuous vertical strip across chapters',
                    style: AppText.caption,
                  ),
                  trailing: _selectedMode == ReaderMode.webtoon
                      ? Icon(Icons.check_rounded, color: AppColors.primary)
                      : null,
                  onTap: () {
                    Navigator.pop(sheetCtx);
                    _setMode(ReaderMode.webtoon);
                  },
                ),
                ListTile(
                  leading: Icon(
                    Icons.arrow_forward_rounded,
                    color: _selectedMode == ReaderMode.leftToRight
                        ? AppColors.primary
                        : AppColors.muted,
                  ),
                  title: Text(
                    'Left to Right (Western Comics)',
                    style: AppText.bodyMedium,
                  ),
                  subtitle: Text(
                    'Swipe right for next page, auto-advances to next chapter',
                    style: AppText.caption,
                  ),
                  trailing: _selectedMode == ReaderMode.leftToRight
                      ? Icon(Icons.check_rounded, color: AppColors.primary)
                      : null,
                  onTap: () {
                    Navigator.pop(sheetCtx);
                    _setMode(ReaderMode.leftToRight);
                  },
                ),
                if (hasPerMangaOverride)
                  ListTile(
                    leading: Icon(
                      Icons.restart_alt_rounded,
                      color: AppColors.muted,
                    ),
                    title: Text(
                      'Reset to Global Default',
                      style: AppText.bodyMedium,
                    ),
                    subtitle: Text(
                      'Remove this title\'s custom reading direction override',
                      style: AppText.caption,
                    ),
                    onTap: () async {
                      Navigator.pop(sheetCtx);
                      await ReaderSettings.instance
                          .clearReadingDirectionOverride(widget.mangaId);
                      final globalStr =
                          ReaderSettings.instance.defaultDirection;
                      final globalMode =
                          ReaderMode.values.cast<ReaderMode?>().firstWhere(
                            (m) => m?.name == globalStr,
                            orElse: () => ReaderMode.automatic,
                          ) ??
                          ReaderMode.automatic;
                      if (!mounted) return;
                      final oldEffective = _effectiveMode;
                      final oldController = _pageController;
                      setState(() {
                        _selectedMode = globalMode;
                        if (_effectiveMode != oldEffective) {
                          _pageController = _newPageController(_page - 1);
                          _webtoonLoadedIndices
                            ..clear()
                            ..add(_currentChapterIndex);
                          _pageSlots.clear();
                        }
                      });
                      if (_effectiveMode != oldEffective) {
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          oldController.dispose();
                        });
                      }
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(
                            'Reset reading direction to global default',
                          ),
                          duration: Duration(seconds: 1),
                        ),
                      );
                    },
                  ),
                Divider(color: AppColors.outline, height: 24),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 8,
                  ),
                  child: Text(
                    'NAVIGATION & TOUCH CONTROLS',
                    style: AppText.sectionHeader,
                  ),
                ),
                SwitchListTile(
                  value: _enableTapZones,
                  activeThumbColor: AppColors.primary,
                  title: Text(
                    'Tap Zones Navigation',
                    style: AppText.bodyMedium,
                  ),
                  subtitle: Text(
                    'Tap sides to turn page, center for reader menu',
                    style: AppText.caption,
                  ),
                  onChanged: (val) {
                    _setEnableTapZones(val);
                    setSheet(() {});
                  },
                ),
                SwitchListTile(
                  value: _invertTapZones,
                  activeThumbColor: AppColors.primary,
                  title: Text('Invert Tap Zones', style: AppText.bodyMedium),
                  subtitle: Text(
                    'Flips left and right tap zone actions',
                    style: AppText.caption,
                  ),
                  onChanged: _enableTapZones
                      ? (val) {
                          _setInvertTapZones(val);
                          setSheet(() {});
                        }
                      : null,
                ),
                if (_enableTapZones)
                  ListTile(
                    leading: Icon(
                      Icons.touch_app_outlined,
                      color: AppColors.primary,
                    ),
                    title: Text('Preview Tap Zones', style: AppText.bodyMedium),
                    subtitle: Text(
                      'Briefly highlight Prev / Menu / Next tap zones on screen',
                      style: AppText.caption,
                    ),
                    onTap: () {
                      Navigator.pop(sheetCtx);
                      _flashTapZoneOverlay();
                    },
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _handleTap(TapUpDetails details, BoxConstraints constraints) {
    // Never accidentally turn pages when zoomed in or when tap zones are disabled
    if (_isPageZoomed || _isWebtoonZoomed || !_enableTapZones) {
      _toggleChrome();
      return;
    }

    if (_mode == ReaderMode.webtoon) {
      if (!_webtoonTapScroll || !_scrollController.hasClients) {
        _toggleChrome();
        return;
      }
      final y = details.localPosition.dy;
      final h = constraints.maxHeight;
      final topBound = h * 0.22;
      final bottomBound = h * 0.72;
      final step = h * 0.78;
      final pos = _scrollController.position;
      if (y < topBound) {
        final target = (pos.pixels - step).clamp(
          pos.minScrollExtent,
          pos.maxScrollExtent,
        );
        _scrollController.animateTo(
          target,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
        );
      } else if (y > bottomBound) {
        final target = (pos.pixels + step).clamp(
          pos.minScrollExtent,
          pos.maxScrollExtent,
        );
        _scrollController.animateTo(
          target,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
        );
      } else {
        _toggleChrome();
      }
      return;
    }

    final x = details.localPosition.dx;
    final w = constraints.maxWidth;
    final leftBound = w * 0.30;
    final rightBound = w * 0.70;

    final isRtl = _mode == ReaderMode.rightToLeft;
    bool nextOnRight = !isRtl;
    if (_invertTapZones) nextOnRight = !nextOnRight;

    if (x < leftBound) {
      if (nextOnRight) {
        _prevPage();
      } else {
        _nextPage();
      }
    } else if (x > rightBound) {
      if (nextOnRight) {
        _nextPage();
      } else {
        _prevPage();
      }
    } else {
      _toggleChrome();
    }
  }

  void _prevPage() {
    if (_pageController.hasClients && _pageController.page != null) {
      final cur = _pageController.page!.round();
      if (cur > 0) {
        _pageController.previousPage(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      } else {
        final prevIdx = _findAdjacentChapterIndex(_currentChapterIndex, -1);
        if (prevIdx != null) _switchToChapter(prevIdx);
      }
    }
  }

  void _nextPage() {
    if (_pageController.hasClients && _pageController.page != null) {
      _isPageZoomed = false;
      final cur = _pageController.page!.round();
      final pages = _pagesCache[_currentChapter.id];
      final pageLen = pages?.length ?? 0;
      final spreadCount = _isDualSpreadActive()
          ? (pageLen / 2).ceil()
          : pageLen;
      final total = spreadCount + (_hasNextChapter ? 1 : 0);
      if (cur + 1 < total) {
        _pageController.nextPage(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      } else {
        final nextIdx = _findAdjacentChapterIndex(_currentChapterIndex, 1);
        if (nextIdx != null) _switchToChapter(nextIdx);
      }
    }
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      Navigator.of(context).maybePop();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyM) {
      _toggleChrome();
      return KeyEventResult.handled;
    }
    if (_mode == ReaderMode.webtoon) {
      if (!_scrollController.hasClients) return KeyEventResult.ignored;
      final step = MediaQuery.sizeOf(context).height * 0.72;
      final pos = _scrollController.position;
      if (key == LogicalKeyboardKey.arrowDown ||
          key == LogicalKeyboardKey.pageDown ||
          key == LogicalKeyboardKey.space) {
        _scrollController.animateTo(
          (pos.pixels + step).clamp(pos.minScrollExtent, pos.maxScrollExtent),
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
        );
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowUp ||
          key == LogicalKeyboardKey.pageUp) {
        _scrollController.animateTo(
          (pos.pixels - step).clamp(pos.minScrollExtent, pos.maxScrollExtent),
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
        );
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    final isRtl = _mode == ReaderMode.rightToLeft;
    if (key == LogicalKeyboardKey.arrowRight) {
      isRtl ? _prevPage() : _nextPage();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      isRtl ? _nextPage() : _prevPage();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.space ||
        key == LogicalKeyboardKey.pageDown ||
        key == LogicalKeyboardKey.arrowDown) {
      _nextPage();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.pageUp || key == LogicalKeyboardKey.arrowUp) {
      _prevPage();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Future<void> _showJumpToPageDialog() async {
    if (_totalPages <= 1) return;
    final ctrl = TextEditingController(text: '$_page');
    String? err;
    final chosen = await showDialog<int>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          backgroundColor: AppColors.surface,
          title: Text('Jump to Page', style: AppText.sheetTitle),
          content: TextField(
            controller: ctrl,
            autofocus: true,
            keyboardType: TextInputType.number,
            style: AppText.body,
            decoration: InputDecoration(
              hintText: '1 – $_totalPages',
              errorText: err,
            ),
            onSubmitted: (_) {
              final n = int.tryParse(ctrl.text.trim());
              if (n == null || n < 1 || n > _totalPages) {
                setDlg(() => err = 'Enter a page between 1 and $_totalPages');
                return;
              }
              Navigator.pop(ctx, n);
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(
                'Cancel',
                style: AppText.bodyMedium.copyWith(color: AppColors.muted),
              ),
            ),
            FilledButton(
              onPressed: () {
                final n = int.tryParse(ctrl.text.trim());
                if (n == null || n < 1 || n > _totalPages) {
                  setDlg(() => err = 'Enter a page between 1 and $_totalPages');
                  return;
                }
                Navigator.pop(ctx, n);
              },
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: AppColors.onPrimary,
              ),
              child: const Text('Go'),
            ),
          ],
        ),
      ),
    );
    if (chosen != null && mounted) {
      _go(chosen);
    }
  }

  Widget _buildTapZoneGuideOverlay() {
    if (_mode == ReaderMode.webtoon) {
      return Column(
        children: [
          Expanded(
            flex: 22,
            child: Container(
              color: Colors.blueAccent.withValues(alpha: 0.24),
              alignment: Alignment.center,
              child: const Text(
                'SCROLL UP',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1,
                ),
              ),
            ),
          ),
          Expanded(
            flex: 50,
            child: Container(
              color: Colors.black.withValues(alpha: 0.22),
              alignment: Alignment.center,
              child: const Text(
                'MENU',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1,
                ),
              ),
            ),
          ),
          Expanded(
            flex: 28,
            child: Container(
              color: Colors.green.withValues(alpha: 0.24),
              alignment: Alignment.center,
              child: const Text(
                'SCROLL DOWN',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1,
                ),
              ),
            ),
          ),
        ],
      );
    }
    final isRtl = _mode == ReaderMode.rightToLeft;
    bool nextOnRight = !isRtl;
    if (_invertTapZones) nextOnRight = !nextOnRight;
    final leftLabel = nextOnRight ? 'PREV' : 'NEXT';
    final rightLabel = nextOnRight ? 'NEXT' : 'PREV';
    return Row(
      children: [
        Expanded(
          flex: 30,
          child: Container(
            color: (nextOnRight ? Colors.blueAccent : Colors.green).withValues(
              alpha: 0.24,
            ),
            alignment: Alignment.center,
            child: Text(
              leftLabel,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                letterSpacing: 1,
              ),
            ),
          ),
        ),
        Expanded(
          flex: 40,
          child: Container(
            color: Colors.black.withValues(alpha: 0.22),
            alignment: Alignment.center,
            child: const Text(
              'MENU',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                letterSpacing: 1,
              ),
            ),
          ),
        ),
        Expanded(
          flex: 30,
          child: Container(
            color: (nextOnRight ? Colors.green : Colors.blueAccent).withValues(
              alpha: 0.24,
            ),
            alignment: Alignment.center,
            child: Text(
              rightLabel,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                letterSpacing: 1,
              ),
            ),
          ),
        ),
      ],
    );
  }

  static const ColorFilter _grayscaleColorFilter = ColorFilter.matrix(<double>[
    0.2126,
    0.7152,
    0.0722,
    0,
    0,
    0.2126,
    0.7152,
    0.0722,
    0,
    0,
    0.2126,
    0.7152,
    0.0722,
    0,
    0,
    0,
    0,
    0,
    1,
    0,
  ]);

  static const ColorFilter _invertColorFilter = ColorFilter.matrix(<double>[
    -1,
    0,
    0,
    0,
    255,
    0,
    -1,
    0,
    0,
    255,
    0,
    0,
    -1,
    0,
    255,
    0,
    0,
    0,
    1,
    0,
  ]);

  Widget _applyColorFilters(Widget child) {
    Widget out = child;
    if (_grayscaleFilter) {
      out = ColorFiltered(colorFilter: _grayscaleColorFilter, child: out);
    }
    if (_invertColors) {
      out = ColorFiltered(colorFilter: _invertColorFilter, child: out);
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, result) {
        _flushProgress();
      },
      child: Focus(
        autofocus: true,
        onKeyEvent: _handleKeyEvent,
        child: Scaffold(
          backgroundColor: _background.color,
          body: Stack(
            fit: StackFit.expand,
            children: [
              // Content reader layer
              LayoutBuilder(
                builder: (context, constraints) {
                  return GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapUp: (details) => _handleTap(details, constraints),
                    child: _applyColorFilters(_buildReaderBody()),
                  );
                },
              ),
              // Brightness dimming overlay (down to 10% brightness -> up to 0.90 alpha)
              if (_brightness < 0.99)
                Positioned.fill(
                  child: IgnorePointer(
                    child: ColoredBox(
                      color: Colors.black.withValues(
                        alpha: (1.0 - _brightness).clamp(0.0, 0.9),
                      ),
                    ),
                  ),
                ),
              // Warm eye-care tint overlay
              if (_tint > 0.01)
                Positioned.fill(
                  child: IgnorePointer(
                    child: ColoredBox(
                      color: const Color(
                        0xFFFFA726,
                      ).withValues(alpha: (_tint * 0.35).clamp(0.0, 0.45)),
                    ),
                  ),
                ),
              // Tap-zone visual guide overlay (brief preview when requested)
              if (_showTapZoneOverlay)
                Positioned.fill(
                  child: IgnorePointer(child: _buildTapZoneGuideOverlay()),
                ),
              // Minimal always-visible reading status bar when chrome is hidden
              if (!_chrome && _showStatusBar && _totalPages > 0)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: MediaQuery.paddingOf(context).bottom + 4,
                  child: IgnorePointer(
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.62),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: ValueListenableBuilder<int>(
                          valueListenable: _pageNotifier,
                          builder: (_, page, _) => ValueListenableBuilder<String>(
                            valueListenable: _clockNotifier,
                            builder: (_, clockStr, _) => Text(
                              '$_chapterLabel  ·  $page / $_totalPages  ·  $clockStr',
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 11,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              // Auto-Scroll floating control pill when active
              if (_autoScrolling)
                Positioned(
                  right: 16,
                  bottom:
                      (_chrome ? 148 : 34) +
                      MediaQuery.paddingOf(context).bottom,
                  child: Material(
                    color: AppColors.surfaceHigh.withValues(alpha: 0.92),
                    borderRadius: BorderRadius.circular(24),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(24),
                      onTap: () => _toggleAutoScroll(false),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.pause_rounded,
                              size: 16,
                              color: AppColors.primary,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              'Auto ${_autoScrollSpeed.toStringAsFixed(1)}x',
                              style: AppText.caption.copyWith(
                                color: AppColors.text,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              // Top Bar
              AnimatedPositioned(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOut,
                left: 0,
                right: 0,
                top: _chrome ? 0 : -(76 + MediaQuery.paddingOf(context).top),
                child: _topBar(context),
              ),
              // Bottom Bar
              AnimatedPositioned(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOut,
                left: 0,
                right: 0,
                bottom: _chrome
                    ? 0
                    : -(160 + MediaQuery.paddingOf(context).bottom),
                child: _bottom(context),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildReaderBody() =>
      _mode == ReaderMode.webtoon ? _buildWebtoonReader() : _buildPagedReader();

  Future<void> _openChapterInWebViewAndRetry(int chapterIndex) async {
    final chapter = _chapters[chapterIndex];
    String? webUrl;
    if (chapter.id.startsWith('ext:')) {
      final parts = chapter.id.split(':');
      if (parts.length >= 3) {
        final pkg = parts[1];
        final rawUrl = Uri.decodeComponent(parts.sublist(2).join(':'));
        if (rawUrl.startsWith('http')) {
          webUrl = rawUrl;
        } else {
          final baseUrl = await ExtensionBridge.instance.getSourceBaseUrl(
            pkg: pkg,
          );
          final ext = ExtensionService.instance.getExtensionByPkg(
            pkg.split('@').first,
          );
          final base = (baseUrl != null && baseUrl.isNotEmpty)
              ? baseUrl
              : (ext?.homeUrl ?? '');
          if (base.isNotEmpty) {
            webUrl = base.endsWith('/') && rawUrl.startsWith('/')
                ? '$base${rawUrl.substring(1)}'
                : '$base$rawUrl';
          }
        }
      }
    }
    if (webUrl != null && webUrl.isNotEmpty) {
      await ExtensionBridge.instance.openInWebView(
        url: webUrl,
        title: widget.mangaTitle.isNotEmpty
            ? widget.mangaTitle
            : chapter.displayTitle,
      );
      if (mounted) {
        _reloadChapterPages(chapterIndex);
      }
    }
  }

  /// Inline loading / error state for a chapter whose pages aren't available.
  Widget _buildChapterStatus(int chapterIndex, {bool fill = false}) {
    final chapter = _chapters[chapterIndex];
    final error = _chapterErrors[chapter.id];
    final isExtChapter = chapter.id.startsWith('ext:');

    final Widget content = AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      child: error != null
          ? Container(
              key: ValueKey('err:${chapter.id}'),
              padding: const EdgeInsets.all(24),
              constraints: const BoxConstraints(maxWidth: 360),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: AppColors.outline),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.error_outline_rounded,
                    size: 42,
                    color: AppColors.primary,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Could not load ${chapter.displayTitle}',
                    textAlign: TextAlign.center,
                    style: AppText.cardTitle,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    error,
                    textAlign: TextAlign.center,
                    style: AppText.caption.copyWith(height: 1.4),
                  ),
                  const SizedBox(height: 18),
                  FilledButton.icon(
                    onPressed: () => _reloadChapterPages(chapterIndex),
                    icon: const Icon(Icons.refresh_rounded, size: 18),
                    label: Text(
                      'Retry Chapter',
                      style: AppText.bodySemiBold.copyWith(
                        color: AppColors.onPrimary,
                      ),
                    ),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      foregroundColor: AppColors.onPrimary,
                      minimumSize: const Size(0, 44),
                    ),
                  ),
                  if (isExtChapter) ...[
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: () =>
                          _openChapterInWebViewAndRetry(chapterIndex),
                      icon: const Icon(Icons.shield_outlined, size: 16),
                      label: Text(
                        'Solve in WebView & Retry',
                        style: AppText.bodyMedium,
                      ),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.text,
                        side: BorderSide(color: AppColors.outline),
                        minimumSize: const Size(0, 44),
                      ),
                    ),
                  ],
                ],
              ),
            )
          : Column(
              key: ValueKey('load:${chapter.id}'),
              mainAxisSize: MainAxisSize.min,
              children: [
                ShimmerLoading(
                  child: Container(
                    width: 220,
                    height: 180,
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                    color: AppColors.primary,
                    strokeWidth: 2.2,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  'Loading ${chapter.displayTitle}...',
                  style: AppText.caption,
                ),
              ],
            ),
    );

    final body = Center(
      child: Padding(padding: const EdgeInsets.all(24), child: content),
    );
    return fill ? body : SizedBox(height: 320, child: body);
  }

  // ---- Continuous Webtoon Reader ----

  _PageSlot _slotFor(_FeedItem item) => _pageSlots.putIfAbsent(
    item.id,
    () => _PageSlot(item.chapterIndex!, item.pageIndex!),
  );

  Widget _buildWebtoonReader() {
    final feedItems = <_FeedItem>[];

    for (var k = 0; k < _webtoonLoadedIndices.length; k++) {
      final chIdx = _webtoonLoadedIndices[k];
      final chapter = _chapters[chIdx];
      final pages = _pagesCache[chapter.id];

      if (k > 0) {
        feedItems.add(
          _FeedItem.divider(
            prevChapter: _chapters[_webtoonLoadedIndices[k - 1]],
            nextChapter: chapter,
            chapterIndex: chIdx,
          ),
        );
      }

      if (pages == null) {
        // Loading or failed: shown inline (with Retry) so it can't be skipped.
        feedItems.add(_FeedItem.status(chIdx));
      } else {
        for (var p = 0; p < pages.length; p++) {
          feedItems.add(
            _FeedItem.page(chapterIndex: chIdx, pageIndex: p, url: pages[p]),
          );
        }
      }
    }

    final lastIdx = _webtoonLoadedIndices.last;
    if (_pagesCache.containsKey(_chapters[lastIdx].id)) {
      final nextFeedIdx = _findAdjacentChapterIndex(lastIdx, 1);
      if (nextFeedIdx != null) {
        feedItems.add(
          _FeedItem.nextChapterTrigger(_chapters[nextFeedIdx], nextFeedIdx),
        );
      } else {
        feedItems.add(_FeedItem.endOfManga());
      }
    }

    final keys = <Key>[
      for (final item in feedItems)
        item.type == _ItemType.page ? _slotFor(item).key : ValueKey(item.id),
    ];
    final indexByKey = <Key, int>{
      for (var i = 0; i < keys.length; i++) keys[i]: i,
    };

    final sidePadPx = MediaQuery.sizeOf(context).width * _webtoonSidePadding;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onDoubleTapDown: (details) => _webtoonDoubleTapDetails = details,
      onDoubleTap: _handleWebtoonDoubleTap,
      child: InteractiveViewer(
        transformationController: _webtoonTransformController,
        minScale: 1.0,
        maxScale: 3.5,
        panEnabled: _isWebtoonZoomed,
        child: NotificationListener<ScrollNotification>(
          onNotification: (notification) {
            if (_autoScrolling &&
                notification is UserScrollNotification &&
                notification.direction.name != 'idle') {
              _toggleAutoScroll(false);
            }
            return _onWebtoonScroll(notification);
          },
          child: ListView.builder(
            key: _listKey,
            controller: _scrollController,
            // Keep 3 viewports of decoded strips alive above & below so scrolling
            // back several pages never disposes widgets or triggers reload spinners.
            // ignore: deprecated_member_use
            cacheExtent: MediaQuery.sizeOf(context).height * 3.0,
            padding: EdgeInsets.only(
              left: sidePadPx,
              right: sidePadPx,
              top: MediaQuery.paddingOf(context).top + 50,
              bottom: MediaQuery.paddingOf(context).bottom + 90,
            ),
            itemCount: feedItems.length,
            findChildIndexCallback: (key) => indexByKey[key],
            itemBuilder: (context, i) =>
                KeyedSubtree(key: keys[i], child: _buildFeedItem(feedItems[i])),
          ),
        ),
      ),
    );
  }

  Widget _buildFeedItem(_FeedItem item) {
    switch (item.type) {
      case _ItemType.page:
        final chIdx = item.chapterIndex ?? _currentChapterIndex;
        final pageIdx = item.pageIndex ?? 0;
        final chapterId = _chapters[chIdx].id;
        final url = item.url!;
        final keepAlive =
            chIdx == _currentChapterIndex &&
            (pageIdx - (_page - 1)).abs() <= 10;
        return _KeepAlivePageWrapper(
          keepAlive: keepAlive,
          child: _ReaderPageImage(
            url: url,
            fallbackUrls: _fallbackUrlsFor(chapterId, pageIdx, url),
            pageNumber: pageIdx + 1,
            fit: BoxFit.fitWidth,
            expandWidth: true,
            // Never scale-crop seamless vertical webtoon strips
            cropBorders: false,
            onReloadChapter: () => _reloadChapterPages(chIdx),
            onOpenWebView: chapterId.startsWith('ext:')
                ? () => _openChapterInWebViewAndRetry(chIdx)
                : null,
            onLongPress: (reload) =>
                _showPageContextMenu(url, pageIdx + 1, reload),
          ),
        );

      case _ItemType.divider:
        return Container(
          margin: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.outline),
          ),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.check_circle_rounded,
                    color: AppColors.primary,
                    size: 16,
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      '${item.prevChapter?.displayTitle ?? "Previous Chapter"} finished',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.caption,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                '↓ Continuing to ${item.nextChapter?.displayTitle ?? "Next Chapter"}',
                textAlign: TextAlign.center,
                style: AppText.cardTitle,
              ),
            ],
          ),
        );

      case _ItemType.status:
        return _buildChapterStatus(item.chapterIndex!);

      case _ItemType.nextTrigger:
        return Container(
          padding: const EdgeInsets.symmetric(vertical: 36),
          child: Center(
            child: FilledButton.tonalIcon(
              onPressed: () => _extendWebtoonFeed(userTappedTrigger: true),
              icon: const Icon(Icons.arrow_downward_rounded, size: 18),
              label: Text(
                'Next: ${item.nextChapter?.displayTitle ?? "Next Chapter"}',
                style: AppText.bodySemiBold,
              ),
            ),
          ),
        );

      case _ItemType.endOfManga:
        return Container(
          padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 24),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.celebration_rounded,
                  color: AppColors.primary,
                  size: 36,
                ),
                const SizedBox(height: 12),
                Text(
                  "You've reached the latest chapter!",
                  style: AppText.cardTitle,
                ),
                const SizedBox(height: 4),
                Text(
                  'Check back later for new releases',
                  style: AppText.caption,
                ),
              ],
            ),
          ),
        );
    }
  }

  // ---- Continuous Paged Reader (RTL Japanese Manga & LTR Western) ----

  /// Called when the reader lands on the "next chapter" card. Waits a beat and
  /// only advances if the user is still on that card (they may swipe back).
  void _scheduleAutoAdvance(int fromIdx, int cardPage) {
    if (_advancing) return;
    final nextIdx = _findAdjacentChapterIndex(fromIdx, 1);
    if (nextIdx == null) return;
    _advancing = true;
    _autoAdvanceTimer?.cancel();
    _autoAdvanceTimer = Timer(const Duration(milliseconds: 1500), () {
      _advancing = false;
      if (!mounted ||
          _mode == ReaderMode.webtoon ||
          _currentChapterIndex != fromIdx)
        return;
      if (!_pageController.hasClients ||
          _pageController.page?.round() != cardPage)
        return;
      _switchToChapter(nextIdx);
    });
  }

  Widget _buildPagedReader() {
    final curChapter = _currentChapter;
    final pages = _pagesCache[curChapter.id];

    if (pages == null) {
      return _buildChapterStatus(_currentChapterIndex, fill: true);
    }

    final isRtl = _mode == ReaderMode.rightToLeft;
    final size = MediaQuery.sizeOf(context);
    final useDualSpread =
        _dualPageSpread && size.width >= 720 && size.width > size.height;

    // Total items in pageview: pages (or pairs in landscape dual-spread) + 1 transition card
    final nextChapterIdx = _findAdjacentChapterIndex(_currentChapterIndex, 1);
    final hasNext = nextChapterIdx != null;
    final spreadCount = useDualSpread
        ? (pages.length / 2).ceil()
        : pages.length;
    final pageCount = spreadCount + (hasNext ? 1 : 0);
    final chapterIdx = _currentChapterIndex;
    final isExtChapter = curChapter.id.startsWith('ext:');

    return PageView.builder(
      key: ValueKey(
        '${curChapter.id}:${_mode.name}:${useDualSpread ? 'dual' : 'single'}',
      ),
      controller: _pageController,
      reverse: isRtl,
      allowImplicitScrolling: true,
      itemCount: pageCount,
      physics: const PageScrollPhysics(),
      onPageChanged: (idx) {
        _isPageZoomed = false;
        if (idx < spreadCount) {
          final List<int> viewedNow;
          final int newP;
          if (useDualSpread) {
            final firstPage = (idx * 2) + 1;
            final secondPage = firstPage + 1;
            viewedNow = secondPage <= pages.length
                ? [firstPage, secondPage]
                : [firstPage];
            newP = math.min(secondPage, pages.length);
          } else {
            newP = idx + 1;
            viewedNow = [newP];
          }
          _recordPagesViewed(curChapter.id, viewedNow);
          if (_page != newP) {
            _sessionPagesTurned++;
            _page = newP;
            _pageNotifier.value = newP;
            if (_hasReadAllPages(curChapter.id)) {
              _onChapterFinished(chapterIdx);
            }
            _syncProgress(newP);
            _precacheSlidingWindow(
              pages,
              math.min(newP - 1, pages.length - 1),
              window: 6,
            );
            // Prefetch next chapter when nearing the end
            if (newP >= pages.length - 4 && nextChapterIdx != null) {
              _loadChapter(nextChapterIdx);
            }
          } else if (_hasReadAllPages(curChapter.id)) {
            _onChapterFinished(chapterIdx);
          }
        } else if (hasNext) {
          // Only mark chapter read if the user actually read every page!
          if (_hasReadAllPages(curChapter.id)) {
            _onChapterFinished(chapterIdx);
          }
          _scheduleAutoAdvance(chapterIdx, idx);
        }
      },
      itemBuilder: (_, i) {
        if (i < spreadCount) {
          final currentSpreadIdx = useDualSpread
              ? ((_page - 1) ~/ 2)
              : (_page - 1);
          final keepAlive = (i - currentSpreadIdx).abs() <= 8;
          if (useDualSpread) {
            final firstIdx = i * 2;
            final secondIdx = firstIdx + 1;
            final hasSecond = secondIdx < pages.length;
            Widget buildHalf(int pIdx) {
              final url = pages[pIdx];
              return Expanded(
                child: _ReaderPageImage(
                  url: url,
                  fallbackUrls: _fallbackUrlsFor(curChapter.id, pIdx, url),
                  pageNumber: pIdx + 1,
                  fit: BoxFit.contain,
                  expandWidth: false,
                  cropBorders: _cropBorders,
                  onReloadChapter: () => _reloadChapterPages(chapterIdx),
                  onOpenWebView: isExtChapter
                      ? () => _openChapterInWebViewAndRetry(chapterIdx)
                      : null,
                  onLongPress: (reload) =>
                      _showPageContextMenu(url, pIdx + 1, reload),
                ),
              );
            }

            final children = hasSecond
                ? (isRtl
                      ? [buildHalf(secondIdx), buildHalf(firstIdx)]
                      : [buildHalf(firstIdx), buildHalf(secondIdx)])
                : [buildHalf(firstIdx)];
            return _KeepAlivePageWrapper(
              keepAlive: keepAlive,
              child: Center(
                child: ZoomablePageWrapper(
                  onZoomChanged: (z) => _isPageZoomed = z,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: children,
                  ),
                ),
              ),
            );
          }

          final pageUrl = pages[i];
          return _KeepAlivePageWrapper(
            keepAlive: keepAlive,
            child: Center(
              child: ZoomablePageWrapper(
                onZoomChanged: (z) => _isPageZoomed = z,
                child: _ReaderPageImage(
                  url: pageUrl,
                  fallbackUrls: _fallbackUrlsFor(curChapter.id, i, pageUrl),
                  pageNumber: i + 1,
                  fit: _fitMode,
                  expandWidth: false,
                  cropBorders: _cropBorders,
                  splitWidePages: _splitWidePages,
                  isRtl: isRtl,
                  onReloadChapter: () => _reloadChapterPages(chapterIdx),
                  onOpenWebView: isExtChapter
                      ? () => _openChapterInWebViewAndRetry(chapterIdx)
                      : null,
                  onLongPress: (reload) =>
                      _showPageContextMenu(pageUrl, i + 1, reload),
                ),
              ),
            ),
          );
        }

        // Seamless Next Chapter Transition Card
        final nextCh = _chapters[nextChapterIdx!];
        return Center(
          child: Container(
            padding: const EdgeInsets.all(32),
            margin: const EdgeInsets.symmetric(horizontal: 24),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: AppColors.outline),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.check_circle_rounded,
                  color: AppColors.primary,
                  size: 48,
                ),
                const SizedBox(height: 16),
                Text(
                  '${curChapter.displayTitle} Finished',
                  textAlign: TextAlign.center,
                  style: AppText.sheetTitle,
                ),
                const SizedBox(height: 8),
                Text(
                  'Up next: ${nextCh.displayTitle}',
                  textAlign: TextAlign.center,
                  style: AppText.body.copyWith(color: AppColors.muted),
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: () => _switchToChapter(nextChapterIdx),
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: Text(
                    'Read Next Chapter',
                    style: AppText.bodySemiBold.copyWith(
                      color: AppColors.onPrimary,
                    ),
                  ),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: AppColors.onPrimary,
                    minimumSize: const Size(0, 44),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _topBar(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;
    final curChapter = _currentChapter;
    final isBookmarked = ApiService.instance.isChapterBookmarked(curChapter.id);

    return Container(
      constraints: BoxConstraints(minHeight: 74 + top),
      padding: EdgeInsets.fromLTRB(6, top + 4, 6, 4),
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: .94),
        border: Border(bottom: BorderSide(color: AppColors.outline)),
      ),
      child: Row(
        children: [
          BarIcon(
            Icons.arrow_back_rounded,
            label: 'Back',
            onTap: () => Navigator.of(context).maybePop(),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _effectiveMangaTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.bodyMedium,
                ),
                const SizedBox(height: 3),
                ValueListenableBuilder<int>(
                  valueListenable: _pageNotifier,
                  builder: (_, page, _) => Text(
                    '$_chapterLabel · Page $page/$_totalPages',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.caption,
                  ),
                ),
              ],
            ),
          ),
          // In-reader Chapter List Drawer Button
          if (_chapters.length > 1)
            IconButton(
              constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
              icon: Icon(
                Icons.format_list_bulleted_rounded,
                color: AppColors.text,
                size: 22,
              ),
              tooltip: 'Chapters',
              onPressed: _showChaptersDrawer,
            ),
          // Bookmark Chapter Icon Button
          IconButton(
            constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
            icon: Icon(
              isBookmarked
                  ? Icons.bookmark_rounded
                  : Icons.bookmark_border_rounded,
              color: isBookmarked ? AppColors.primary : AppColors.text,
              size: 22,
            ),
            tooltip: isBookmarked ? 'Bookmarked' : 'Bookmark Chapter',
            onPressed: () async {
              final state = await ApiService.instance.toggleChapterBookmark(
                curChapter.id,
              );
              if (mounted) setState(() {});
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      state
                          ? 'Bookmarked ${curChapter.displayTitle}'
                          : 'Removed bookmark for ${curChapter.displayTitle}',
                    ),
                    duration: const Duration(seconds: 1),
                  ),
                );
              }
            },
          ),
          BarIcon(
            Icons.tune_rounded,
            label: 'Display & Filter',
            onTap: _showDisplaySheet,
          ),
          BarIcon(
            _selectedMode == ReaderMode.automatic
                ? Icons.auto_awesome_rounded
                : _mode.icon,
            label: _selectedMode == ReaderMode.automatic
                ? 'Auto (${_mode.shortLabel})'
                : _selectedMode.label,
            onTap: _showModeSheet,
          ),
        ],
      ),
    );
  }

  Widget _bottom(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom;
    final isRtl = _mode == ReaderMode.rightToLeft;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Page Scrubber Slider (mirrored naturally for RTL Japanese manga)
        Container(
          constraints: const BoxConstraints(minHeight: 54),
          margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          padding: const EdgeInsets.symmetric(horizontal: 7),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(27),
            border: Border.all(color: AppColors.outline),
          ),
          child: Row(
            children: [
              _ScrubButton(
                '‹',
                tooltip: isRtl ? 'Next page' : 'Previous page',
                onTap: () => _go(isRtl ? _page + 1 : _page - 1),
              ),
              Expanded(
                child: Directionality(
                  textDirection: isRtl ? TextDirection.rtl : TextDirection.ltr,
                  child: ValueListenableBuilder<int>(
                    valueListenable: _pageNotifier,
                    builder: (context, page, _) => SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 3,
                        activeTrackColor: AppColors.primary,
                        inactiveTrackColor: AppColors.outline,
                        thumbColor: AppColors.primary,
                        overlayColor: AppColors.primary.withValues(alpha: .12),
                      ),
                      child: Slider(
                        min: 1,
                        max: math.max(1, _totalPages).toDouble(),
                        value: page
                            .clamp(1, math.max(1, _totalPages))
                            .toDouble(),
                        onChanged: (v) => _go(v.round()),
                      ),
                    ),
                  ),
                ),
              ),
              Tooltip(
                message: 'Jump to page',
                child: InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: _totalPages > 1 ? _showJumpToPageDialog : null,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      minWidth: 52,
                      minHeight: 34,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 6,
                      ),
                      child: Center(
                        child: ValueListenableBuilder<int>(
                          valueListenable: _pageNotifier,
                          builder: (_, page, _) => Text(
                            '$page / $_totalPages',
                            textAlign: TextAlign.center,
                            style: AppText.caption.copyWith(
                              color: AppColors.text,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              _ScrubButton(
                '›',
                tooltip: isRtl ? 'Previous page' : 'Next page',
                onTap: () => _go(isRtl ? _page - 1 : _page + 1),
              ),
            ],
          ),
        ),
        // Clean Bottom Controls with Next/Prev Chapter & Fit
        Container(
          constraints: BoxConstraints(minHeight: 64 + bottom),
          padding: EdgeInsets.only(top: 6, bottom: bottom + 4),
          decoration: BoxDecoration(
            color: AppColors.surface.withValues(alpha: .95),
            border: Border(top: BorderSide(color: AppColors.outline)),
          ),
          child: Row(
            children: [
              // Previous Chapter
              Expanded(
                child: InkWell(
                  onTap: _hasPrevChapter
                      ? () {
                          final prevIdx = _findAdjacentChapterIndex(
                            _currentChapterIndex,
                            -1,
                          );
                          if (prevIdx != null) _switchToChapter(prevIdx);
                        }
                      : null,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 48),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.skip_previous_rounded,
                          size: 20,
                          color: _hasPrevChapter
                              ? AppColors.text
                              : AppColors.muted.withValues(alpha: .3),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Prev Ch.',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.caption.copyWith(
                            color: _hasPrevChapter
                                ? AppColors.muted
                                : AppColors.muted.withValues(alpha: .3),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              // Direction toggle (Webtoon / RTL Manga / LTR)
              Expanded(
                child: InkWell(
                  onTap: _showModeSheet,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 48),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          _selectedMode == ReaderMode.automatic
                              ? Icons.auto_awesome_rounded
                              : _mode.icon,
                          size: 20,
                          color: AppColors.primary,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _selectedMode == ReaderMode.automatic
                              ? 'Auto (${_mode.shortLabel})'
                              : _selectedMode.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.caption.copyWith(
                            color: AppColors.primary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              // Fit mode toggle (Fit Width vs Fit Screen)
              Expanded(
                child: InkWell(
                  onTap: () {
                    setState(() {
                      _fitMode = _fitMode == BoxFit.contain
                          ? BoxFit.fitWidth
                          : BoxFit.contain;
                    });
                    ReaderSettings.instance.setFitMode(_fitMode);
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          _fitMode == BoxFit.contain
                              ? 'Mode: Fit Page'
                              : 'Mode: Fit Width',
                        ),
                        duration: const Duration(milliseconds: 800),
                      ),
                    );
                  },
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 48),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          _fitMode == BoxFit.contain
                              ? Icons.fit_screen_rounded
                              : Icons.photo_size_select_actual_outlined,
                          size: 20,
                          color: AppColors.text,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _fitMode == BoxFit.contain ? 'Fit Page' : 'Fit Width',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.caption,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              // Next Chapter
              Expanded(
                child: InkWell(
                  onTap: _hasNextChapter
                      ? () {
                          final nextIdx = _findAdjacentChapterIndex(
                            _currentChapterIndex,
                            1,
                          );
                          if (nextIdx != null) _switchToChapter(nextIdx);
                        }
                      : null,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 48),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.skip_next_rounded,
                          size: 20,
                          color: _hasNextChapter
                              ? AppColors.primary
                              : AppColors.muted.withValues(alpha: .3),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Next Ch.',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.caption.copyWith(
                            color: _hasNextChapter
                                ? AppColors.primary
                                : AppColors.muted.withValues(alpha: .3),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ScrubButton extends StatelessWidget {
  const _ScrubButton(this.glyph, {required this.onTap, required this.tooltip});
  final String glyph;
  final VoidCallback onTap;
  final String tooltip;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: tooltip,
    child: Tooltip(
      message: tooltip,
      child: SizedBox(
        width: 44,
        height: 44,
        child: InkResponse(
          onTap: onTap,
          radius: 22,
          child: Center(
            child: Text(
              glyph,
              style: TextStyle(
                fontSize: 28,
                color: AppColors.primary,
                height: 1,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

// Supporting models for continuous webtoon feed
enum _ItemType { page, divider, status, nextTrigger, endOfManga }

/// Tracks a mounted page widget so the reader can measure which page is under
/// the reading line.
class _PageSlot {
  _PageSlot(this.chapterIndex, this.pageIndex);
  final int chapterIndex;
  final int pageIndex;
  final GlobalKey key = GlobalKey();
}

class _FeedItem {
  final _ItemType type;
  final int? chapterIndex;
  final int? pageIndex;
  final String? url;
  final ChapterItem? prevChapter;
  final ChapterItem? nextChapter;

  const _FeedItem._({
    required this.type,
    this.chapterIndex,
    this.pageIndex,
    this.url,
    this.prevChapter,
    this.nextChapter,
  });

  /// Stable identity, used for widget keys.
  String get id => switch (type) {
    _ItemType.page => 'p:$chapterIndex:$pageIndex',
    _ItemType.divider => 'd:$chapterIndex',
    _ItemType.status => 's:$chapterIndex',
    _ItemType.nextTrigger => 'n:$chapterIndex',
    _ItemType.endOfManga => 'end',
  };

  factory _FeedItem.page({
    required int chapterIndex,
    required int pageIndex,
    required String url,
  }) => _FeedItem._(
    type: _ItemType.page,
    chapterIndex: chapterIndex,
    pageIndex: pageIndex,
    url: url,
  );

  factory _FeedItem.divider({
    required ChapterItem prevChapter,
    required ChapterItem nextChapter,
    required int chapterIndex,
  }) => _FeedItem._(
    type: _ItemType.divider,
    prevChapter: prevChapter,
    nextChapter: nextChapter,
    chapterIndex: chapterIndex,
  );

  factory _FeedItem.status(int chapterIndex) =>
      _FeedItem._(type: _ItemType.status, chapterIndex: chapterIndex);

  factory _FeedItem.nextChapterTrigger(ChapterItem chapter, int chapterIndex) =>
      _FeedItem._(
        type: _ItemType.nextTrigger,
        nextChapter: chapter,
        chapterIndex: chapterIndex,
      );

  factory _FeedItem.endOfManga() =>
      const _FeedItem._(type: _ItemType.endOfManga);
}

class ZoomablePageWrapper extends StatefulWidget {
  const ZoomablePageWrapper({
    super.key,
    required this.child,
    this.onZoomChanged,
  });

  final Widget child;
  final ValueChanged<bool>? onZoomChanged;

  @override
  State<ZoomablePageWrapper> createState() => _ZoomablePageWrapperState();
}

class _ZoomablePageWrapperState extends State<ZoomablePageWrapper>
    with SingleTickerProviderStateMixin {
  final TransformationController _controller = TransformationController();
  late final AnimationController _animController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
  );
  Animation<Matrix4>? _zoomAnimation;
  TapDownDetails? _doubleTapDetails;
  bool _isZoomed = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onTransformChanged);
    _animController.addListener(() {
      final anim = _zoomAnimation;
      if (anim != null) {
        _controller.value = anim.value;
      }
    });
  }

  void _onTransformChanged() {
    final zoomed = _controller.value.getMaxScaleOnAxis() > 1.05;
    if (zoomed != _isZoomed) {
      setState(() => _isZoomed = zoomed);
      widget.onZoomChanged?.call(zoomed);
    }
  }

  void _handleDoubleTap() {
    final currentScale = _controller.value.getMaxScaleOnAxis();
    final Matrix4 target;
    if (currentScale > 1.08) {
      target = Matrix4.identity();
    } else {
      const targetScale = 2.5;
      final position = _doubleTapDetails?.localPosition ?? Offset.zero;
      final box = context.findRenderObject() as RenderBox?;
      var tx = -position.dx * (targetScale - 1.0);
      var ty = -position.dy * (targetScale - 1.0);
      if (box != null && box.hasSize) {
        final minTx = -(box.size.width * (targetScale - 1.0));
        final minTy = -(box.size.height * (targetScale - 1.0));
        tx = tx.clamp(minTx, 0.0);
        ty = ty.clamp(minTy, 0.0);
      }
      target = Matrix4.identity()
        ..translateByDouble(tx, ty, 0.0, 1.0)
        ..scaleByDouble(targetScale, targetScale, 1.0, 1.0);
    }

    _zoomAnimation = Matrix4Tween(begin: _controller.value, end: target)
        .animate(
          CurvedAnimation(parent: _animController, curve: Curves.easeOutCubic),
        );
    _animController
      ..reset()
      ..forward();
  }

  @override
  void dispose() {
    _animController.dispose();
    _controller.removeListener(_onTransformChanged);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onDoubleTapDown: (details) => _doubleTapDetails = details,
      onDoubleTap: _handleDoubleTap,
      child: InteractiveViewer(
        transformationController: _controller,
        minScale: 1.0,
        maxScale: 4.0,
        panEnabled: _isZoomed,
        clipBehavior: Clip.none,
        child: widget.child,
      ),
    );
  }
}

/// Keeps nearby reader pages alive across scroll/swipe recycling so going back
/// several pages is 0ms instant with zero placeholder flash or re-decoding.
class _KeepAlivePageWrapper extends StatefulWidget {
  const _KeepAlivePageWrapper({required this.keepAlive, required this.child});

  final bool keepAlive;
  final Widget child;

  @override
  State<_KeepAlivePageWrapper> createState() => _KeepAlivePageWrapperState();
}

class _KeepAlivePageWrapperState extends State<_KeepAlivePageWrapper>
    with AutomaticKeepAliveClientMixin<_KeepAlivePageWrapper> {
  @override
  bool get wantKeepAlive => widget.keepAlive;

  @override
  void didUpdateWidget(covariant _KeepAlivePageWrapper oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.keepAlive != widget.keepAlive) {
      updateKeepAlive();
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

class _ReaderPageImage extends StatefulWidget {
  const _ReaderPageImage({
    required this.url,
    required this.fallbackUrls,
    required this.pageNumber,
    required this.fit,
    required this.expandWidth,
    this.cropBorders = false,
    this.splitWidePages = false,
    this.isRtl = false,
    this.onReloadChapter,
    this.onOpenWebView,
    this.onLongPress,
  });

  final String url;
  final List<String> fallbackUrls;
  final int pageNumber;
  final BoxFit fit;
  final bool expandWidth;
  final bool cropBorders;
  final bool splitWidePages;
  final bool isRtl;
  final VoidCallback? onReloadChapter;
  final VoidCallback? onOpenWebView;
  final void Function(VoidCallback reloadPage)? onLongPress;

  @override
  State<_ReaderPageImage> createState() => _ReaderPageImageState();
}

class _ReaderPageImageState extends State<_ReaderPageImage> {
  int _localReloadGen = 0;
  bool _isWideSpread = false;
  ImageStream? _probeStream;
  ImageStreamListener? _probeListener;

  @override
  void initState() {
    super.initState();
    _maybeProbeWideImage();
  }

  @override
  void didUpdateWidget(covariant _ReaderPageImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url ||
        oldWidget.splitWidePages != widget.splitWidePages) {
      _detachProbe();
      _isWideSpread = false;
      _maybeProbeWideImage();
    }
  }

  @override
  void dispose() {
    _detachProbe();
    super.dispose();
  }

  void _detachProbe() {
    if (_probeStream != null && _probeListener != null) {
      _probeStream!.removeListener(_probeListener!);
    }
    _probeStream = null;
    _probeListener = null;
  }

  void _maybeProbeWideImage() {
    if (!widget.splitWidePages) return;
    final url = widget.url.trim();
    ImageProvider? provider;
    if (url.startsWith('file://')) {
      provider = FileImage(File(url.replaceFirst('file://', '')));
    } else if (url.startsWith('http') || url.startsWith('//')) {
      final norm = url.startsWith('//') ? 'https:$url' : url;
      provider = CachedNetworkImageProvider(norm);
    }
    if (provider == null) return;
    final stream = provider.resolve(ImageConfiguration.empty);
    final listener = ImageStreamListener((info, _) {
      final wide = info.image.width > info.image.height * 1.15;
      if (mounted && wide != _isWideSpread) {
        setState(() => _isWideSpread = wide);
      }
      _detachProbe();
    }, onError: (_, _) => _detachProbe());
    _probeStream = stream;
    _probeListener = listener;
    stream.addListener(listener);
  }

  Widget _wrapPostProcess(Widget child, VoidCallback reloadPage) {
    Widget out = child;
    if (widget.cropBorders) {
      // Gentle paged-mode margin crop (less aggressive so text near edges stays safe)
      out = ClipRect(
        child: Transform.scale(scaleX: 1.05, scaleY: 1.02, child: out),
      );
    }
    if (widget.splitWidePages && _isWideSpread) {
      final size = MediaQuery.sizeOf(context);
      if (size.height > size.width) {
        out = SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          reverse: widget.isRtl,
          child: SizedBox(height: size.height, child: out),
        );
      }
    }
    if (widget.onLongPress != null) {
      out = GestureDetector(
        behavior: HitTestBehavior.translucent,
        onLongPress: () => widget.onLongPress!(reloadPage),
        child: out,
      );
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final url = widget.url.trim();
    // Impeller GPU VRAM safety: decode to viewport pixel width (capped 720..1600px)
    // without clamping vertical height so tall webtoon strips stay sharp and never OOM.
    final mq = MediaQuery.of(context);
    final decodeWidth = (mq.size.width * mq.devicePixelRatio * 1.35)
        .round()
        .clamp(720, 1600);

    if (url.startsWith('file://')) {
      final file = File(url.replaceFirst('file://', ''));
      void reloadLocal() {
        FileImage(file).evict();
        setState(() => _localReloadGen++);
      }

      return _wrapPostProcess(
        Image.file(
          file,
          key: ValueKey('file:$url#$_localReloadGen'),
          fit: widget.fit,
          width: widget.expandWidth ? double.infinity : null,
          cacheWidth: decodeWidth,
          gaplessPlayback: true,
          errorBuilder: (_, _, _) => _PageErrorCard(
            pageNumber: widget.pageNumber,
            fill: !widget.expandWidth,
            onRetryPage: reloadLocal,
            onReloadChapter: widget.onReloadChapter,
            onOpenWebView: widget.onOpenWebView,
          ),
        ),
        reloadLocal,
      );
    }

    final normalizedUrl = url.startsWith('//') ? 'https:$url' : url;
    if (!normalizedUrl.startsWith('http')) {
      return _PageErrorCard(
        pageNumber: widget.pageNumber,
        fill: !widget.expandWidth,
        onRetryPage: () => setState(() => _localReloadGen++),
        onReloadChapter: widget.onReloadChapter,
        onOpenWebView: widget.onOpenWebView,
      );
    }

    void forceRetryThisPage() {
      evictCachedImageUrl(normalizedUrl);
      for (final fb in widget.fallbackUrls) {
        if (fb.startsWith('http')) {
          evictCachedImageUrl(fb);
        }
      }
      if (mounted) {
        setState(() => _localReloadGen++);
      }
    }

    return _wrapPostProcess(
      RetryingNetworkImage(
        key: ValueKey('net:$normalizedUrl#$_localReloadGen'),
        url: normalizedUrl,
        fallbackUrls: widget.fallbackUrls,
        fit: widget.fit,
        width: widget.expandWidth ? double.infinity : null,
        memCacheWidth: decodeWidth,
        fadeInDuration: const Duration(milliseconds: 60),
        progressBuilder: (_, progress) => _PageLoadingSkeleton(
          pageNumber: widget.pageNumber,
          progress: progress,
          fill: !widget.expandWidth,
          onForceRetry: forceRetryThisPage,
          onReloadChapter: widget.onReloadChapter,
        ),
        errorBuilder: (_, retry) => _PageErrorCard(
          pageNumber: widget.pageNumber,
          fill: !widget.expandWidth,
          onRetryPage: () {
            evictCachedImageUrl(normalizedUrl);
            retry();
          },
          onReloadChapter: widget.onReloadChapter,
          onOpenWebView: widget.onOpenWebView,
        ),
      ),
      forceRetryThisPage,
    );
  }
}

class _PageLoadingSkeleton extends StatefulWidget {
  const _PageLoadingSkeleton({
    required this.pageNumber,
    required this.progress,
    required this.fill,
    this.onForceRetry,
    this.onReloadChapter,
  });

  final int pageNumber;
  final double? progress;
  final bool fill;
  final VoidCallback? onForceRetry;
  final VoidCallback? onReloadChapter;

  @override
  State<_PageLoadingSkeleton> createState() => _PageLoadingSkeletonState();
}

class _PageLoadingSkeletonState extends State<_PageLoadingSkeleton> {
  bool _showSlowRetry = false;
  Timer? _slowTimer;

  @override
  void initState() {
    super.initState();
    if (widget.onForceRetry != null) {
      _slowTimer = Timer(const Duration(seconds: 4), () {
        if (mounted) {
          setState(() => _showSlowRetry = true);
        }
      });
    }
  }

  @override
  void dispose() {
    _slowTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final progress = widget.progress;
    final pageNumber = widget.pageNumber;
    final pct = (progress != null && progress > 0)
        ? (progress * 100).round().clamp(1, 99)
        : null;
    final box = Stack(
      alignment: Alignment.center,
      children: [
        Positioned.fill(
          child: ShimmerLoading(
            child: Container(color: AppColors.surface.withValues(alpha: 0.7)),
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          decoration: BoxDecoration(
            color: AppColors.black.withValues(alpha: 0.72),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.outline),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(
                  value: (progress != null && progress > 0 && progress < 1)
                      ? progress
                      : null,
                  color: AppColors.primary,
                  backgroundColor: AppColors.surfaceHigh,
                  strokeWidth: 2.4,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                pct != null ? 'Page $pageNumber · $pct%' : 'Page $pageNumber',
                style: AppText.caption,
              ),
              if (_showSlowRetry && widget.onForceRetry != null) ...[
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: widget.onForceRetry,
                  icon: const Icon(Icons.refresh_rounded, size: 14),
                  label: Text('Retry Page $pageNumber'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.primary,
                    side: BorderSide(
                      color: AppColors.primary.withValues(alpha: 0.55),
                    ),
                    minimumSize: const Size(0, 44),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    textStyle: AppText.chip,
                  ),
                ),
                if (widget.onReloadChapter != null)
                  TextButton(
                    onPressed: widget.onReloadChapter,
                    style: TextButton.styleFrom(
                      foregroundColor: AppColors.muted,
                      minimumSize: const Size(0, 44),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      textStyle: AppText.caption,
                    ),
                    child: const Text('Reload Chapter URLs'),
                  ),
              ],
            ],
          ),
        ),
      ],
    );

    if (widget.fill) {
      return SizedBox(
        width: double.infinity,
        height: MediaQuery.sizeOf(context).height * 0.75,
        child: box,
      );
    }
    return Container(
      height: 440,
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 1),
      child: box,
    );
  }
}

class _PageErrorCard extends StatelessWidget {
  const _PageErrorCard({
    required this.pageNumber,
    required this.onRetryPage,
    required this.fill,
    this.onReloadChapter,
    this.onOpenWebView,
  });

  final int pageNumber;
  final VoidCallback onRetryPage;
  final VoidCallback? onReloadChapter;
  final VoidCallback? onOpenWebView;
  final bool fill;

  @override
  Widget build(BuildContext context) {
    final card = Center(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
        constraints: const BoxConstraints(maxWidth: 340),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: AppColors.outline),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: AppColors.surfaceHigh,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                Icons.broken_image_outlined,
                color: AppColors.primary,
                size: 22,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Page $pageNumber failed to load',
              textAlign: TextAlign.center,
              style: AppText.cardTitle,
            ),
            const SizedBox(height: 4),
            Text(
              'The image server timed out or dropped the connection.',
              textAlign: TextAlign.center,
              style: AppText.caption.copyWith(height: 1.4),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onRetryPage,
              icon: const Icon(Icons.refresh_rounded, size: 17),
              label: Text(
                'Retry Page $pageNumber',
                style: AppText.bodySemiBold.copyWith(
                  color: AppColors.onPrimary,
                ),
              ),
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: AppColors.onPrimary,
                minimumSize: const Size(0, 44),
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 10,
                ),
              ),
            ),
            if (onOpenWebView != null) ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: onOpenWebView,
                icon: const Icon(Icons.shield_outlined, size: 16),
                label: Text('Open in WebView', style: AppText.bodyMedium),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.text,
                  side: BorderSide(color: AppColors.outline),
                  minimumSize: const Size(0, 44),
                ),
              ),
            ],
            if (onReloadChapter != null) ...[
              const SizedBox(height: 6),
              TextButton.icon(
                onPressed: onReloadChapter,
                icon: const Icon(Icons.sync_rounded, size: 15),
                label: const Text('Reload Chapter URLs'),
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.muted,
                  minimumSize: const Size(0, 44),
                  textStyle: AppText.caption,
                ),
              ),
            ],
          ],
        ),
      ),
    );

    if (fill) return card;
    return SizedBox(width: double.infinity, height: 280, child: card);
  }
}
