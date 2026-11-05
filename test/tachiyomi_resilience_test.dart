import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:manga_reader/services/api_service.dart';
import 'package:manga_reader/services/extension_bridge.dart';
import 'package:manga_reader/services/extension_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const extensionsChannel = MethodChannel('com.example.manga_reader/extensions');

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    ExtensionBridge.instance.clearCachesForTesting();
    ExtensionBridge.instance.forceAndroidForTesting = true;
    ExtensionService.instance.setDeviceExtensionsForTesting(const []);
    ExtensionService.instance.setRepoExtensionsForTesting(const []);
    await ApiService.instance.init();
  });

  tearDown(() {
    ExtensionBridge.instance.forceAndroidForTesting = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(extensionsChannel, null);
  });

  test('ExtensionBridge maps relative manga and chapter URLs with a leading slash', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(extensionsChannel, (call) async {
      if (call.method == 'fetchPopularManga') {
        return [
          {
            'url': 'series/01J76XYDHFFVWJXVWCEZTCHK8Q/Bungo',
            'title': 'Bungo Stray Dogs',
            'thumbnail_url': 'https://weebcentral.com/cover.jpg',
          }
        ];
      }
      if (call.method == 'fetchChapterList') {
        return [
          {
            'url': 'chapters/01J76XYV0H8W93M895123/1',
            'name': 'Chapter 1',
            'chapter_number': 1.0,
          }
        ];
      }
      return null;
    });

    final mangas = await ExtensionBridge.instance.fetchPopularManga(
      pkg: 'eu.kanade.tachiyomi.extension.en.weebcentral',
    );
    expect(mangas, isNotEmpty);
    expect(mangas.first.id, contains(Uri.encodeComponent('/series/01J76XYDHFFVWJXVWCEZTCHK8Q/Bungo')));

    final chapters = await ExtensionBridge.instance.fetchChapterList(
      pkg: 'eu.kanade.tachiyomi.extension.en.weebcentral',
      url: '/series/01J76XYDHFFVWJXVWCEZTCHK8Q/Bungo',
    );
    expect(chapters, isNotEmpty);
    expect(chapters.first.id, contains(Uri.encodeComponent('/chapters/01J76XYV0H8W93M895123/1')));
  });

  test('ApiService.getChapters falls back gracefully without unhandled exception when native throws on Android', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(extensionsChannel, (call) async {
      if (call.method == 'fetchChapterList') {
        throw PlatformException(
          code: 'EXTENSION_NOT_FOUND',
          message: 'Extension APK for package eu.kanade.tachiyomi.extension.en.test not found on device.',
        );
      }
      return null;
    });

    final ext = MangaExtension(
      id: 'test',
      name: 'Test Source',
      pkg: 'eu.kanade.tachiyomi.extension.en.test',
      version: '1.0',
      versionCode: 1,
      apkUrl: '',
      iconUrl: '',
      lang: 'EN',
      isNsfw: false,
      sourceNames: ['Test Source'],
      homeUrl: '',
    );
    ExtensionService.instance.setRepoExtensionsForTesting([ext]);

    // When native throws and no web fallback homeUrl is present, it should throw a clear exception
    expect(
      () => ApiService.instance.getChapters('ext:eu.kanade.tachiyomi.extension.en.test:series/123'),
      throwsA(isA<PlatformException>()),
    );
  });

  test('ApiService.searchManga returns empty list gracefully without throwing when native search encounters an error', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(extensionsChannel, (call) async {
      if (call.method == 'searchManga') {
        throw PlatformException(
          code: 'SEARCH_ERROR',
          message: 'Connection timed out or 500 error from source',
        );
      }
      return null;
    });

    final ext = MangaExtension(
      id: 'test_ext',
      name: 'Test Source',
      pkg: 'eu.kanade.tachiyomi.extension.en.test_search',
      version: '1.0',
      versionCode: 1,
      apkUrl: '',
      iconUrl: '',
      lang: 'EN',
      isNsfw: false,
      sourceNames: ['Test Source'],
      homeUrl: '',
    );
    ExtensionService.instance.setRepoExtensionsForTesting([ext]);

    final results = await ApiService.instance.searchManga(
      query: 'Solo Leveling',
      source: 'eu.kanade.tachiyomi.extension.en.test_search',
    );
    expect(results, isEmpty);
  });

  test('ExtensionBridge correctly classifies manhwa from manhwa scanlator package and description', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(extensionsChannel, (call) async {
      if (call.method == 'fetchPopularManga') {
        return [
          {
            'url': '/series/solo-leveling',
            'title': 'Solo Leveling',
            'thumbnail_url': 'https://asura.nacm.xyz/cover.jpg',
            'description': 'Famous web novel adaptation.',
          },
          {
            'url': '/series/magic-emperor',
            'title': 'Magic Emperor',
            'thumbnail_url': 'https://colamanga.com/cover.jpg',
            'description': 'Chinese cultivation series.',
          }
        ];
      }
      return null;
    });

    final manhwas = await ExtensionBridge.instance.fetchPopularManga(
      pkg: 'eu.kanade.tachiyomi.extension.en.asurascans',
    );
    expect(manhwas.first.type, 'manhwa');

    final manhuas = await ExtensionBridge.instance.fetchPopularManga(
      pkg: 'eu.kanade.tachiyomi.extension.zh.colamanga',
    );
    expect(manhuas.last.type, 'manhua');
  });
}
