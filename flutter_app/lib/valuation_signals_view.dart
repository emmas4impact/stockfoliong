part of 'main.dart';

enum _SignalStyle {
  buy(
    'Buy',
    Icons.trending_up,
    Color(0xff006841),
    Colors.white,
    Color(0xff68dfab),
  ),
  hold(
    'Hold',
    Icons.trending_flat,
    Color(0xffccedaa),
    Color(0xff284a18),
    Color(0xffc5e79e),
  ),
  sell(
    'Sell',
    Icons.trending_down,
    Color(0xffaf2d38),
    Colors.white,
    Color(0xffff969d),
  );

  const _SignalStyle(this.label, this.icon, this.fill, this.ink, this.darkInk);
  final String label;
  final IconData icon;
  final Color fill, ink, darkInk;
}

class _ValuationSignals extends StatefulWidget {
  const _ValuationSignals({required this.signals, required this.insufficient, this.onSelect});
  final List<ValuationSignal> signals;
  final List<PeerShortfall> insufficient;
  final ValueChanged<Stock>? onSelect;
  @override
  State<_ValuationSignals> createState() => _ValuationSignalsState();
}

class _ValuationSignalsState extends State<_ValuationSignals> {
  String? selection;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = _SignalStyle.values.firstWhere(
      (s) => s.label == (selection ?? widget.signals.firstOrNull?.label),
      orElse: () => _SignalStyle.buy,
    );
    final rows = widget.signals.where((s) => s.label == style.label);
    return Material(
      color: theme.colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Valuation signals',
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.info_outline, size: 20),
                  tooltip: 'Valuation methodology',
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: const Text('Valuation methodology'),
                      content: const Text(
                        'Buy: both P/E and P/B are at least 20% below sector peer medians. '
                        'Sell: both are at least 20% above. Hold: neither condition. '
                        'Only verified company shares with current positive ratios and at least three other '
                        'qualifying company shares in their sector receive a signal. Research only.',
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: const Text('Close'),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final option in _SignalStyle.values)
                  ChoiceChip(
                    label: Text(option.label),
                    selected: option == style,
                    showCheckmark: false,
                    avatar: Icon(
                      option.icon,
                      size: 18,
                      color: option == style
                          ? option.ink
                          : theme.brightness == Brightness.dark
                          ? option.darkInk
                          : option == _SignalStyle.hold
                          ? option.ink
                          : option.fill,
                    ),
                    selectedColor: option.fill,
                    backgroundColor: theme.colorScheme.surface,
                    labelStyle: theme.textTheme.labelLarge?.copyWith(
                      color: option == style
                          ? option.ink
                          : theme.colorScheme.onSurface,
                      fontWeight: FontWeight.w700,
                    ),
                    side: BorderSide(
                      color: option == style
                          ? option.fill
                          : theme.colorScheme.outlineVariant,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(6),
                    ),
                    onSelected: (_) => setState(() => selection = option.label),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            LayoutBuilder(
              builder: (context, box) {
                final wide =
                    box.maxWidth >=
                    640 * MediaQuery.textScalerOf(context).scale(1);
                final caption = theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                );
                return Column(
                  children: [
                    if (wide && rows.isNotEmpty)
                      ColoredBox(
                        color: theme.colorScheme.surfaceContainerLow,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          child: _QuoteColumns(
                            cells: [
                              for (final h in [
                                'Stock / sector',
                                'P/E',
                                'P/B',
                                'Coverage',
                              ])
                                Text(
                                  h,
                                  style: caption,
                                  textAlign: h == 'Stock / sector'
                                      ? TextAlign.start
                                      : TextAlign.end,
                                ),
                            ],
                          ),
                        ),
                      ),
                    if (rows.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 20),
                        child: Text(
                          widget.signals.isEmpty
                              ? 'No signals with sufficient current peer data.'
                              : 'No qualifying ${style.label.toLowerCase()} signals.',
                          style: caption,
                        ),
                      ),
                    for (final row in rows) ...[
                      InkWell(
                        onTap: widget.onSelect == null
                            ? null
                            : () => widget.onSelect!(
                                Stock(symbol: row.symbol, sector: row.sector),
                              ),
                        child: Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: wide ? 12 : 0,
                            vertical: 14,
                          ),
                          child: Builder(
                            builder: (_) {
                              final identity = Row(
                                children: [
                                  CompanyLogo(
                                    symbol: row.symbol,
                                    size: 40,
                                    showFullMark: true,
                                    useInitials: true,
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          row.symbol,
                                          style: theme.textTheme.titleSmall
                                              ?.copyWith(
                                                fontWeight: FontWeight.w700,
                                              ),
                                        ),
                                        Text(row.sector, style: caption),
                                      ],
                                    ),
                                  ),
                                ],
                              );
                              final date = DateFormat.yMMMd().format(row.asOf);
                              Widget metric(
                                String name,
                                double value,
                                double median,
                              ) => Column(
                                crossAxisAlignment: wide
                                    ? CrossAxisAlignment.end
                                    : CrossAxisAlignment.start,
                                children: [
                                  if (!wide) Text(name, style: caption),
                                  Text(
                                    '${value.toStringAsFixed(2)}x',
                                    style: theme.textTheme.titleMedium
                                        ?.copyWith(
                                          fontWeight: FontWeight.w700,
                                          fontFeatures: const [
                                            FontFeature.tabularFigures(),
                                          ],
                                        ),
                                  ),
                                  Text(
                                    'Median ${median.toStringAsFixed(2)}x',
                                    style: caption,
                                  ),
                                ],
                              );
                              if (wide)
                                return _QuoteColumns(
                                  cells: [
                                    identity,
                                    metric('P/E', row.pe, row.peerPe),
                                    metric('P/B', row.pb, row.peerPb),
                                    Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.end,
                                      children: [
                                        Text(
                                          '${row.peerCount} peers',
                                          style: theme.textTheme.bodyMedium,
                                        ),
                                        Text(date, style: caption),
                                      ],
                                    ),
                                  ],
                                );
                              return Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  identity,
                                  const SizedBox(height: 10),
                                  Row(
                                    children: [
                                      Expanded(
                                        child: metric(
                                          'P/E',
                                          row.pe,
                                          row.peerPe,
                                        ),
                                      ),
                                      Expanded(
                                        child: metric(
                                          'P/B',
                                          row.pb,
                                          row.peerPb,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    '${row.peerCount} sector peers · $date',
                                    style: caption,
                                  ),
                                ],
                              );
                            },
                          ),
                        ),
                      ),
                      Divider(
                        height: 1,
                        color: theme.colorScheme.outlineVariant,
                      ),
                    ],
                  ],
                );
              },
            ),
            if (widget.insufficient.isNotEmpty)
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: Text('Insufficient peers (${widget.insufficient.length})'),
                children: [
                  for (final item in widget.insufficient)
                    ListTile(
                      leading: CompanyLogo(symbol: item.symbol, size: 36, useInitials: true, showFullMark: true),
                      title: Text(item.symbol),
                      subtitle: Text('${item.sector} · ${item.peers} of ${item.requiredPeers} required peers'),
                      onTap: widget.onSelect == null ? null : () =>
                          widget.onSelect!(Stock(symbol: item.symbol, sector: item.sector)),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _QuoteColumns extends StatelessWidget {
  const _QuoteColumns({required this.cells});
  final List<Widget> cells;
  @override
  Widget build(BuildContext context) => Row(
    children: [
      for (var i = 0; i < cells.length; i++)
        Expanded(flex: i == 0 ? 4 : 2, child: cells[i]),
    ],
  );
}
