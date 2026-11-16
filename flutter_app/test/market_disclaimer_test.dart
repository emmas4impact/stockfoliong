import 'package:flutter/material.dart';
import 'package:flutter_app/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const disclaimer = 'Stockfolio NG highlights data-driven watchlist ideas only. '
      'It is not a financial adviser app. Contact your broker for detailed analysis.';
  for (final width in [320.0, 1100.0]) {
    for (final brightness in Brightness.values) {
      testWidgets('bold disclaimer wraps at $width in $brightness', (tester) async {
        await tester.binding.setSurfaceSize(Size(width, 1000));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(MaterialApp(
          theme: ThemeData(brightness: brightness),
          home: Scaffold(body: MediaQuery(
            data: MediaQueryData(size: Size(width, 1000), textScaler: TextScaler.linear(1.5)),
            child: SingleChildScrollView(child: MarketIdeasPanel(
              bundle: MarketIdeasBundle.fromJson({'disclaimer': disclaimer}),
            )),
          )),
        ));
        final text = tester.widget<Text>(find.text(disclaimer));
        expect(text.style?.fontWeight, FontWeight.w700);
        expect(text.style?.fontSize, 16);
        expect(text.maxLines, isNull);
        final notice = find.byKey(const ValueKey('market-ideas-disclaimer'));
        final bounds = tester.getRect(notice);
        final textBounds = tester.getRect(find.text(disclaimer));
        expect(textBounds.left, greaterThanOrEqualTo(bounds.left));
        expect(textBounds.right, lessThanOrEqualTo(bounds.right));
        expect(textBounds.bottom, lessThanOrEqualTo(bounds.bottom));
        expect(tester.takeException(), isNull);
      });
    }
  }
}
