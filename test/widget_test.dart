import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:manga_reader/main.dart';
import 'package:manga_reader/screens/reader_screen.dart';
import 'package:manga_reader/services/api_service.dart';

void main() {
  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    await ApiService.instance.init();
  });

  Future<void> boot(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const ShioriApp());
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('Library → Detail → Reader', (tester) async {
    await boot(tester);
    expect(find.text('Library'), findsWidgets);

    await tester.tap(find.byType(InkWell).at(6));
    await tester.pumpAndSettle();
    expect(find.text('Resume Ch. 142'), findsOneWidget);

    await tester.tap(find.text('Resume Ch. 142'));
    await tester.pumpAndSettle();
    expect(find.byType(ReaderScreen), findsOneWidget);
  });

  testWidgets('Display sheet opens and changes columns/mode', (tester) async {
    await boot(tester);
    await tester.tap(find.byTooltip('Filter, sort and display'));
    await tester.pumpAndSettle();
    expect(find.text('Display mode'.toUpperCase()), findsOneWidget);

    await tester.tap(find.text('List'));
    await tester.pumpAndSettle();
  });

  testWidgets('Updates tab renders', (tester) async {
    await boot(tester);
    await tester.tap(find.text('Updates'));
    await tester.pumpAndSettle();
    expect(find.text('Solo Leveling: Ragnarok'), findsOneWidget);
  });

  testWidgets('Browse tab renders', (tester) async {
    await boot(tester);
    await tester.tap(find.text('Browse'));
    await tester.pumpAndSettle();
    expect(find.text('Browse'), findsWidgets);
  });

  testWidgets('More tab renders with auth & settings', (tester) async {
    await boot(tester);
    await tester.tap(find.text('More'));
    await tester.pumpAndSettle();
    expect(find.text('Guest User'), findsOneWidget);
    expect(find.text('MongoDB Status'), findsOneWidget);
  });
}
