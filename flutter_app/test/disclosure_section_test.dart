import 'package:flutter/material.dart';
import 'package:flutter_app/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows three filings on mobile; archive expands and collapses', (tester) async {
    await tester.binding.setSurfaceSize(const Size(375, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final filings = List.generate(5, (i) => DisclosureItem(title: 'Filing $i'));
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(
      child: DisclosureSection(filings: filings, offers: const [], loading: false),
    ))));
    expect(find.text('IPOs & share offers'), findsNothing);
    expect(find.text('Filing 2'), findsOneWidget);
    expect(find.text('Filing 3'), findsNothing);
    await tester.tap(find.text('View all (5)'));
    await tester.pump();
    expect(find.text('Filing 4'), findsOneWidget);
    await tester.tap(find.text('Show less'));
    await tester.pump();
    expect(find.text('Filing 4'), findsNothing);
  });

  testWidgets('renders a confirmed rights issue above filings', (tester) async {
    final offers = MarketOffer.parseList([{
      'name': 'Example PLC', 'kind': 'Rights issue', 'status': 'Upcoming',
      'next_date': '2026-11-20', 'url': 'https://www.invest.ngxgroup.com/',
    }]);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: DisclosureSection(
      filings: const [], offers: offers, loading: false,
    ))));
    expect(find.textContaining('Opens Nov 20, 2026'), findsOneWidget);
    expect(tester.getTopLeft(find.text('Example PLC')).dy,
        lessThan(tester.getTopLeft(find.text('Recent disclosures')).dy));
  });
}
