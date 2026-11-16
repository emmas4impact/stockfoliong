import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_app/main.dart';

void main() {
  for (final width in [320.0, 800.0]) {
    for (final scale in [1.0, 1.5]) {
      for (final range in ['1M', '6M', '1Y', 'ALL']) {
        testWidgets('date labels stay inside $width / $scale / $range', (
          tester,
        ) async {
          SharedPreferences.setMockInitialValues({});
          await tester.binding.setSurfaceSize(const Size(1000, 1000));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          final count = switch (range) {
            '1M' => 30,
            '6M' => 180,
            _ => 365,
          };
          await tester.pumpWidget(
            MaterialApp(
              home: MediaQuery(
                data: MediaQueryData(textScaler: TextScaler.linear(scale)),
                child: Scaffold(
                  body: SingleChildScrollView(
                    child: Center(
                      child: SizedBox(
                        width: width,
                        child: PriceChart(
                          rangeLabel: range,
                          symbolLabel: 'ACCESSCORP',
                          showSummaryMetrics: false,
                          points: List.generate(
                            count,
                            (i) => PricePoint(
                              date: DateTime(
                                2025,
                                11,
                                17,
                              ).add(Duration(days: i)),
                              open: 22,
                              high: 30,
                              low: 20,
                              close: 25 + i % 5,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();

          void checkLabels() {
            expect(tester.takeException(), isNull);
            final plot = tester.getRect(
              find.byKey(const ValueKey('price-chart-plot')),
            );
            final labels = find.descendant(
              of: find.byType(SideTitleWidget),
              matching: find.byType(Text),
            );
            expect(labels, findsWidgets);
            for (final label in labels.evaluate()) {
              final bounds = tester.getRect(find.byWidget(label.widget));
              expect(bounds.left, greaterThanOrEqualTo(plot.left + 4));
              expect(bounds.right, lessThanOrEqualTo(plot.right - 4));
              expect(bounds.bottom, lessThanOrEqualTo(plot.bottom - 4));
            }
          }

          checkLabels();
          await tester.tap(find.text('Bar'));
          await tester.pumpAndSettle();
          expect(find.byType(BarChart), findsOneWidget);
          checkLabels();
        });
      }
    }
  }
}
