import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_app/main.dart';
import 'package:flutter_test/flutter_test.dart';

Holding holding(String symbol, double change) => Holding(
  symbol: symbol,
  name: symbol,
  quantity: 100,
  avgPurchasePrice: 10,
  totalCost: 1000,
  totalValue: 1000 + change * 10,
  currentPrice: 10 + change / 10,
  profitLoss: change * 10,
  profitLossPercent: change,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    const fonts = String.fromEnvironment('PREVIEW_FONT_DIR');
    if (fonts.isNotEmpty) {
      for (final entry in {
        'Roboto': 'Roboto-Regular.ttf',
        'MaterialIcons': 'MaterialIcons-Regular.otf',
      }.entries) {
        final loader = FontLoader(entry.key)
          ..addFont(
            File(
              '$fonts/${entry.value}',
            ).readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
          );
        await loader.load();
      }
    }
  });
  for (final width in [360.0, 1100.0]) {
    for (final dark in [false, true]) {
      testWidgets('return highlights at $width, dark=$dark', (tester) async {
        tester.view.physicalSize = Size(width, 500);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final theme = ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.teal,
            brightness: dark ? Brightness.dark : Brightness.light,
          ),
        );
        Holding? opened;
        await tester.pumpWidget(
          MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: theme,
            home: Scaffold(
              body: Padding(
                padding: const EdgeInsets.all(16),
                child: HoldingReturnHighlights(
                  highest: holding('GTCO', 177.13),
                  lowest: holding('ELLAHLAKES', -52.25),
                  onSelect: (value) => opened = value,
                ),
              ),
            ),
          ),
        );
        await tester.runAsync(() async {
          await precacheImage(
            const AssetImage('assets/company_logos/GTCO.png'),
            tester.element(find.byType(HoldingReturnHighlights)),
          );
        });
        await tester.pumpAndSettle();
        expect(
          tester.widget<Text>(find.text('-52.25%')).style!.color,
          theme.colorScheme.error,
        );
        expect(
          tester.widget<Text>(find.text('+177.13%')).style!.color,
          dark ? const Color(0xff7cddb2) : const Color(0xff087448),
        );
        final first = tester.getTopLeft(find.text('Highest return'));
        final last = tester.getTopLeft(find.text('Lowest return'));
        expect(width < 620 ? last.dy > first.dy : last.dy == first.dy, isTrue);
        await tester.tap(find.text('ELLAHLAKES'));
        expect(opened!.symbol, 'ELLAHLAKES');
        await tester.pumpAndSettle();
        if (const bool.fromEnvironment('RETURN_PREVIEWS')) {
          await expectLater(
            find.byType(MaterialApp),
            matchesGoldenFile('/tmp/returns-$width-$dark.png'),
          );
        }
        expect(tester.takeException(), isNull);
      });
    }
  }
  testWidgets('color follows the sign, not the ranking, at large text size', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 950);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final theme = ThemeData();
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.8)),
          child: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(16),
              child: HoldingReturnHighlights(
                highest: holding('GTCO', -1),
                lowest: holding('LONGSTOCKSYMBOL', -50),
                onSelect: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(find.text('-1.00%')).style!.color,
      theme.colorScheme.error,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('one holding is not repeated as highest and lowest', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HoldingReturnHighlights(
            highest: holding('GTCO', 0),
            lowest: holding('GTCO', 0),
            onSelect: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Highest return'), findsOneWidget);
    expect(find.text('Lowest return'), findsNothing);
    expect(find.text('0.00%'), findsOneWidget);
  });
}
