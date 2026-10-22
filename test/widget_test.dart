import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:manga_reader/main.dart';
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
    await tester.pump(const Duration(milliseconds: 2500));
    await tester.pumpAndSettle();
  }

  testWidgets('Library tab renders with empty state', (tester) async {
    await boot(tester);
    expect(find.text('Library'), findsWidgets);
    expect(find.text('Your library is empty'), findsOneWidget);
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
    expect(find.text('No recent updates'), findsOneWidget);
  });

  testWidgets('Browse tab renders', (tester) async {
    await boot(tester);
    await tester.tap(find.text('Browse'));
    await tester.pumpAndSettle();
    expect(find.text('Browse'), findsWidgets);
  });

  testWidgets('More tab renders with clean auth card & settings', (tester) async {
    await boot(tester);
    await tester.tap(find.text('More'));
    await tester.pumpAndSettle();
    expect(find.text('Guest User'), findsOneWidget);
    expect(find.text('Sign In / Create Account'), findsOneWidget);
    expect(find.text('Extensions'), findsOneWidget);
  });
}
