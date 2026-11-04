import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:manga_reader/models/manga_models.dart';
import 'package:manga_reader/services/library_repository.dart';
import 'package:manga_reader/widgets/common.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    ImageReferers.resetForTesting();
  });

  group('ImageReferers and imageHeadersForUrl Tests', () {
    test('resmk.org and mangabuddy URLs receive mangabuddy referer', () {
      final headers = imageHeadersForUrl('https://rx.resmk.org/covers/8cec924e03c9.webp');
      expect(headers['Referer'], 'https://mangabuddy.com/');

      final buddyHeaders = imageHeadersForUrl('https://mangabuddy.com/avatar.png');
      expect(buddyHeaders['Referer'], 'https://mangabuddy.com/');
    });

    test('mpcdn and manganelo URLs receive manganelo referer', () {
      final headers = imageHeadersForUrl('https://v1.mpcdn.net/covers/123.jpg');
      expect(headers['Referer'], 'https://manganelo.com/');
    });

    test('derives referer from extension package when mangaId is provided', () {
      final headers = imageHeadersForUrl(
        'https://custom-cdn.net/cover.jpg',
        mangaId: 'ext:eu.kanade.tachiyomi.extension.en.mangabuddy:%2Fblue-lock',
      );
      expect(headers['Referer'], 'https://mangabuddy.com/');
    });

    test('refererProvider dynamically provides referer', () {
      ImageReferers.refererProvider = (url, mangaId) {
        if (url.contains('dynamic-source')) return 'https://dynamic.source.com';
        return null;
      };

      final headers = imageHeadersForUrl('https://dynamic-source.net/cover.webp');
      expect(headers['Referer'], 'https://dynamic.source.com/');
    });

    test('nativeLoaderProvider supplies loader for extension manga', () {
      bool loaderCalled = false;
      ImageReferers.nativeLoaderProvider = (url, mangaId) {
        if (mangaId != null && mangaId.startsWith('ext:test.extension')) {
          return (targetUrl) async {
            loaderCalled = true;
            return Uint8List.fromList([1, 2, 3]);
          };
        }
        return null;
      };

      final loader = ImageReferers.lookupNativeLoader(
        'https://cdn.test/img.png',
        mangaId: 'ext:test.extension:123',
      );
      expect(loader, isNotNull);
      loader!('https://cdn.test/img.png');
      expect(loaderCalled, isTrue);
    });

    test('imageHeaderVariants returns distinct variants without duplicates', () {
      final variants = imageHeaderVariants(
        'https://rx.resmk.org/covers/8cec924e03c9.webp',
      );
      expect(variants.isNotEmpty, isTrue);
      expect(variants.first['Referer'], 'https://mangabuddy.com/');
      expect(variants.any((v) => v['Referer'] == 'https://rx.resmk.org/'), isTrue);
      expect(variants.any((v) => !v.containsKey('Referer')), isTrue);
    });
  });

  group('LibraryRepository Cloud Cover Recovery', () {
    test('downloadLibraryBookmarks adopts coverFallback when cloud cover is empty', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final repo = LibraryRepository();
      await repo.init(prefs);

      final client = MockClient((request) async {
        if (request.url.path == '/library') {
          return http.Response(
            jsonEncode({
              'items': [
                {
                  'mangaId': 'ext:eu.kanade.tachiyomi.extension.en.mangabuddy:%2Fblue-lock',
                  'title': 'Blue Lock',
                  'cover': '', // Empty cloud cover!
                  'type': 'manga',
                  'status': 'ongoing',
                  'source': 'MangaBuddy',
                  'latestChapter': 'Chapter 280',
                  'categories': ['Favorites'],
                }
              ]
            }),
            200,
          );
        }
        return http.Response('Not Found', 404);
      });

      await repo.downloadLibraryBookmarks(
        client,
        'http://localhost:3000',
        {},
        coverFallback: (id) => 'https://rx.resmk.org/covers/recovered.webp',
      );

      final items = repo.getLibraryItems();
      expect(items.length, 1);
      expect(items.first.cover, 'https://rx.resmk.org/covers/recovered.webp');
    });
  });
}

