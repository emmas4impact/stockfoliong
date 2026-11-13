import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_app/financials.dart';
import 'package:flutter_app/main.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> statement(int year, {int? quarter}) => {
  'period_key': '$year:${quarter ?? 0}',
  'fiscal_year': year,
  'quarter': quarter,
  'basis': quarter == null ? 'annual' : 'year_to_date',
  'scope': 'consolidated',
  'currency': 'NGN',
  'audited': quarter == null,
  'period_start': '$year-01-01',
  'period_end': '$year-${quarter == null ? '12' : '09'}-30',
  'source_title': 'Reviewed financial statement',
  'source_url': 'https://example.com/report.pdf',
  'metrics': {
    'revenue': year == 2025 ? 1200000000 : 1000000000,
    'net_profit': 400000000,
    'eps': 4.28,
    'total_assets': 52000000000,
    'total_liabilities': 48000000000,
    'total_equity': 4000000000,
  },
  'yoy': {'revenue': 20.0, 'net_profit': -5.3, 'total_liabilities': 24.87},
};

FinancialsData fixture() => FinancialsData.fromJson({
  'valuation': {
    'pb_ratio': .41,
    'pe_ratio': 5.6,
    'eps': 4.28,
    'observed_at': '2026-11-12T10:00:00Z',
    'provider_updated_at': '2026-11-01T10:00:00Z',
    'freshness': 'stale',
  },
  'statements': [statement(2025), statement(2024), statement(2025, quarter: 3)],
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    const fonts = String.fromEnvironment('FINANCIALS_FONT_DIR');
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
  test('old API response still decodes and report links are deduplicated', () {
    expect(
      StockDetailBundle.fromJson({
        'stock': {'symbol': 'TEST'},
      }).financials.statements,
      isEmpty,
    );
    final reports = financialReportLinks([
      DisclosureItem(
        category: 'Financial Statements',
        url: 'https://example.com/report.pdf',
      ),
      DisclosureItem(
        category: 'Financial Statements',
        url: 'https://example.com/report.pdf',
      ),
      DisclosureItem(
        category: 'Financial Statements',
        url: 'javascript:alert(1)',
      ),
      DisclosureItem(
        category: 'DirectorsDealings',
        url: 'https://example.com/deal.pdf',
      ),
    ]);
    expect(reports, hasLength(1));
    expect(reports.single.title, 'Financial statement');
  });

  for (final width in [360.0, 1280.0]) {
    testWidgets('periods, source and responsive layout at $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      String? opened;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            useMaterial3: true,
            colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
          ),
          home: FinancialsView(
            symbol: 'TEST',
            data: fixture(),
            reports: const [],
            onOpenReport: (url) => opened = url,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('0.41x'), findsOneWidget);
      expect(find.textContaining('Stale'), findsOneWidget);
      expect(find.text('FY-2025'), findsOneWidget);
      expect(find.text('NGN 1.2B'), findsOneWidget);
      if (const bool.fromEnvironment('FINANCIALS_PREVIEWS')) {
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('/tmp/financials-$width.png'),
        );
      }
      await tester.tap(find.text('FY-2024'));
      await tester.pumpAndSettle();
      expect(find.text('NGN 1B'), findsOneWidget);
      await tester.tap(find.text('Quarterly'));
      await tester.pumpAndSettle();
      expect(find.text('Q3-2025 YTD'), findsOneWidget);
      expect(find.textContaining('Year to date'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Reviewed financial statement'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reviewed financial statement'));
      expect(opened, 'https://example.com/report.pdf');
      expect(tester.takeException(), isNull);
    });

    testWidgets('opens and closes financials at $width', (tester) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: EarningsFinancialsSection(
              symbol: 'TEST',
              data: fixture(),
              reports: const [],
              onOpenReport: (_) {},
            ),
          ),
        ),
      );
      await tester.tap(
        find.widgetWithText(OutlinedButton, 'Earnings & financials'),
      );
      await tester.pumpAndSettle();
      expect(find.byType(FinancialsView), findsOneWidget);
      expect(find.byType(Dialog), width < 700 ? findsNothing : findsOneWidget);
      await tester.tap(find.byTooltip('Close financials'));
      await tester.pumpAndSettle();
      expect(find.byType(FinancialsView), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('missing statements never create periods or zero financials', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: FinancialsView(
          symbol: 'EMPTY',
          data: const FinancialsData(),
          reports: const [],
          onOpenReport: (_) {},
        ),
      ),
    );
    expect(find.text('Valuation data unavailable.'), findsOneWidget);
    expect(
      find.text('No reviewed annual statements available.'),
      findsOneWidget,
    );
    expect(find.byType(ChoiceChip), findsNothing);
    await tester.tap(find.text('Quarterly'));
    await tester.pumpAndSettle();
    expect(
      find.text('No reviewed quarterly statements available.'),
      findsOneWidget,
    );
  });

  testWidgets('loading and failure do not masquerade as missing values', (
    tester,
  ) async {
    Widget page({bool loading = false, bool failed = false}) => MaterialApp(
      home: Scaffold(
        body: EarningsFinancialsSection(
          symbol: 'TEST',
          data: const FinancialsData(),
          reports: const [],
          onOpenReport: (_) {},
          loading: loading,
          failed: failed,
        ),
      ),
    );
    await tester.pumpWidget(page(loading: true));
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.byType(OutlinedButton), findsNothing);
    await tester.pumpWidget(page(failed: true));
    expect(find.text('Financials could not be loaded.'), findsOneWidget);
  });
}
