import 'package:flutter_test/flutter_test.dart';
import 'package:manga_reader/services/api_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'dart:io';

void main() {
  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
    await ApiService.instance.init();
  });

  test('Test Direct Sources', () async {
    final sources = [
      'mangadex',
      'asura',
      'flamecomics',
      'weebcentral',
      'mangapill',
      'mangakatana',
      'mangaread',
    ];

    for (final s in sources) {
      try {
        final list = await ApiService.instance.searchManga(source: s);
        print('SOURCE $s: returned ${list.length} items');
        if (list.isNotEmpty) {
          final first = list.first;
          print('  First: ${first.title} (id: ${first.id}, cover: ${first.cover})');
          final chapters = await ApiService.instance.getChapters(first.id);
          print('  Chapters for ${first.title}: ${chapters.length}');
        }
      } catch (e, st) {
        print('SOURCE $s FAILED: $e\n$st');
      }
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
