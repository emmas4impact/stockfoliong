import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

class FinancialReportLink {
  const FinancialReportLink(this.title, this.url);
  final String title, url;
}

class FinancialStatementData {
  FinancialStatementData.fromJson(Map<String, dynamic> json)
    : key = json['period_key'] as String,
      year = json['fiscal_year'] as int,
      quarter = json['quarter'] as int?,
      basis = json['basis'] as String,
      scope = json['scope'] as String,
      currency = json['currency'] as String,
      audited = json['audited'] as bool,
      end = DateTime.parse(json['period_end'] as String),
      start = DateTime.parse(json['period_start'] as String),
      sourceTitle = json['source_title'] as String,
      sourceUrl = json['source_url'] as String,
      metrics = Map<String, dynamic>.from(json['metrics'] as Map),
      yoy = Map<String, dynamic>.from(json['yoy'] as Map? ?? {});

  final String key, basis, scope, currency, sourceTitle, sourceUrl;
  final int year;
  final int? quarter;
  final bool audited;
  final DateTime start, end;
  final Map<String, dynamic> metrics, yoy;
  bool get annual => basis == 'annual';
  String get label =>
      '${annual ? 'FY' : 'Q$quarter'}-$year'
      '${basis == 'year_to_date' ? ' YTD' : ''}'
      '${scope == 'company' ? ' Company' : ''}';
}

class FinancialsData {
  const FinancialsData({this.valuation, this.statements = const []});
  final Map<String, dynamic>? valuation;
  final List<FinancialStatementData> statements;

  factory FinancialsData.fromJson(Map<String, dynamic> json) => FinancialsData(
    valuation: json['valuation'] as Map<String, dynamic>?,
    statements: (json['statements'] as List? ?? const [])
        .map(
          (item) => FinancialStatementData.fromJson(
            Map<String, dynamic>.from(item as Map),
          ),
        )
        .toList(),
  );
}

class EarningsFinancialsSection extends StatelessWidget {
  const EarningsFinancialsSection({
    super.key,
    required this.symbol,
    required this.data,
    required this.reports,
    required this.onOpenReport,
    this.loading = false,
    this.failed = false,
  });
  final String symbol;
  final FinancialsData data;
  final List<FinancialReportLink> reports;
  final ValueChanged<String> onOpenReport;
  final bool loading, failed;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Earnings & financials',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        if (loading)
          const LinearProgressIndicator(semanticsLabel: 'Loading financials')
        else if (failed)
          const Text('Financials could not be loaded.')
        else ...[
          _Valuation(data: data.valuation, compact: true),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            icon: const Icon(Icons.account_balance_outlined),
            label: const Text('Earnings & financials'),
            onPressed: () {
              final page = FinancialsView(
                symbol: symbol,
                data: data,
                reports: reports,
                onOpenReport: onOpenReport,
              );
              if (MediaQuery.sizeOf(context).width < 700) {
                Navigator.of(
                  context,
                ).push(MaterialPageRoute<void>(builder: (_) => page));
              } else {
                showDialog<void>(
                  context: context,
                  builder: (_) => Dialog(
                    clipBehavior: Clip.antiAlias,
                    child: SizedBox(
                      width: 860,
                      height: MediaQuery.sizeOf(context).height * .85,
                      child: page,
                    ),
                  ),
                );
              }
            },
          ),
        ],
      ],
    );
  }
}

class FinancialsView extends StatefulWidget {
  const FinancialsView({
    super.key,
    required this.symbol,
    required this.data,
    required this.reports,
    required this.onOpenReport,
  });
  final String symbol;
  final FinancialsData data;
  final List<FinancialReportLink> reports;
  final ValueChanged<String> onOpenReport;

  @override
  State<FinancialsView> createState() => _FinancialsViewState();
}

class _FinancialsViewState extends State<FinancialsView> {
  late bool annual =
      widget.data.statements.any((s) => s.annual) ||
      widget.data.statements.isEmpty;
  String? selectedKey;

  @override
  Widget build(BuildContext context) {
    final periods =
        widget.data.statements.where((s) => s.annual == annual).toList()
          ..sort((a, b) => b.end.compareTo(a.end));
    final selected =
        periods.where((s) => s.key == selectedKey).firstOrNull ??
        periods.firstOrNull;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(
          '${widget.symbol} / Financials',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        leading: IconButton(
          tooltip: 'Close financials',
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text('Latest valuation', style: theme.textTheme.titleLarge),
          const SizedBox(height: 12),
          _Valuation(data: widget.data.valuation),
          const Divider(height: 36),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: true, label: Text('Annual')),
              ButtonSegment(value: false, label: Text('Quarterly')),
            ],
            selected: {annual},
            onSelectionChanged: (value) => setState(() {
              annual = value.single;
              selectedKey = null;
            }),
          ),
          const SizedBox(height: 16),
          if (periods.isNotEmpty)
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final period in periods)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(period.label),
                        selected: selected == period,
                        onSelected: (_) =>
                            setState(() => selectedKey = period.key),
                      ),
                    ),
                ],
              ),
            ),
          const SizedBox(height: 16),
          if (selected == null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: Text(
                'No reviewed ${annual ? 'annual' : 'quarterly'} statements available.',
              ),
            )
          else ...[
            Text(
              '${DateFormat.yMMMd().format(selected.start)} - ${DateFormat.yMMMd().format(selected.end)}',
              style: theme.textTheme.bodyMedium,
            ),
            Text(
              '${selected.scope == 'consolidated' ? 'Consolidated' : 'Company only'}'
              ' / ${selected.audited ? 'Audited' : 'Unaudited'} / ${selected.currency}'
              '${selected.basis == 'year_to_date' ? ' / Year to date' : ''}',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            LayoutBuilder(
              builder: (context, constraints) {
                final income = _StatementGroup(
                  title: 'Income statement',
                  statement: selected,
                  fields: const {
                    'revenue': 'Revenue',
                    'gross_profit': 'Gross profit',
                    'ebit': 'EBIT',
                    'profit_before_tax': 'Profit before tax',
                    'net_profit': 'Profit after tax',
                    'eps': 'Earnings per share',
                  },
                );
                final balance = _StatementGroup(
                  title: 'Balance sheet',
                  statement: selected,
                  fields: const {
                    'total_assets': 'Total assets',
                    'total_liabilities': 'Total liabilities',
                    'total_equity': 'Total equity',
                    'ordinary_equity': 'Ordinary shareholders\' equity',
                  },
                );
                return constraints.maxWidth >= 640
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(child: income),
                          const SizedBox(width: 32),
                          Expanded(child: balance),
                        ],
                      )
                    : Column(
                        children: [income, const SizedBox(height: 20), balance],
                      );
              },
            ),
            const SizedBox(height: 16),
            TextButton.icon(
              onPressed: () => widget.onOpenReport(selected.sourceUrl),
              icon: const Icon(Icons.open_in_new, size: 18),
              label: Text(selected.sourceTitle),
            ),
          ],
          if (widget.reports.isNotEmpty) ...[
            const Divider(height: 36),
            Text('Financial reports', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            for (final report in widget.reports)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.description_outlined),
                title: Text(report.title),
                trailing: const Icon(Icons.open_in_new, size: 18),
                onTap: () => widget.onOpenReport(report.url),
              ),
          ],
        ],
      ),
    );
  }
}

class _Valuation extends StatelessWidget {
  const _Valuation({required this.data, this.compact = false});
  final Map<String, dynamic>? data;
  final bool compact;

  String ratio(String key) {
    final value = data?[key] as num?;
    if (value == null) return 'Not available';
    return value <= 0 ? 'N/M' : '${value.toStringAsFixed(2)}x';
  }

  @override
  Widget build(BuildContext context) {
    if (data == null) return const Text('Valuation data unavailable.');
    final updated = DateTime.tryParse(
      data!['provider_updated_at'] as String? ?? '',
    );
    final observed = DateTime.tryParse(data!['observed_at'] as String? ?? '');
    final freshness = data!['freshness'];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _MetricRow(label: 'Price-to-book (P/B)', value: ratio('pb_ratio')),
        _MetricRow(label: 'Price-to-earnings (P/E)', value: ratio('pe_ratio')),
        if (!compact)
          _MetricRow(
            label: 'EPS (provider units)',
            value:
                (data!['eps'] as num?)?.toStringAsFixed(2) ?? 'Not available',
          ),
        const SizedBox(height: 8),
        Text(
          'Kobo fundamentals'
          '${updated == null ? '' : ' / Updated ${DateFormat.yMMMd().format(updated)}'}'
          '${updated != null || observed == null ? '' : ' / Retrieved ${DateFormat.yMMMd().format(observed)}'}'
          '${freshness == 'stale'
              ? ' / Stale'
              : freshness == 'unknown'
              ? ' / Freshness unknown'
              : ''}',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        if (!compact)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'Provider snapshot; historical valuation date and EPS currency/period are not supplied.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
      ],
    );
  }
}

class _StatementGroup extends StatelessWidget {
  const _StatementGroup({
    required this.title,
    required this.statement,
    required this.fields,
  });
  final String title;
  final FinancialStatementData statement;
  final Map<String, String> fields;

  @override
  Widget build(BuildContext context) {
    final available = fields.entries.where(
      (field) => statement.metrics[field.key] != null,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            const Text('Y/Y'),
          ],
        ),
        if (available.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text('Not reported'),
          ),
        for (final field in available)
          _MetricRow(
            label: field.value,
            value:
                '${statement.currency} ${field.key == 'eps' ? (statement.metrics[field.key] as num).toStringAsFixed(2) : NumberFormat.compact(locale: 'en').format(statement.metrics[field.key])}',
            yoy: (statement.yoy[field.key] as num?)?.toDouble(),
            showYoy: true,
            neutral: field.key == 'total_liabilities',
          ),
      ],
    );
  }
}

class _MetricRow extends StatelessWidget {
  const _MetricRow({
    required this.label,
    required this.value,
    this.yoy,
    this.showYoy = false,
    this.neutral = false,
  });
  final String label, value;
  final double? yoy;
  final bool showYoy, neutral;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(flex: 5, child: Text(label)),
          const SizedBox(width: 12),
          Expanded(
            flex: 4,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  value,
                  textAlign: TextAlign.end,
                  style: theme.textTheme.titleSmall,
                ),
                if (showYoy)
                  Text(
                    yoy == null
                        ? 'Y/Y unavailable'
                        : '${yoy! > 0 ? '+' : ''}${yoy!.toStringAsFixed(2)}%',
                    textAlign: TextAlign.end,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: neutral || yoy == null || yoy == 0
                          ? theme.colorScheme.onSurfaceVariant
                          : yoy! > 0
                          ? (theme.brightness == Brightness.dark
                                ? Colors.greenAccent
                                : Colors.green.shade800)
                          : theme.colorScheme.error,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
