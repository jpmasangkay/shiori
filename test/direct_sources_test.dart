// ignore_for_file: avoid_print
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:manga_reader/services/api_service.dart';
import 'package:manga_reader/widgets/common.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<bool> _verifyImageLoads(String url) async {
  for (final headers in imageHeaderVariants(url)) {
    try {
      final res = await http
          .get(Uri.parse(url), headers: {...headers, 'Range': 'bytes=0-2047'})
          .timeout(const Duration(seconds: 10));
      if ((res.statusCode == 200 || res.statusCode == 206) && res.bodyBytes.isNotEmpty) {
        return true;
      }
    } catch (_) {}
  }
  return false;
}

void main() {
  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
    await ApiService.instance.init();
  });

  test('All 7 direct sources return covers, details, chapters, and loadable pages', () async {
    const sources = [
      'mangadex',
      'asura',
      'flamecomics',
      'weebcentral',
      'mangapill',
      'mangakatana',
      'mangaread',
    ];

    final failures = <String>[];

    for (final s in sources) {
      print('\n=== Verifying Direct Source: $s ===');
      try {
        final browseList = await ApiService.instance.searchManga(source: s);
        print('[$s] Browse catalog count: ${browseList.length}');
        if (browseList.isEmpty) {
          failures.add('[$s] browse catalog returned 0 items');
          continue;
        }

        final missingBrowseCovers = browseList.where((m) => !m.cover.startsWith('http')).toList();
        if (missingBrowseCovers.isNotEmpty) {
          failures.add('[$s] ${missingBrowseCovers.length} browse items missing http cover URL');
        }

        final searchList = await ApiService.instance.searchManga(source: s, query: 'level');
        print('[$s] Search("level") count: ${searchList.length}');
        if (searchList.isEmpty) {
          failures.add('[$s] search("level") returned 0 items');
        } else {
          final missingSearchCovers = searchList.where((m) => !m.cover.startsWith('http')).toList();
          if (missingSearchCovers.isNotEmpty) {
            failures.add('[$s] ${missingSearchCovers.length} search items missing http cover URL');
          }
        }

        var chosen = browseList.first;
        var chapters = await ApiService.instance.getChapters(chosen.id);
        for (final candidate in browseList.skip(1).take(3)) {
          if (chapters.isNotEmpty) break;
          chosen = candidate;
          chapters = await ApiService.instance.getChapters(chosen.id);
        }

        print('[$s] Picked "${chosen.title}" (${chosen.id}) -> ${chapters.length} chapters');
        if (chapters.isEmpty) {
          failures.add('[$s] getChapters(${chosen.id}) returned 0 chapters');
          continue;
        }

        final details = await ApiService.instance.getManga(chosen.id);
        print('[$s] Details title="${details.title}" cover="${details.cover}"');
        if (!details.cover.startsWith('http')) {
          failures.add('[$s] getManga(${chosen.id}) missing http cover URL ("${details.cover}")');
        } else {
          final coverOk = await _verifyImageLoads(details.cover);
          print('[$s] Cover HTTP load: $coverOk');
          if (!coverOk) {
            failures.add('[$s] cover URL failed HTTP load: ${details.cover}');
          }
        }

        final sampleChapter = chapters.first;
        final chapterPages = await ApiService.instance.getChapterPages(sampleChapter.id);
        print('[$s] Chapter "${sampleChapter.displayTitle}" (${sampleChapter.id}) -> ${chapterPages.pages.length} pages');
        if (chapterPages.pages.isEmpty) {
          failures.add('[$s] getChapterPages(${sampleChapter.id}) returned 0 pages');
          continue;
        }
        if (!chapterPages.pages.every((p) => p.startsWith('http'))) {
          failures.add('[$s] non-http URL in chapterPages for ${sampleChapter.id}');
        }

        final firstPageUrl = chapterPages.pages.first;
        final pageOk = await _verifyImageLoads(firstPageUrl);
        print('[$s] First page HTTP load ($firstPageUrl): $pageOk');
        if (!pageOk) {
          failures.add('[$s] first page failed HTTP load: $firstPageUrl');
        }
      } catch (e, st) {
        print('[$s] EXCEPTION: $e\n$st');
        failures.add('[$s] threw exception: $e');
      }
    }

    if (failures.isNotEmpty) {
      print('\n--- FAILURES SUMMARY ---\n${failures.join('\n')}');
    }
    expect(failures, isEmpty, reason: failures.join('; '));
  }, timeout: const Timeout(Duration(minutes: 3)));
}
