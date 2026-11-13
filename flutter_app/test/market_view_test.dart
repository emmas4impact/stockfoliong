import 'package:flutter/material.dart';
import 'package:flutter_app/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final width in [360.0, 1280.0]) {
    testWidgets(
      'market boards at $width show actual returns and open details',
      (tester) async {
        await tester.binding.setSurfaceSize(Size(width, 740));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final up = Stock.fromJson({
          'symbol': 'EXAMPLE',
          'name': 'Example PLC',
          'open_price': 50.0,
          'last_price': 51.0,
          'percent_change': 1.25,
        });
        final noQuote = Stock.fromJson({'symbol': 'PENDING'});
        Stock? selected;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Column(
                children: [
                  MarketLeadersBoard(
                    movers: [up],
                    losers: [noQuote],
                    onStockTap: (s) => selected = s,
                  ),
                  OpeningMoves(stocks: [up, noQuote]),
                ],
              ),
            ),
          ),
        );
        expect(find.text('+2.00%'), findsOneWidget);
        expect(find.text('+1.25%'), findsOneWidget);
        expect(find.text('PENDING'), findsOneWidget);
        await tester.tap(find.text('Example PLC'));
        expect(selected, same(up));
        expect(tester.takeException(), isNull);
      },
    );
  }
}
