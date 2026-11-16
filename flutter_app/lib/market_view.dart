part of 'main.dart';

class OpeningMoves extends StatelessWidget {
  const OpeningMoves({super.key, required this.stocks});
  final List<Stock> stocks;
  @override
  Widget build(BuildContext context) {
    final moves = {
      for (final s in stocks)
        if ((s.openPrice ?? 0) > 0 && (s.lastPrice ?? 0) > 0)
          s.symbol: (s.lastPrice! - s.openPrice!) * 100 / s.openPrice!,
    };
    if (moves.isEmpty) return const SizedBox.shrink();
    final scale = moves.values.fold(0.01, (a, b) => max(a, b.abs()));
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Change since open', style: theme.textTheme.titleLarge),
          const SizedBox(height: 8),
          ColoredBox(
            color: theme.colorScheme.surface,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                children: [
                  for (final m in moves.entries)
                    Row(
                      children: [
                        SizedBox(
                          width: 100,
                          child: Text(
                            m.key,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelMedium,
                          ),
                        ),
                        Expanded(
                          child: LayoutBuilder(
                            builder: (_, box) => SizedBox(
                              height: 24,
                              child: Stack(
                                alignment: Alignment.center,
                                children: [
                                  Container(
                                    width: 1,
                                    color: theme.colorScheme.outlineVariant,
                                  ),
                                  Positioned(
                                    left:
                                        box.maxWidth / 2 -
                                        (m.value < 0
                                            ? box.maxWidth /
                                                  2 *
                                                  m.value.abs() /
                                                  scale
                                            : 0),
                                    width:
                                        box.maxWidth /
                                        2 *
                                        m.value.abs() /
                                        scale,
                                    child: Container(
                                      height: 7,
                                      color: m.value < 0
                                          ? theme.colorScheme.error
                                          : theme.colorScheme.primary,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        SizedBox(width: 72, child: _HoldingReturn(m.value)),
                      ],
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class MarketLeadersBoard extends StatelessWidget {
  const MarketLeadersBoard({
    super.key,
    required this.movers,
    required this.losers,
    required this.onStockTap,
  });
  final List<Stock> movers, losers;
  final ValueChanged<Stock> onStockTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget group(String label, IconData icon, List<Stock> rows, Color accent) =>
        Material(
          color: theme.colorScheme.surface,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
                child: Row(
                  children: [
                    Icon(icon, size: 18, color: accent),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(label, style: theme.textTheme.titleMedium),
                    ),
                  ],
                ),
              ),
              if (rows.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('No quotes available.'),
                ),
              for (final stock in rows) ...[
                const Divider(height: 1),
                InkWell(
                  onTap: () => onStockTap(stock),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    child: Row(
                      children: [
                        CompanyLogo(
                          symbol: stock.symbol,
                          size: 30,
                          useInitials: true,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          flex: 3,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                stock.symbol,
                                style: theme.textTheme.titleSmall,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              Text(
                                stock.name ?? '',
                                style: theme.textTheme.bodySmall,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          flex: 2,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text(_amount(stock.lastPrice)),
                              ),
                              _HoldingReturn(stock.percentChange),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        );
    final gainers = group(
      'Top gainers',
      Icons.trending_up,
      movers,
      theme.colorScheme.primary,
    );
    final decliners = group(
      'Top losers',
      Icons.trending_down,
      losers,
      theme.colorScheme.error,
    );
    return LayoutBuilder(
      builder: (_, box) => box.maxWidth >= 640
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: gainers),
                const SizedBox(width: 16),
                Expanded(child: decliners),
              ],
            )
          : Column(children: [gainers, const SizedBox(height: 12), decliners]),
    );
  }
}
