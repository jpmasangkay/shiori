import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:manga_reader/services/extension_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class KeiyoushiExtension {
  final String name;
  final String pkg;
  final String version;
  final int versionCode;
  final String apkUrl;
  final String iconUrl;
  final String lang;
  final bool isNsfw;
  final List<String> sourceNames;

  KeiyoushiExtension({
    required this.name,
    required this.pkg,
    required this.version,
    required this.versionCode,
    required this.apkUrl,
    required this.iconUrl,
    required this.lang,
    required this.isNsfw,
    required this.sourceNames,
  });
}

class KeiyoushiParser {
  static List<KeiyoushiExtension> parse(Uint8List rawBytes) {
    // If gzipped, decompress
    Uint8List data = rawBytes;
    if (rawBytes.length >= 2 && rawBytes[0] == 0x1f && rawBytes[1] == 0x8b) {
      data = Uint8List.fromList(gzip.decode(rawBytes));
    }

    final extensions = <KeiyoushiExtension>[];
    int pos = 0;

    while (pos < data.length) {
      final tag = data[pos++];
      final wire = tag & 0x07;
      final field = tag >> 3;

      if (wire == 2) {
        int len = 0;
        int shift = 0;
        while (true) {
          final b = data[pos++];
          len |= (b & 0x7f) << shift;
          if ((b & 0x80) == 0) break;
          shift += 7;
        }

        if (pos + len > data.length) break;
        final sub = Uint8List.sublistView(data, pos, pos + len);
        pos += len;

        if (field == 1) {
          try {
            final ext = _parseExtension(sub);
            if (ext != null && ext.name.isNotEmpty) {
              extensions.pushOrAdd(ext);
            }
          } catch (_) {}
        }
      } else if (wire == 0) {
        while ((data[pos++] & 0x80) != 0) {}
      } else if (wire == 5) {
        pos += 4;
      } else if (wire == 1) {
        pos += 8;
      } else {
        break;
      }
    }

    return extensions;
  }

  static KeiyoushiExtension? _parseExtension(Uint8List sub) {
    int pos = 0;
    String name = '';
    String pkg = '';
    String version = '';
    int versionCode = 0;
    String apkUrl = '';
    String iconUrl = '';
    int nsfw = 0;
    String lang = 'all';
    final sourceNames = <String>[];

    while (pos < sub.length) {
      final tag = sub[pos++];
      final wire = tag & 0x07;
      final field = tag >> 3;

      if (wire == 2) {
        int len = 0;
        int shift = 0;
        while (true) {
          final b = sub[pos++];
          len |= (b & 0x7f) << shift;
          if ((b & 0x80) == 0) break;
          shift += 7;
        }
        if (pos + len > sub.length) break;
        final chunk = Uint8List.sublistView(sub, pos, pos + len);
        pos += len;

        if (field == 1) {
          name = utf8.decode(chunk, allowMalformed: true);
        } else if (field == 2) {
          pkg = utf8.decode(chunk, allowMalformed: true);
        } else if (field == 3) {
          // Assets
          final assets = _parseAssets(chunk);
          apkUrl = assets.apk;
          iconUrl = assets.icon;
        } else if (field == 6) {
          version = utf8.decode(chunk, allowMalformed: true);
        } else if (field == 8) {
          // Source submessage
          final src = _parseSource(chunk);
          if (src.name.isNotEmpty) sourceNames.add(src.name);
          if (src.lang.isNotEmpty && lang == 'all') lang = src.lang;
        }
      } else if (wire == 0) {
        int val = 0;
        int shift = 0;
        while (true) {
          final b = sub[pos++];
          val |= (b & 0x7f) << shift;
          if ((b & 0x80) == 0) break;
          shift += 7;
        }
        if (field == 5) {
          versionCode = val;
        } else if (field == 7) {
          nsfw = val;
        }
      } else if (wire == 5) {
        pos += 4;
      } else if (wire == 1) {
        pos += 8;
      } else {
        break;
      }
    }

    if (name.isEmpty && pkg.isEmpty) return null;

    // Detect language from pkg if not set
    if (lang == 'all') {
      final parts = pkg.split('.');
      if (parts.length >= 5 && parts[3] != 'all') {
        lang = parts[3].toUpperCase();
      }
    }

    return KeiyoushiExtension(
      name: name.isNotEmpty ? name : (sourceNames.isNotEmpty ? sourceNames.first : pkg),
      pkg: pkg,
      version: version,
      versionCode: versionCode,
      apkUrl: apkUrl,
      iconUrl: iconUrl,
      lang: lang.toUpperCase(),
      isNsfw: nsfw >= 2,
      sourceNames: sourceNames,
    );
  }

  static ({String apk, String icon}) _parseAssets(Uint8List chunk) {
    int pos = 0;
    String apk = '';
    String icon = '';

    while (pos < chunk.length) {
      final tag = chunk[pos++];
      final wire = tag & 0x07;
      final field = tag >> 3;

      if (wire == 2) {
        int len = 0;
        int shift = 0;
        while (true) {
          final b = chunk[pos++];
          len |= (b & 0x7f) << shift;
          if ((b & 0x80) == 0) break;
          shift += 7;
        }
        if (pos + len > chunk.length) break;
        final s = utf8.decode(Uint8List.sublistView(chunk, pos, pos + len), allowMalformed: true);
        pos += len;
        if (field == 1) apk = s;
        if (field == 2) icon = s;
      } else if (wire == 0) {
        while ((chunk[pos++] & 0x80) != 0) {}
      } else if (wire == 5) {
        pos += 4;
      } else if (wire == 1) {
        pos += 8;
      } else {
        break;
      }
    }
    return (apk: apk, icon: icon);
  }

  static ({String name, String lang, String baseUrl}) _parseSource(Uint8List chunk) {
    int pos = 0;
    String name = '';
    String lang = '';
    String baseUrl = '';

    while (pos < chunk.length) {
      final tag = chunk[pos++];
      final wire = tag & 0x07;
      final field = tag >> 3;

      if (wire == 2) {
        int len = 0;
        int shift = 0;
        while (true) {
          final b = chunk[pos++];
          len |= (b & 0x7f) << shift;
          if ((b & 0x80) == 0) break;
          shift += 7;
        }
        if (pos + len > chunk.length) break;
        final s = utf8.decode(Uint8List.sublistView(chunk, pos, pos + len), allowMalformed: true);
        pos += len;
        if (field == 2) name = s;
        if (field == 3) lang = s;
        if (field == 4) baseUrl = s;
      } else if (wire == 0) {
        while ((chunk[pos++] & 0x80) != 0) {}
      } else if (wire == 5) {
        pos += 4;
      } else if (wire == 1) {
        pos += 8;
      } else {
        break;
      }
    }
    return (name: name, lang: lang, baseUrl: baseUrl);
  }
}

extension _ListExt<T> on List<T> {
  void pushOrAdd(T val) => add(val);
}

class _AllowHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context)
      ..badCertificateCallback = (X509Certificate cert, String host, int port) => true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = _AllowHttpOverrides();

  test('Keiyoushi index.pb parser test', () async {
    final res = await http.get(Uri.parse('https://raw.githubusercontent.com/keiyoushi/extensions/repo/index.pb'));
    expect(res.statusCode, 200);

    final exts = KeiyoushiParser.parse(res.bodyBytes);
    expect(exts.length, greaterThan(1000));

    final asura = exts.firstWhere((e) => e.pkg.contains('asurascans'));
    expect(asura.apkUrl.isNotEmpty, true);
    expect(asura.iconUrl.isNotEmpty, true);
  });

  test('ExtensionService in-app download and installation test', () async {
    SharedPreferences.setMockInitialValues({});
    final service = ExtensionService.instance;

    final testExt = MangaExtension(
      id: 'eu.kanade.tachiyomi.extension.en.testextension',
      name: 'Test Extension',
      pkg: 'eu.kanade.tachiyomi.extension.en.testextension',
      version: '1.4.0',
      versionCode: 140,
      apkUrl: '', // empty to test instant in-app fallback
      iconUrl: 'https://example.com/icon.png',
      lang: 'EN',
      isNsfw: false,
      sourceNames: ['Test Source'],
    );

    expect(testExt.isInstalled, false);
    expect(service.isPackageInstalled(testExt.pkg), false);

    // Perform in-app download and install
    final success = await service.downloadAndInstallExtension(testExt);
    expect(success, true);
    expect(testExt.isInstalled, true);
    expect(service.isPackageInstalled(testExt.pkg), true);
    expect(service.installedExtensions.any((e) => e.pkg == testExt.pkg), true);

    // Uninstall
    await service.uninstallExtension(testExt);
    expect(testExt.isInstalled, false);
    expect(service.isPackageInstalled(testExt.pkg), false);
    expect(service.installedExtensions.any((e) => e.pkg == testExt.pkg), false);
  });
}
