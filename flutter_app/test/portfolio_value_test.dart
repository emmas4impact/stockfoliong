import 'package:flutter_app/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('missing share quote never becomes zero value or zero return', () {
    final data = {
      'stock_symbol': 'ACCESSCORP',
      'quantity': 166350,
      'avg_purchase_price': 21.959,
      'total_cost': 3652879.65,
      'current_price': null,
      'total_value': 0,
      'profit_loss': 0,
      'profit_loss_percent': 0,
    };
    final pending = Holding.fromJson(data);
    expect(portfolioAmount(pending.totalValue), 'Quote pending');
    expect(portfolioPercent(pending.profitLossPercent), 'Not available');
    expect(pending.profitLoss, isNull);
    final priced = Holding.fromJson({
      ...data,
      'current_price': 27,
      'total_value': 4491450,
      'profit_loss': 838570.35,
      'profit_loss_percent': 22.96,
    });
    final totals = PortfolioTotals([priced]);
    expect(totals.value, 4491450);
    expect(totals.profit, closeTo(838570.35, 0.01));
    expect(PortfolioTotals([pending, priced]).value, isNull);
  });
}
