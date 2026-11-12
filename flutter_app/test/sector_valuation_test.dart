import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_app/sector_valuation.dart';
import 'package:flutter_test/flutter_test.dart';

SectorValuation sample({double? rank, double? pe = 5.6}) =>
    SectorValuation.fromJson({
      'inputs': {'sector': 'financial services', 'pe_ratio': pe},
      'scores': {'valuation': rank},
      'sector_pe_median': 7.1,
      'peer_count': 4,
      'observed_at': '2026-11-12T08:00:00Z',
      'reasons': ['A positive P/E is unavailable.'],
    });

Widget screen(String symbol, Future<SectorValuation?> Function(String) load) =>
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 260,
          child: SectorValuationSection(symbol: symbol, load: load),
        ),
      ),
    );

void main() {
  testWidgets('wraps metrics, preserves zero rank and changes selected stock', (
    tester,
  ) async {
    final next = Completer<SectorValuation?>();
    final calls = <String>[];
    Future<SectorValuation?> load(String symbol) {
      calls.add(symbol);
      return symbol == 'A' ? Future.value(sample(rank: 0)) : next.future;
    }

    await tester.pumpWidget(screen('A', load));
    await tester.pumpAndSettle();
    expect(find.text('5.60x'), findsOneWidget);
    expect(find.text('0 / 100'), findsOneWidget);
    await tester.pumpWidget(screen('A', load));
    await tester.pumpWidget(screen('B', load));
    expect(find.text('0 / 100'), findsNothing);
    next.complete(sample(pe: null));
    await tester.pumpAndSettle();
    expect(find.text('Not scored'), findsOneWidget);
    expect(find.text('A positive P/E is unavailable.'), findsOneWidget);
    expect(calls, ['A', 'B']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('distinguishes failed requests from a missing observation', (
    tester,
  ) async {
    var attempts = 0;
    await tester.pumpWidget(
      screen('A', (_) async {
        if (++attempts == 1) throw Exception('Offline');
        return null;
      }),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Retry sector valuation'));
    await tester.pumpAndSettle();
    expect(
      find.text('No valuation observation yet for this stock.'),
      findsOneWidget,
    );
    expect(attempts, 2);
  });
}
