import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:manga_reader/services/api_service.dart';
import 'package:manga_reader/services/extension_bridge.dart';
import 'package:manga_reader/services/extension_service.dart';
import 'package:manga_reader/widgets/common.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Valid 1x1 transparent PNG bytes for deterministic image rendering in tests.
final Uint8List _validPngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

class _FakeApkHttpClient extends http.BaseClient {
  int apkDownloads = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    apkDownloads++;
    // Return fake >1024-byte APK payload
    final payload = Uint8List.fromList(List<int>.filled(2048, 0x50));
    return http.StreamedResponse(
      Stream<List<int>>.value(payload),
      200,
      contentLength: payload.length,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  GoogleFonts.config.allowRuntimeFetching = false;

  const extensionsChannel = MethodChannel('com.example.manga_reader/extensions');
  const installerChannel = MethodChannel('com.example.manga_reader/installer');

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    ImageReferers.resetForTesting();
    ExtensionBridge.instance.clearCachesForTesting();
    ExtensionBridge.instance.forceAndroidForTesting = null;
    ExtensionService.instance.httpClientFactory = null;
    await ApiService.instance.init();
    // Re-attach ApiService cover resolver after resetForTesting()
    ImageReferers.coverLookup = (id) async => (await ApiService.instance.getManga(id)).cover;
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(extensionsChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(installerChannel, null);
    ExtensionBridge.instance.forceAndroidForTesting = null;
    ExtensionService.instance.httpClientFactory = null;
  });

  test('Keiyoushi index parsing preserves ALL multi-lang extensions, EN homeUrl, and subSources', () {
    final sampleRepoJson = jsonEncode([
      {
        'name': 'Tachiyomi: Comick',
        'pkg': 'eu.kanade.tachiyomi.extension.all.comick',
        'apk': 'tachiyomi-all.comick-v1.4.49.apk',
        'lang': 'all',
        'code': 49,
        'version': '1.4.49',
        'nsfw': 1,
        'sources': [
          {'name': 'Comick', 'lang': 'ar', 'id': '1001', 'baseUrl': 'https://ar.comick.io'},
          {'name': 'Comick', 'lang': 'en', 'id': '1002', 'baseUrl': 'https://comick.io'},
          {'name': 'Comick', 'lang': 'ja', 'id': '1003', 'baseUrl': 'https://ja.comick.io'},
        ],
      },
      {
        'name': 'Tachiyomi: MangaBox',
        'pkg': 'eu.kanade.tachiyomi.extension.en.mangabox',
        'apk': 'tachiyomi-en.mangabox-v1.4.12.apk',
        'lang': 'en',
        'code': 12,
        'version': '1.4.12',
        'nsfw': 0,
        'sources': [
          {'name': 'Manganato', 'lang': 'en', 'id': '2001', 'baseUrl': 'https://chapmanganato.to'},
          {'name': 'Mangakakalot', 'lang': 'en', 'id': '2002', 'baseUrl': 'https://mangakakalot.com'},
        ],
      },
    ]);

    final parsed = ExtensionService.parseJsonIndexForTesting(sampleRepoJson);
    expect(parsed.length, 2);

    final comick = parsed[0];
    expect(comick.name, 'Comick'); // stripped 'Tachiyomi: '
    expect(comick.lang, 'ALL'); // NOT mislabeled as 'AR'!
    expect(comick.supportsLang('EN'), isTrue);
    expect(comick.supportsLang('JA'), isTrue);
    expect(comick.homeUrl, 'https://comick.io'); // preferred EN baseUrl
    expect(comick.subSources.length, 3);

    final mangabox = parsed[1];
    expect(mangabox.name, 'MangaBox');
    expect(mangabox.lang, 'EN');
    expect(mangabox.supportsLang('EN'), isTrue);
    expect(mangabox.subSources.length, 2);
    expect(mangabox.subSources.first['name'], 'Manganato');
  });

  test('Uninstalled Tachiyomi extension auto-downloads APK on-demand, preserves /comic/ & @selector, and resolves covers + pages', () async {
    const testPkg = 'eu.kanade.tachiyomi.extension.all.testsource';
    const subSelectorPkg = '$testPkg@EN';

    // Clean any leftover temp APK before test
    final tempDir = Directory('${Directory.systemTemp.path}/shiori_extensions');
    if (tempDir.existsSync()) {
      for (final f in tempDir.listSync().whereType<File>()) {
        if (f.path.contains('testsource')) f.deleteSync();
      }
    }

    // Seed extension metadata into ExtensionService via SharedPreferences cache (NOT installed!)
    final uninstalledExt = MangaExtension(
      id: testPkg,
      name: 'TestSource',
      pkg: testPkg,
      version: '1.4.10',
      versionCode: 10,
      apkUrl: 'https://example.org/repo/apk/testsource.apk',
      iconUrl: 'https://example.org/repo/icon/testsource.png',
      lang: 'ALL',
      isNsfw: false,
      sourceNames: const ['TestSource'],
      supportedLangs: const ['ALL', 'EN'],
      subSources: const [
        {'id': '99', 'name': 'TestSource EN', 'lang': 'EN', 'baseUrl': 'https://testsource.example'},
      ],
      homeUrl: 'https://testsource.example',
      isInstalled: false,
    );
    SharedPreferences.setMockInitialValues({
      'shiori_extensions_cache_v2': jsonEncode([uninstalledExt.toJson()]),
    });

    final fakeHttp = _FakeApkHttpClient();
    ExtensionService.instance.httpClientFactory = () => fakeHttp;
    ExtensionBridge.instance.forceAndroidForTesting = true;

    // Reload ExtensionService cache by installing & immediately uninstalling metadata or populating cache:
    await ExtensionService.instance.installExtension(uninstalledExt);
    await ExtensionService.instance.uninstallExtension(uninstalledExt);
    // Re-seed extensions list via repo cache simulation:
    SharedPreferences.setMockInitialValues({
      'shiori_extensions_cache_v2': jsonEncode([uninstalledExt.toJson()]),
    });
    // Ensure lookup finds it even when uninstalled:
    ExtensionService.instance.extensions
      ..clear()
      ..add(uninstalledExt);
    expect(uninstalledExt.isInstalled, isFalse);

    final recordedMethods = <String>[];
    final recordedArgs = <Map<dynamic, dynamic>>[];

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(installerChannel, (call) async {
      if (call.method == 'persistExtensionApk') {
        final args = call.arguments as Map;
        return args['sourcePath'] as String?;
      }
      return null;
    });

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(extensionsChannel, (call) async {
      recordedMethods.add(call.method);
      final args = (call.arguments as Map?) ?? {};
      recordedArgs.add(args);

      switch (call.method) {
        case 'getSourceHeaders':
          return {
            'baseUrl': 'https://testsource.example',
            'nativeImages': true,
            'headers': {
              'User-Agent': 'TachiyomiCustomUA/1.5',
              'Referer': 'https://testsource.example/',
              'Cookie': 'cf_clearance=verified_token',
            },
          };
        case 'fetchLatestUpdates':
          return [
            {
              'title': 'Solo Leveling',
              'url': '/comic/solo-leveling',
              'thumbnail_url': '/uploads/covers/solo.jpg',
              'referer': 'https://testsource.example',
            },
          ];
        case 'fetchMangaDetails':
          return {
            'title': 'Solo Leveling',
            'url': args['url'], // verify /comic/ was NOT stripped!
            'thumbnail_url': 'https://cdn.testsource.example/covers/solo_hd.jpg',
            'description': 'A hunter rises.',
            'author': 'Chugong',
            'genre': 'Action, Manhwa',
            'status': 2,
            'referer': 'https://testsource.example',
          };
        case 'fetchChapterList':
          return [
            {
              'url': '/comic/solo-leveling/chapter-1',
              'name': 'Chapter 1',
              'chapter_number': 1.0,
              'date_upload': 1700000000000,
              'scanlator': 'Official',
            },
          ];
        case 'fetchPageList':
          return [
            '/images/ch1/001.jpg',
            'https://cdn.testsource.example/images/ch1/002.jpg',
          ];
        case 'fetchImageBytes':
          return _validPngBytes;
      }
      return null;
    });

    // 1. Browse Latest on uninstalled sub-source -> must auto-download APK & call fetchLatestUpdates with @EN preserved!
    final latest = await ApiService.instance.searchManga(
      source: subSelectorPkg,
      order: 'latest',
    );
    expect(fakeHttp.apkDownloads, 1, reason: 'Uninstalled extension APK must auto-download on demand');
    expect(recordedMethods, contains('fetchLatestUpdates'));
    final latestCallArgs = recordedArgs[recordedMethods.indexOf('fetchLatestUpdates')];
    expect(latestCallArgs['pkg'], subSelectorPkg);
    expect((latestCallArgs['apkPath'] as String?)?.isNotEmpty, isTrue);
    expect(latest.length, 1);
    expect(latest.first.cover, 'https://testsource.example/uploads/covers/solo.jpg');

    // 2. Fetch details -> must preserve `/comic/solo-leveling` URL!
    final details = await ApiService.instance.getManga(latest.first.id);
    final detailArgs = recordedArgs[recordedMethods.indexOf('fetchMangaDetails')];
    expect(detailArgs['url'], '/comic/solo-leveling');
    expect(details.cover, 'https://cdn.testsource.example/covers/solo_hd.jpg');
    expect(details.type, 'manhwa');

    // 3. Fetch chapters & pages -> resolves relative page URLs and registers native image loader + cookies!
    final chapters = await ApiService.instance.getChapters(latest.first.id);
    expect(chapters.length, 1);
    final pages = await ApiService.instance.getChapterPages(chapters.first.id);
    expect(pages.pages, [
      'https://testsource.example/images/ch1/001.jpg',
      'https://cdn.testsource.example/images/ch1/002.jpg',
    ]);
    expect(ImageReferers.prefersNative(pages.pages.first), isTrue);
    final headers = imageHeadersForUrl(pages.pages.first);
    expect(headers['Cookie'], 'cf_clearance=verified_token');
    final fetchedBytes = await ImageReferers.fetchNativeBytes(pages.pages.first);
    expect(fetchedBytes, equals(_validPngBytes));
  });

  testWidgets('Stalled/failing page never hangs: watchdog triggers specific Retry Page button and recovers on tap', (tester) async {
    int attempts = 0;
    const stalledUrl = 'https://stalled-cdn.example.org/ch10/page_03.jpg';

    // Register a native loader that stalls/fails first, then succeeds when the user taps Retry Page 3!
    ImageReferers.registerSourceConfig(
      [stalledUrl],
      referer: 'https://stalled-cdn.example.org/',
      preferNative: true,
      nativeLoader: (_) async {
        attempts++;
        if (attempts == 1) {
          // Simulate a tarpitted/dropped image server
          await Future<void>.delayed(const Duration(milliseconds: 500));
          return null;
        }
        return _validPngBytes;
      },
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RetryingNetworkImage(
            url: stalledUrl,
            attemptTimeout: const Duration(milliseconds: 120),
            progressBuilder: (_, _) => const Text('Loading Page 3...'),
            errorBuilder: (_, retry) => ElevatedButton(
              onPressed: retry,
              child: const Text('Retry Page 3'),
            ),
          ),
        ),
      ),
    );

    expect(find.text('Loading Page 3...'), findsOneWidget);

    // Advance past watchdog + HTTP fallback timeouts so all initial attempts exhaust cleanly
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }

    // Specific page retry button MUST be visible!
    expect(find.text('Retry Page 3'), findsOneWidget);

    // Tap "Retry Page 3" -> second native fetch returns valid PNG bytes and renders Image!
    await tester.tap(find.text('Retry Page 3'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(Image), findsOneWidget);
    expect(find.text('Retry Page 3'), findsNothing);
  });

  testWidgets('CoverImage self-heals missing covers via mangaId and renders offline file:// covers', (tester) async {
    // 1. Offline local file cover ("downloaded or not")
    final tmpCover = File('${Directory.systemTemp.path}/shiori_test_offline_cover.png');
    tmpCover.writeAsBytesSync(_validPngBytes);
    addTearDown(() {
      if (tmpCover.existsSync()) tmpCover.deleteSync();
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 100,
            height: 150,
            child: CoverImage(
              imageUrl: 'file://${tmpCover.path}',
              mangaId: 'ext:test:offline1',
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(Image), findsOneWidget);

    // 2. Self-healing cover when card initially has empty cover URL
    const healedCoverUrl = 'https://healed-cdn.example.org/cover.png';
    ImageReferers.coverLookup = (mangaId) async {
      if (mangaId == 'ext:test:missing_cover') {
        ImageReferers.registerSourceConfig(
          [healedCoverUrl],
          preferNative: true,
          nativeLoader: (_) async => _validPngBytes,
        );
        return healedCoverUrl;
      }
      return null;
    };

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 100,
            height: 150,
            child: CoverImage(
              imageUrl: '',
              mangaId: 'ext:test:missing_cover',
            ),
          ),
        ),
      ),
    );

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(ImageReferers.getResolvedCover('ext:test:missing_cover'), healedCoverUrl);
    expect(find.byType(Image), findsOneWidget);
  });
}

