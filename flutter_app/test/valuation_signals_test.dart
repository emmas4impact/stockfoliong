import 'package:flutter/material.dart';
import 'package:flutter_app/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final width in [360.0, 1100.0]) {
    testWidgets('Home valuation layout and signals at $width', (tester) async {
      await tester.binding.setSurfaceSize(Size(width, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final bundle = MarketIdeasBundle.fromJson({
        'valuation_signals': [
          for (final label in ['Buy', 'Hold', 'Sell'])
            {
              'signal': label,
              'symbol': label.toUpperCase(),
              'sector': 'Banks',
              'peer_count': 3,
              'pe': 5,
              'pb': 1,
              'peer_pe': 8,
              'peer_pb': 2,
              'as_of': '2026-11-14T00:00:00Z',
            },
        ],
      });
      String? selectedStock;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MarketIdeasPanel(
              bundle: bundle,
              onSelect: (stock) => selectedStock = stock.symbol,
            ),
          ),
        ),
      );
      for (final label in ['Buy', 'Hold', 'Sell']) {
        await tester.tap(find.text(label));
        await tester.pumpAndSettle();
        expect(find.text(label.toUpperCase()), findsOneWidget);
        expect(find.text('5.00x'), findsOneWidget);
        expect(find.text('Median 2.00x'), findsOneWidget);
        expect(
          find.text('Coverage'),
          width >= 640 ? findsOneWidget : findsNothing,
        );
        final chip = tester.widget<ChoiceChip>(
          find.widgetWithText(ChoiceChip, label),
        );
        expect(chip.selected, isTrue);
        expect(
          chip.selectedColor,
          {
            'Buy': const Color(0xff006841),
            'Hold': const Color(0xffccedaa),
            'Sell': const Color(0xffaf2d38),
          }[label],
        );
        await tester.tap(find.text(label.toUpperCase()));
        expect(selectedStock, label.toUpperCase());
        expect(tester.takeException(), isNull);
      }
    });
  }
}
