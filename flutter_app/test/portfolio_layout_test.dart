import 'package:flutter/material.dart';
import 'package:flutter_app/main.dart';
import 'package:flutter_app/sector_valuation.dart';
import 'package:flutter_test/flutter_test.dart';

class PortfolioFixture extends ApiClient {
  PortfolioFixture() : super('http://localhost');
  @override
  Future<List<Holding>> holdings() async => [
    for (final (symbol, name, qty, cost, value) in [
      ('GTCO', 'Guaranty Trust Holding Company Plc', 12500, 725000, 851250),
      ('ZENITHBANK', 'Zenith Bank Plc', 5500, 287650, 305250),
      ('CUTIX', 'Cutix Plc', 4000, 16200, 13760),
      ('FIDELITYBK', 'Fidelity Bank Plc', 8200, 145140, 178760),
      ('AIICO', 'AIICO Insurance Plc', 9000, 26100, 31950),
    ])
      Holding(
        symbol: symbol,
        name: name,
        quantity: qty.toDouble(),
        avgPurchasePrice: cost / qty,
        totalCost: cost.toDouble(),
        totalValue: value.toDouble(),
        currentPrice: value / qty,
        profitLoss: (value - cost).toDouble(),
        profitLossPercent: (value - cost) * 100 / cost,
      ),
  ];
  @override
  Future<StockDetailBundle> stockDetail(
    String symbol, {
    String range = '1y',
    int newsLimit = 6,
  }) async => StockDetailBundle.fromJson({
    'stock': {'symbol': symbol},
  });
  @override
  Future<SectorValuation?> sectorValuation(String symbol) async => null;
}

void main() {
  for (final width in [375.0, 1280.0]) {
    testWidgets('portfolio selection and actions at width $width', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(Size(width, 880));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PortfolioScreen(
              api: PortfolioFixture(),
              hideFinancialValues: false,
              onToggleFinancialPrivacy: () async {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('Actions for GTCO'));
      await tester.pumpAndSettle();
      expect(find.text('Edit holding'), findsOneWidget);
      expect(find.text('Delete holding'), findsOneWidget);
      await tester.tapAt(const Offset(4, 4));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(HoldingsLedger),
          matching: find.text('GTCO'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(PortfolioHoldingDetail), findsOneWidget);
      if (width > 960) {
        await tester.tap(find.text('Allocation'));
        await tester.pumpAndSettle();
        expect(find.byType(PortfolioAllocation), findsOneWidget);
      } else {
        expect(find.byType(BottomSheet), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('privacy masks aggregate amounts and percentage', (tester) async {
    final holdings = await PortfolioFixture().holdings();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PortfolioSummaryStrip(
            totals: PortfolioTotals(holdings),
            hidden: true,
            togglePrivacy: () {},
          ),
        ),
      ),
    );
    expect(find.text('•••••'), findsNWidgets(3));
    expect(find.textContaining('%'), findsNothing);
  });
}
