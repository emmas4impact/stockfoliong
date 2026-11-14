import 'package:flutter/material.dart';
import 'package:flutter_app/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Home shows ratios and only the selected valuation signal', (tester) async {
    final bundle = MarketIdeasBundle.fromJson({
      'valuation_signals': [
        for (final label in ['Buy', 'Hold', 'Sell'])
          {'signal': label, 'symbol': label.toUpperCase(), 'sector': 'Banks',
           'peer_count': 3, 'pe': 5, 'pb': 1, 'peer_pe': 8, 'peer_pb': 2,
           'as_of': '2026-11-14T00:00:00Z'},
      ],
    });
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: MarketIdeasPanel(bundle: bundle))));
    for (final label in ['Buy', 'Hold', 'Sell']) {
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
      expect(find.text('${label.toUpperCase()} · Banks'), findsOneWidget);
      expect(find.textContaining('P/E 5.00x · P/B 1.00x'), findsOneWidget);
    }
  });
}
