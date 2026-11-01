import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:manga_reader/screens/browse_screen.dart';
import 'package:manga_reader/services/api_service.dart';
import 'package:manga_reader/services/extension_bridge.dart';
import 'package:manga_reader/services/extension_service.dart';
import 'package:manga_reader/services/source_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeExtensionApkHttpClient extends http.BaseClient {
  int apkDownloads = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    apkDownloads++;
    final fakeApkPayload = List<int>.filled(2048, 0x50);
    return http.StreamedResponse(
      Stream<List<int>>.value(fakeApkPayload),
      200,
      contentLength: fakeApkPayload.length,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  GoogleFonts.config.allowRuntimeFetching = false;

  const installerChannel = MethodChannel('com.example.manga_reader/installer');
  const extensionsChannel = MethodChannel('com.example.manga_reader/extensions');

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    SourceManager.debugPlatformOverride = null;
    ExtensionService.instance.httpClientFactory = null;
    ExtensionBridge.instance.forceAndroidForTesting = false;
    ExtensionService.instance.setDeviceExtensionsForTesting(const []);
    ExtensionService.instance.setRepoExtensionsForTesting(const []);
    await ApiService.instance.init();
  });

  tearDown(() {
    SourceManager.debugPlatformOverride = null;
    ExtensionService.instance.httpClientFactory = null;
    ExtensionBridge.instance.forceAndroidForTesting = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(installerChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(extensionsChannel, null);
  });

  test('Keiyoushi index.pb fixture protobuf decode (>1000 extensions, stubs filtered, Repo & Extension fields)', () {
    final fixtureFile = File('test/fixtures/keiyoushi_index.pb');
    expect(fixtureFile.existsSync(), isTrue, reason: 'test/fixtures/keiyoushi_index.pb must exist');

    final rawBytes = fixtureFile.readAsBytesSync();
    final decoded = ExtensionService.parseRepoProtobufForTesting(rawBytes);

    // Repo fields (1=name, 2=shortName, 3=signingKeyFingerprint, 4=links{1=website,2=discord}, 101=index)
    expect(decoded.name, 'Keiyoushi');
    expect(decoded.shortName, 'KEI');
    expect(
      decoded.signingKeyFingerprint,
      '9add655a78e96c4ec7a53ef89dccb557cb5d767489fac5e785d671a5a75d4da2',
    );
    expect(decoded.website, contains('keiyoushi.github.io'));

    final exts = decoded.extensions;
    expect(exts.length, greaterThan(1000));

    // Stubs must ALWAYS be filtered out
    expect(
      exts.any((e) => e.pkg.contains('extension.all.keiyoushi') || e.pkg.contains('extension.all.mihon')),
      isFalse,
    );
    expect(
      exts.any((e) => e.name.toLowerCase() == 'outdated app' || e.name.toLowerCase().startsWith('update to mihon')),
      isFalse,
    );

    // Check specific 1.6 extensions & fields
    final asura = exts.firstWhere((e) => e.pkg == 'eu.kanade.tachiyomi.extension.en.asurascans');
    expect(asura.name, 'Asura Scans');
    expect(asura.lang, 'EN');
    expect(asura.libVersion, '1.6');
    expect(asura.isCompatible, isTrue);
    expect(asura.versionCode, greaterThanOrEqualTo(70));
    expect(asura.apkUrl, contains('tachiyomi-en.asurascans'));
    expect(asura.iconUrl, contains('asurascans'));
    expect(asura.jarUrl, contains('.jar'));
    expect(asura.sources, isNotEmpty);

    // Check multi-language ("all" -> "ALL") derivation from pkg
    final mangadex = exts.firstWhere((e) => e.pkg == 'eu.kanade.tachiyomi.extension.all.mangadex');
    expect(mangadex.lang, 'ALL');
    expect(mangadex.libVersion, '1.6');
    expect(mangadex.sources.length, greaterThan(10));
  });

  test('Legacy JSON fallback filters out Keiyoushi/Mihon deprecation stub packages', () {
    final legacyStubJson = jsonEncode([
      {
        'name': 'Tachiyomi: Outdated App',
        'pkg': 'eu.kanade.tachiyomi.extension.all.keiyoushi',
        'apk': 'tachiyomi-all.keiyoushi-v1.4.2.apk',
        'lang': 'all',
        'code': 2,
        'version': '1.4.2',
        'nsfw': 0,
        'sources': [],
      },
      {
        'name': 'Tachiyomi: Update to Mihon 0.20.1+',
        'pkg': 'eu.kanade.tachiyomi.extension.all.mihon',
        'apk': 'tachiyomi-all.mihon-v1.4.2.apk',
        'lang': 'all',
        'code': 2,
        'version': '1.4.2',
        'nsfw': 1,
        'sources': [],
      },
      {
        'name': 'Tachiyomi: Custom Source',
        'pkg': 'eu.kanade.tachiyomi.extension.en.customsource',
        'apk': 'tachiyomi-en.customsource-v1.5.1.apk',
        'lang': 'en',
        'code': 5,
        'version': '1.5.1',
        'nsfw': 0,
        'sources': [
          {'id': '1234', 'name': 'Custom Source', 'lang': 'en', 'baseUrl': 'https://custom.example.org'},
        ],
      },
    ]);

    final parsed = ExtensionService.parseJsonIndexForTesting(legacyStubJson);
    expect(parsed.length, 1);
    expect(parsed.single.pkg, 'eu.kanade.tachiyomi.extension.en.customsource');
  });

  test('installedExtensions comes from device even when offline/repo empty, and merges with repo for update detection', () async {
    final service = ExtensionService.instance;
    SourceManager.debugPlatformOverride = TargetPlatform.android;

    // Mock Android MethodChannel returning 2 installed device extensions
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(installerChannel, (call) async {
      if (call.method == 'getInstalledExtensions') {
        return [
          {
            'name': 'Asura Scans',
            'pkg': 'eu.kanade.tachiyomi.extension.en.asurascans',
            'versionName': '1.6.68',
            'versionCode': 68,
            'libVersion': '1.6',
            'lang': 'EN',
            'nsfw': false,
            'iconBytes': Uint8List.fromList([137, 80, 78, 71]),
            'sources': [
              {
                'id': '6236404237041016552',
                'name': 'Asura Scans',
                'lang': 'en',
                'baseUrl': 'https://asuracomic.net',
              },
            ],
          },
          {
            'name': 'Weeb Central',
            'pkg': 'eu.kanade.tachiyomi.extension.en.weebcentral',
            'versionName': '1.6.13',
            'versionCode': 13,
            'libVersion': '1.6',
            'lang': 'EN',
            'nsfw': false,
            'sources': [
              {
                'id': '1932325120003706788',
                'name': 'Weeb Central',
                'lang': 'en',
                'baseUrl': 'https://weebcentral.com',
              },
            ],
          },
        ];
      }
      return null;
    });

    // 1. Refresh device extensions while repo is empty (offline scenario)
    await service.refreshInstalledPackages();

    final installedOffline = service.installedExtensions.toList();
    expect(installedOffline.length, 2);
    expect(installedOffline.map((e) => e.name), containsAll(['Asura Scans', 'Weeb Central']));
    expect(installedOffline.every((e) => e.hasUpdate == false), isTrue);

    // 2. Load repo extensions where Asura Scans has a newer versionCode (70 > 68) and Weeb Central is up-to-date (13 == 13)
    service.setRepoExtensionsForTesting([
      MangaExtension(
        id: 'eu.kanade.tachiyomi.extension.en.asurascans',
        name: 'Asura Scans',
        pkg: 'eu.kanade.tachiyomi.extension.en.asurascans',
        version: '1.6.70',
        versionCode: 70,
        libVersion: '1.6',
        apkUrl: 'https://raw.githubusercontent.com/keiyoushi/extensions/repo/apk/tachiyomi-en.asurascans-v1.6.70.apk',
        iconUrl: 'https://raw.githubusercontent.com/keiyoushi/extensions/repo/icon/eu.kanade.tachiyomi.extension.en.asurascans.png',
        lang: 'EN',
        isNsfw: false,
        sourceNames: const ['Asura Scans'],
      ),
      MangaExtension(
        id: 'eu.kanade.tachiyomi.extension.en.weebcentral',
        name: 'Weeb Central',
        pkg: 'eu.kanade.tachiyomi.extension.en.weebcentral',
        version: '1.6.13',
        versionCode: 13,
        libVersion: '1.6',
        apkUrl: 'https://raw.githubusercontent.com/keiyoushi/extensions/repo/apk/tachiyomi-en.weebcentral-v1.6.13.apk',
        iconUrl: 'https://raw.githubusercontent.com/keiyoushi/extensions/repo/icon/eu.kanade.tachiyomi.extension.en.weebcentral.png',
        lang: 'EN',
        isNsfw: false,
        sourceNames: const ['Weeb Central'],
      ),
      MangaExtension(
        id: 'eu.kanade.tachiyomi.extension.en.flamecomics',
        name: 'Flame Comics',
        pkg: 'eu.kanade.tachiyomi.extension.en.flamecomics',
        version: '1.6.30',
        versionCode: 30,
        libVersion: '1.6',
        apkUrl: 'https://raw.githubusercontent.com/keiyoushi/extensions/repo/apk/tachiyomi-en.flamecomics-v1.6.30.apk',
        iconUrl: 'https://raw.githubusercontent.com/keiyoushi/extensions/repo/icon/eu.kanade.tachiyomi.extension.en.flamecomics.png',
        lang: 'EN',
        isNsfw: false,
        sourceNames: const ['Flame Comics'],
      ),
    ]);

    expect(service.updatesAvailableExtensions.length, 1);
    final asuraMerged = service.updatesAvailableExtensions.single;
    expect(asuraMerged.pkg, 'eu.kanade.tachiyomi.extension.en.asurascans');
    expect(asuraMerged.hasUpdate, isTrue);
    expect(asuraMerged.version, '1.6.68');
    expect(asuraMerged.versionCode, 68);
    expect(asuraMerged.repoVersion, '1.6.70');
    expect(asuraMerged.repoVersionCode, 70);
    expect(asuraMerged.iconBytes, isNotNull);

    expect(service.upToDateInstalledExtensions.length, 1);
    expect(service.upToDateInstalledExtensions.single.pkg, 'eu.kanade.tachiyomi.extension.en.weebcentral');
    expect(service.upToDateInstalledExtensions.single.hasUpdate, isFalse);

    expect(service.availableExtensions.length, 1);
    expect(service.availableExtensions.single.pkg, 'eu.kanade.tachiyomi.extension.en.flamecomics');
  });

  testWidgets('Platform split: iOS shows ONLY built-in direct sources and no extension UI', (tester) async {
    SourceManager.debugPlatformOverride = TargetPlatform.iOS;
    ExtensionService.instance.setDeviceExtensionsForTesting([
      MangaExtension(
        id: 'eu.kanade.tachiyomi.extension.en.asurascans',
        name: 'ExtensionOnlyAsura',
        pkg: 'eu.kanade.tachiyomi.extension.en.asurascans',
        version: '1.6.70',
        versionCode: 70,
        libVersion: '1.6',
        apkUrl: '',
        iconUrl: '',
        lang: 'EN',
        isNsfw: false,
        sourceNames: const ['ExtensionOnlyAsura'],
        isInstalled: true,
      ),
    ]);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: BrowseScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // iOS must show Direct Sources (e.g. MangaDex, MangaPill) and NO Extensions tab or extension items
    expect(SourceManager.directSources, isNotEmpty);
    expect(find.text('DIRECT SOURCES'), findsOneWidget);
    expect(find.text('MangaDex'), findsWidgets);
    expect(find.text('EXTENSIONS'), findsNothing);
    expect(find.text('ExtensionOnlyAsura'), findsNothing);
  });

  testWidgets('Platform split: Android shows ONLY Tachiyomi/Keiyoushi extensions grouped by language + Incompatible badge', (tester) async {
    SourceManager.debugPlatformOverride = TargetPlatform.android;
    ExtensionService.instance.setDeviceExtensionsForTesting([
      MangaExtension(
        id: 'eu.kanade.tachiyomi.extension.en.asurascans',
        name: 'Asura Scans Ext',
        pkg: 'eu.kanade.tachiyomi.extension.en.asurascans',
        version: '1.6.70',
        versionCode: 70,
        libVersion: '1.6',
        apkUrl: '',
        iconUrl: '',
        lang: 'EN',
        isNsfw: false,
        sourceNames: const ['Asura Scans'],
        isInstalled: true,
      ),
      MangaExtension(
        id: 'eu.kanade.tachiyomi.extension.all.legacyext',
        name: 'Legacy Incompatible Ext',
        pkg: 'eu.kanade.tachiyomi.extension.all.legacyext',
        version: '1.2.1',
        versionCode: 1,
        libVersion: '1.2',
        apkUrl: '',
        iconUrl: '',
        lang: 'ALL',
        isNsfw: false,
        sourceNames: const ['Legacy Ext'],
        isInstalled: true,
      ),
    ]);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: BrowseScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Android must show SOURCES and EXTENSIONS tabs, and zero direct sources
    expect(SourceManager.directSources, isEmpty);
    expect(find.text('SOURCES'), findsOneWidget);
    expect(find.text('EXTENSIONS'), findsOneWidget);
    expect(find.text('DIRECT SOURCES'), findsNothing);
    expect(find.text('MangaPill'), findsNothing);

    // Language group headers and extension cards
    expect(find.text('ENGLISH (EN)'), findsOneWidget);
    expect(find.text('MULTI-LANGUAGE (ALL)'), findsOneWidget);
    expect(find.text('Asura Scans Ext'), findsWidgets);
    expect(find.text('Legacy Incompatible Ext'), findsWidgets);
    expect(find.text('Incompatible lib version'), findsOneWidget);

    // Popular / Latest per source (redundant Search button removed)
    expect(find.text('Popular'), findsWidgets);
    expect(find.text('Latest'), findsWidgets);
    expect(find.text('Search'), findsNothing);
  });

  test('Updating an extension updates version/versionCode, clears hasUpdate, and moves it to upToDateInstalledExtensions', () async {
    final service = ExtensionService.instance;
    SourceManager.debugPlatformOverride = TargetPlatform.android;

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(installerChannel, (call) async {
      if (call.method == 'getInstalledExtensions') {
        return [
          {
            'name': 'Asura Scans',
            'pkg': 'eu.kanade.tachiyomi.extension.en.asurascans',
            'versionName': '1.6.68',
            'versionCode': 68,
            'libVersion': '1.6',
            'lang': 'EN',
            'nsfw': false,
          },
        ];
      }
      if (call.method == 'installApk') {
        return true;
      }
      return null;
    });

    await service.refreshInstalledPackages();
    service.setRepoExtensionsForTesting([
      MangaExtension(
        id: 'eu.kanade.tachiyomi.extension.en.asurascans',
        name: 'Asura Scans',
        pkg: 'eu.kanade.tachiyomi.extension.en.asurascans',
        version: '1.6.70',
        versionCode: 70,
        libVersion: '1.6',
        apkUrl: '',
        iconUrl: '',
        lang: 'EN',
        isNsfw: false,
        sourceNames: const ['Asura Scans'],
      ),
    ]);

    expect(service.updatesAvailableExtensions.length, 1);
    final outdated = service.updatesAvailableExtensions.single;
    expect(outdated.hasUpdate, isTrue);
    expect(outdated.version, '1.6.68');
    expect(outdated.repoVersion, '1.6.70');

    final ok = await service.downloadAndInstallExtension(outdated);
    expect(ok, isTrue);

    // Even if refreshInstalledPackages is called before OS PackageInstaller finishes,
    // the updated version (1.6.70 / 70) must be preserved and hasUpdate must be false.
    await service.refreshInstalledPackages();

    expect(service.updatesAvailableExtensions, isEmpty);
    expect(service.upToDateInstalledExtensions.length, 1);
    final updated = service.upToDateInstalledExtensions.single;
    expect(updated.version, '1.6.70');
    expect(updated.versionCode, 70);
    expect(updated.hasUpdate, isFalse);
    expect(updated.repoVersion, isNull);
    expect(updated.repoVersionCode, isNull);
  });

  test('Cancelled or failed OS APK installation keeps hasUpdate=true, preserves old version, and surfaces error without polluting private storage', () async {
    final service = ExtensionService.instance;
    SourceManager.debugPlatformOverride = TargetPlatform.android;

    final fakeHttp = _FakeExtensionApkHttpClient();
    service.httpClientFactory = () => fakeHttp;

    var persistCalled = false;
    Map<dynamic, dynamic>? installApkArgs;

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(installerChannel, (call) async {
      if (call.method == 'getInstalledExtensions') {
        return [
          {
            'name': 'Manganato',
            'pkg': 'eu.kanade.tachiyomi.extension.en.manganelo',
            'versionName': '1.6.23',
            'versionCode': 106023,
            'libVersion': '1.6',
            'lang': 'EN',
            'nsfw': false,
          },
        ];
      }
      if (call.method == 'persistExtensionApk') {
        persistCalled = true;
        return '/fake/persisted.apk';
      }
      if (call.method == 'installApk') {
        installApkArgs = call.arguments as Map<dynamic, dynamic>?;
        throw PlatformException(
          code: 'INSTALL_CANCELLED',
          message: 'Update cancelled.',
        );
      }
      return null;
    });

    await service.refreshInstalledPackages();
    service.setRepoExtensionsForTesting(
      [
        MangaExtension(
          id: 'eu.kanade.tachiyomi.extension.en.manganelo',
          name: 'Manganato',
          pkg: 'eu.kanade.tachiyomi.extension.en.manganelo',
          version: '1.6.24',
          versionCode: 106024,
          libVersion: '1.6',
          apkUrl: 'https://raw.githubusercontent.com/keiyoushi/extensions/repo/apk/tachiyomi-en.manganelo-v1.6.24.apk',
          iconUrl: '',
          lang: 'EN',
          isNsfw: false,
          sourceNames: const ['Manganato'],
        ),
      ],
      meta: ExtensionRepoMeta(
        name: 'Keiyoushi',
        shortName: 'KEI',
        signingKeyFingerprint: '9add655a78e96c4ec7a53ef89dccb557cb5d767489fac5e785d671a5a75d4da2',
        website: 'https://keiyoushi.github.io',
        discord: '',
        extensions: const [],
      ),
    );

    final outdated = service.updatesAvailableExtensions.single;
    final ok = await service.downloadAndInstallExtension(outdated);

    expect(ok, isFalse);
    expect(fakeHttp.apkDownloads, 1);
    expect(persistCalled, isFalse, reason: 'Update download must not persist to private storage before PackageInstaller succeeds');
    expect(installApkArgs, isNotNull);
    expect(
      installApkArgs!['expectedFingerprint'],
      '9add655a78e96c4ec7a53ef89dccb557cb5d767489fac5e785d671a5a75d4da2',
    );
    expect(service.lastInstallError, 'Update cancelled.');

    // Extension must STILL show as needing an update at its real OS version 1.6.23
    expect(service.updatesAvailableExtensions.length, 1);
    final stillOutdated = service.updatesAvailableExtensions.single;
    expect(stillOutdated.version, '1.6.23');
    expect(stillOutdated.versionCode, 106023);
    expect(stillOutdated.hasUpdate, isTrue);
    expect(stillOutdated.repoVersion, '1.6.24');
    expect(stillOutdated.repoVersionCode, 106024);
  });

  test('Poisoned SharedPreferences metadata self-heals against real Android PackageManager versionCode on refresh', () async {
    final service = ExtensionService.instance;
    SourceManager.debugPlatformOverride = TargetPlatform.android;

    // Simulate previously poisoned SharedPreferences claiming Manganato is already 1.6.24 (106024)
    final poisonedEntry = MangaExtension(
      id: 'eu.kanade.tachiyomi.extension.en.manganelo',
      name: 'Manganato',
      pkg: 'eu.kanade.tachiyomi.extension.en.manganelo',
      version: '1.6.24',
      versionCode: 106024,
      libVersion: '1.6',
      apkUrl: '',
      iconUrl: '',
      lang: 'EN',
      isNsfw: false,
      sourceNames: const ['Manganato'],
      isInstalled: true,
    );
    SharedPreferences.setMockInitialValues({
      'shiori_installed_extensions': ['eu.kanade.tachiyomi.extension.en.manganelo'],
      'shiori_installed_extensions_meta_v2': jsonEncode({
        'eu.kanade.tachiyomi.extension.en.manganelo': poisonedEntry.toJson(),
      }),
    });
    await service.reloadPersistedInstalledStateForTesting();

    // Real Android OS PackageManager still has 1.6.23 (106023)
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(installerChannel, (call) async {
      if (call.method == 'getInstalledExtensions') {
        return [
          {
            'name': 'Manganato',
            'pkg': 'eu.kanade.tachiyomi.extension.en.manganelo',
            'versionName': '1.6.23',
            'versionCode': 106023,
            'libVersion': '1.6',
            'lang': 'EN',
            'nsfw': false,
          },
        ];
      }
      return null;
    });

    await service.refreshInstalledPackages();
    service.setRepoExtensionsForTesting([
      MangaExtension(
        id: 'eu.kanade.tachiyomi.extension.en.manganelo',
        name: 'Manganato',
        pkg: 'eu.kanade.tachiyomi.extension.en.manganelo',
        version: '1.6.24',
        versionCode: 106024,
        libVersion: '1.6',
        apkUrl: 'https://raw.githubusercontent.com/keiyoushi/extensions/repo/apk/tachiyomi-en.manganelo-v1.6.24.apk',
        iconUrl: '',
        lang: 'EN',
        isNsfw: false,
        sourceNames: const ['Manganato'],
      ),
    ]);

    expect(service.updatesAvailableExtensions.length, 1);
    final healed = service.updatesAvailableExtensions.single;
    expect(healed.version, '1.6.23');
    expect(healed.versionCode, 106023);
    expect(healed.hasUpdate, isTrue);
    expect(healed.repoVersion, '1.6.24');
  });

  test('updateAllExtensions downloads and installs each outdated APK via PackageInstaller and marks all up to date', () async {
    final service = ExtensionService.instance;
    SourceManager.debugPlatformOverride = TargetPlatform.android;

    final fakeHttp = _FakeExtensionApkHttpClient();
    service.httpClientFactory = () => fakeHttp;

    final installedVersionsOnOs = <String, (String, int)>{
      'eu.kanade.tachiyomi.extension.en.manganelo': ('1.6.23', 106023),
      'eu.kanade.tachiyomi.extension.en.asurascans': ('1.6.68', 68),
    };
    var installApkCalls = 0;

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(installerChannel, (call) async {
      if (call.method == 'getInstalledExtensions') {
        return installedVersionsOnOs.entries.map((entry) {
          return {
            'name': entry.key.split('.').last,
            'pkg': entry.key,
            'versionName': entry.value.$1,
            'versionCode': entry.value.$2,
            'libVersion': '1.6',
            'lang': 'EN',
            'nsfw': false,
          };
        }).toList();
      }
      if (call.method == 'installApk') {
        installApkCalls++;
        final path = (call.arguments as Map)['filePath'] as String;
        if (path.contains('manganelo')) {
          installedVersionsOnOs['eu.kanade.tachiyomi.extension.en.manganelo'] = ('1.6.24', 106024);
        } else if (path.contains('asurascans')) {
          installedVersionsOnOs['eu.kanade.tachiyomi.extension.en.asurascans'] = ('1.6.70', 70);
        }
        return true;
      }
      return null;
    });

    await service.refreshInstalledPackages();
    service.setRepoExtensionsForTesting([
      MangaExtension(
        id: 'eu.kanade.tachiyomi.extension.en.manganelo',
        name: 'Manganato',
        pkg: 'eu.kanade.tachiyomi.extension.en.manganelo',
        version: '1.6.24',
        versionCode: 106024,
        libVersion: '1.6',
        apkUrl: 'https://raw.githubusercontent.com/keiyoushi/extensions/repo/apk/tachiyomi-en.manganelo-v1.6.24.apk',
        iconUrl: '',
        lang: 'EN',
        isNsfw: false,
        sourceNames: const ['Manganato'],
      ),
      MangaExtension(
        id: 'eu.kanade.tachiyomi.extension.en.asurascans',
        name: 'Asura Scans',
        pkg: 'eu.kanade.tachiyomi.extension.en.asurascans',
        version: '1.6.70',
        versionCode: 70,
        libVersion: '1.6',
        apkUrl: 'https://raw.githubusercontent.com/keiyoushi/extensions/repo/apk/tachiyomi-en.asurascans-v1.6.70.apk',
        iconUrl: '',
        lang: 'EN',
        isNsfw: false,
        sourceNames: const ['Asura Scans'],
      ),
    ]);

    expect(service.updatesAvailableExtensions.length, 2);
    final updatedCount = await service.updateAllExtensions();

    expect(updatedCount, 2);
    expect(installApkCalls, 2);
    expect(fakeHttp.apkDownloads, 2);
    expect(service.updatesAvailableExtensions, isEmpty);
    expect(service.upToDateInstalledExtensions.length, 2);
  });

  test('Browsing an installed extension with a pending update does not silently download the update APK in the background', () async {
    final service = ExtensionService.instance;
    SourceManager.debugPlatformOverride = TargetPlatform.android;
    ExtensionBridge.instance.forceAndroidForTesting = true;

    final fakeHttp = _FakeExtensionApkHttpClient();
    service.httpClientFactory = () => fakeHttp;

    service.setDeviceExtensionsForTesting([
      MangaExtension(
        id: 'eu.kanade.tachiyomi.extension.en.manganelo',
        name: 'Manganato',
        pkg: 'eu.kanade.tachiyomi.extension.en.manganelo',
        version: '1.6.23',
        versionCode: 106023,
        libVersion: '1.6',
        apkUrl: '',
        iconUrl: '',
        lang: 'EN',
        isNsfw: false,
        sourceNames: const ['Manganato'],
        isInstalled: true,
      ),
    ]);
    service.setRepoExtensionsForTesting([
      MangaExtension(
        id: 'eu.kanade.tachiyomi.extension.en.manganelo',
        name: 'Manganato',
        pkg: 'eu.kanade.tachiyomi.extension.en.manganelo',
        version: '1.6.24',
        versionCode: 106024,
        libVersion: '1.6',
        apkUrl: 'https://raw.githubusercontent.com/keiyoushi/extensions/repo/apk/tachiyomi-en.manganelo-v1.6.24.apk',
        iconUrl: '',
        lang: 'EN',
        isNsfw: false,
        sourceNames: const ['Manganato'],
      ),
    ]);

    Map<dynamic, dynamic>? popularArgs;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(extensionsChannel, (call) async {
      if (call.method == 'fetchPopularManga') {
        popularArgs = call.arguments as Map<dynamic, dynamic>?;
        return <Map<String, dynamic>>[];
      }
      return null;
    });

    await ExtensionBridge.instance.fetchPopularManga(
      pkg: 'eu.kanade.tachiyomi.extension.en.manganelo',
      page: 1,
    );

    expect(fakeHttp.apkDownloads, 0);
    expect(popularArgs, isNotNull);
    expect(popularArgs!['apkPath'], isNull);
  });
}
