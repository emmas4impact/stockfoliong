part of 'main.dart';

final _naira = NumberFormat.currency(
  locale: 'en_NG',
  symbol: '₦',
  decimalDigits: 2,
);
final _shares = NumberFormat('#,##0.####', 'en_NG');
String _amount(double? value) =>
    value == null ? 'Quote pending' : _naira.format(value);
String _signedPercent(double percent) =>
    '${percent > 0 ? '+' : ''}${percent.toStringAsFixed(2)}%';

class PortfolioSummaryStrip extends StatelessWidget {
  const PortfolioSummaryStrip({
    super.key,
    required this.totals,
    required this.hidden,
    required this.togglePrivacy,
  });
  final PortfolioTotals totals;
  final bool hidden;
  final VoidCallback togglePrivacy;

  @override
  Widget build(BuildContext context) {
    const muted = Color(0xffc1d7d0);
    Widget metric(String label, double? value, {bool primary = false}) =>
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: const TextStyle(color: muted, fontSize: 13)),
            const SizedBox(height: 6),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                hidden ? '•••••' : _amount(value),
                style: TextStyle(
                  fontSize: primary ? 36 : 23,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
            ),
          ],
        );
    final value = metric('Portfolio value', totals.value, primary: true);
    final invested = metric('Amount invested', totals.invested);
    final profit = metric('Unrealized return', totals.profit);
    final percent = totals.percent;
    return Container(
      padding: const EdgeInsets.fromLTRB(22, 12, 22, 22),
      decoration: BoxDecoration(
        color: const Color(0xff123d36),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(
                Icons.account_balance_wallet_outlined,
                size: 18,
                color: muted,
              ),
              const SizedBox(width: 9),
              const Expanded(
                child: Text(
                  'Portfolio overview',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (!hidden && percent != null)
                Text(
                  'Return ${_signedPercent(percent)}',
                  semanticsLabel: 'Portfolio return ${_signedPercent(percent)}',
                  style: TextStyle(
                    color: percent < 0
                        ? const Color(0xffffb8ba)
                        : const Color(0xff9ce5c1),
                    fontWeight: FontWeight.bold,
                  ),
                ),
              IconButton(
                onPressed: togglePrivacy,
                tooltip: hidden ? 'Reveal totals' : 'Hide totals',
                icon: Icon(
                  hidden
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                  size: 19,
                  color: muted,
                ),
              ),
            ],
          ),
          const Divider(height: 20, color: Color(0xff44665e)),
          LayoutBuilder(
            builder: (context, box) {
              if (box.maxWidth >= 660) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(flex: 4, child: value),
                    const SizedBox(width: 20),
                    Expanded(flex: 3, child: invested),
                    const SizedBox(width: 20),
                    Expanded(flex: 3, child: profit),
                  ],
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  value,
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(child: invested),
                      const SizedBox(width: 12),
                      Expanded(child: profit),
                    ],
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class HoldingsLedger extends StatelessWidget {
  const HoldingsLedger({
    super.key,
    required this.holdings,
    required this.selectedSymbol,
    required this.onSelect,
    required this.onEdit,
    required this.onDelete,
    required this.onAdd,
  });
  final List<Holding> holdings;
  final String? selectedSymbol;
  final ValueChanged<Holding> onSelect, onEdit;
  final ValueChanged<String> onDelete;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final small = theme.textTheme.bodySmall!.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final strong = theme.textTheme.titleSmall!.copyWith(
      fontWeight: FontWeight.w700,
    );
    Widget numeric(String value, TextStyle? style) => Align(
      alignment: Alignment.centerRight,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(value, style: style),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Holdings (${holdings.length})',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            FilledButton.icon(
              onPressed: onAdd,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add holding'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (holdings.isEmpty)
          const EmptyState(
            icon: Icons.account_balance_wallet_outlined,
            text: 'No holdings yet.',
          )
        else
          Material(
            color: scheme.surface,
            child: LayoutBuilder(
              builder: (context, box) {
                final wide = box.maxWidth >= 550;
                Widget columns(
                  Widget stock,
                  Widget cost,
                  Widget value,
                  Widget change,
                  Widget actions,
                ) => Row(
                  children: [
                    Expanded(flex: 5, child: stock),
                    const SizedBox(width: 8),
                    if (wide) ...[
                      Expanded(flex: 3, child: cost),
                      const SizedBox(width: 8),
                    ],
                    Expanded(flex: wide ? 3 : 4, child: value),
                    if (wide) ...[
                      const SizedBox(width: 8),
                      Expanded(flex: 2, child: change),
                    ],
                    SizedBox(width: 42, child: actions),
                  ],
                );
                return Column(
                  children: [
                    Container(
                      color: scheme.surfaceContainerHigh,
                      padding: const EdgeInsets.symmetric(
                        vertical: 9,
                        horizontal: 12,
                      ),
                      child: columns(
                        Text('Stock', style: small),
                        numeric('Invested', small),
                        numeric(
                          wide ? 'Market value' : 'Value / return',
                          small,
                        ),
                        numeric('Return', small),
                        const SizedBox(),
                      ),
                    ),
                    for (final h in holdings) ...[
                      Ink(
                        color: selectedSymbol == h.symbol
                            ? scheme.primaryContainer.withValues(alpha: .5)
                            : null,
                        child: InkWell(
                          onTap: () => onSelect(h),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              vertical: 12,
                              horizontal: 12,
                            ),
                            child: columns(
                              Row(
                                children: [
                                  CompanyLogo(symbol: h.symbol, size: 32, useInitials: true),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          h.symbol,
                                          style: strong,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        if (h.name != null)
                                          Text(
                                            h.name!,
                                            style: small,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        Text(
                                          '${_shares.format(h.quantity)} shares',
                                          style: small,
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                              numeric(
                                _amount(h.totalCost),
                                theme.textTheme.bodyMedium,
                              ),
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  numeric(_amount(h.totalValue), strong),
                                  if (!wide)
                                    _HoldingReturn(h.profitLossPercent),
                                ],
                              ),
                              _HoldingReturn(h.profitLossPercent),
                              PopupMenuButton<String>(
                                tooltip: 'Actions for ${h.symbol}',
                                icon: const Icon(Icons.more_vert, size: 20),
                                onSelected: (v) => v == 'edit'
                                    ? onEdit(h)
                                    : onDelete(h.symbol),
                                itemBuilder: (_) => const [
                                  PopupMenuItem(
                                    value: 'edit',
                                    child: Text('Edit holding'),
                                  ),
                                  PopupMenuItem(
                                    value: 'delete',
                                    child: Text('Delete holding'),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                      Divider(height: 1, color: scheme.outlineVariant),
                    ],
                  ],
                );
              },
            ),
          ),
      ],
    );
  }
}

class _HoldingReturn extends StatelessWidget {
  const _HoldingReturn(this.percent);
  final double? percent;
  @override
  Widget build(BuildContext context) {
    final value = percent;
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final color = value == null || value == 0
        ? theme.colorScheme.onSurfaceVariant
        : value < 0
        ? (dark ? Colors.red.shade200 : Colors.red.shade800)
        : (dark ? Colors.tealAccent.shade100 : Colors.teal.shade800);
    return Align(
      alignment: Alignment.centerRight,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(
          value == null ? 'N/A' : _signedPercent(value),
          style: theme.textTheme.labelLarge?.copyWith(
            color: color,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }
}

class PortfolioAllocation extends StatelessWidget {
  const PortfolioAllocation({super.key, required this.holdings});
  final List<Holding> holdings;
  static const colors = [
    Color(0xff18836c),
    Color(0xff557cb9),
    Color(0xffce9340),
    Color(0xffa76992),
    Color(0xff838f96),
  ];

  @override
  Widget build(BuildContext context) {
    final sorted = holdings.where((h) => h.totalCost > 0).toList()
      ..sort((a, b) => b.totalCost.compareTo(a.totalCost));
    final slices = [
      for (final h in sorted.take(sorted.length > 5 ? 4 : 5)) (h.symbol, h.totalCost),
      if (sorted.length > 5)
        (
          'Other holdings',
          sorted.skip(4).fold<double>(0, (a, h) => a + h.totalCost),
        ),
    ];
    final total = slices.fold<double>(0, (v, s) => v + s.$2);
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Invested allocation',
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 12),
        if (slices.isEmpty)
          const Text('No invested capital yet.')
        else
          Container(
            color: theme.colorScheme.surface,
            padding: const EdgeInsets.all(18),
            child: Column(
              children: [
                SizedBox.square(
                  dimension: 168,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      ExcludeSemantics(
                        child: PieChart(
                          PieChartData(
                            startDegreeOffset: -90,
                            centerSpaceRadius: 58,
                            sectionsSpace: slices.length > 1 ? 2 : 0,
                            pieTouchData: PieTouchData(enabled: false),
                            sections: [
                              for (final (i, s) in slices.indexed)
                                PieChartSectionData(
                                  value: s.$2,
                                  radius: 24,
                                  color: colors[i],
                                  showTitle: false,
                                ),
                            ],
                          ),
                        ),
                      ),
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '${holdings.length}',
                            style: theme.textTheme.headlineMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          Text(
                            holdings.length == 1 ? 'holding' : 'holdings',
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                for (final (i, s) in slices.indexed)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    child: Row(
                      children: [
                        Container(width: 10, height: 10, color: colors[i]),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(s.$1, style: theme.textTheme.labelLarge),
                        ),
                        Text(
                          '${(100 * s.$2 / total).toStringAsFixed(1)}%',
                          style: theme.textTheme.labelLarge,
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}
