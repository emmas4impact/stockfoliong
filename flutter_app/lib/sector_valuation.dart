import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

class SectorValuation {
  const SectorValuation({
    required this.sector,
    required this.pe,
    required this.median,
    required this.peers,
    required this.rank,
    required this.observed,
    required this.reasons,
  });

  final String? sector;
  final double? pe, median, rank;
  final int peers;
  final DateTime? observed;
  final List<String> reasons;

  factory SectorValuation.fromJson(Map<String, dynamic> json) {
    final inputs = json['inputs'] as Map<String, dynamic>;
    final scores = json['scores'] as Map<String, dynamic>;
    return SectorValuation(
      sector: inputs['sector'] as String?,
      pe: (inputs['pe_ratio'] as num?)?.toDouble(),
      median: (json['sector_pe_median'] as num?)?.toDouble(),
      peers: (json['peer_count'] as num).toInt(),
      rank: (scores['valuation'] as num?)?.toDouble(),
      observed: DateTime.tryParse(json['observed_at'] as String? ?? ''),
      reasons: List<String>.from(json['reasons'] as List),
    );
  }
}

class SectorValuationSection extends StatefulWidget {
  const SectorValuationSection({
    super.key,
    required this.symbol,
    required this.load,
  });
  final String symbol;
  final Future<SectorValuation?> Function(String) load;

  @override
  State<SectorValuationSection> createState() => _SectorValuationSectionState();
}

class _SectorValuationSectionState extends State<SectorValuationSection> {
  late Future<SectorValuation?> result = widget.load(widget.symbol);

  @override
  void didUpdateWidget(SectorValuationSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.symbol != oldWidget.symbol || widget.load != oldWidget.load) {
      result = widget.load(widget.symbol);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Sector valuation', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        FutureBuilder<SectorValuation?>(
          future: result,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const LinearProgressIndicator(
                semanticsLabel: 'Loading sector valuation',
              );
            }
            if (snapshot.hasError) {
              return Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Text('Sector valuation could not be loaded.'),
                  IconButton(
                    tooltip: 'Retry sector valuation',
                    icon: const Icon(Icons.refresh),
                    onPressed: () => setState(() {
                      result = widget.load(widget.symbol);
                    }),
                  ),
                ],
              );
            }
            final data = snapshot.data;
            if (data == null) {
              return const Text('No valuation observation yet for this stock.');
            }
            Widget metric(String label, String value) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: theme.textTheme.bodySmall),
                Text(value, style: theme.textTheme.titleMedium),
              ],
            );
            String multiple(double? v) =>
                v == null ? 'Not available' : '${v.toStringAsFixed(2)}x';
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  [
                    if (data.sector != null)
                      toBeginningOfSentenceCase(data.sector!),
                    if (data.observed != null)
                      'Observed ${DateFormat.yMMMd().format(data.observed!.toLocal())}',
                  ].join(' | '),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 24,
                  runSpacing: 8,
                  children: [
                    metric('Stock P/E', multiple(data.pe)),
                    metric('Sector median P/E', multiple(data.median)),
                    metric('Eligible peers', data.peers.toString()),
                    metric(
                      'Relative rank',
                      data.rank == null
                          ? 'Not scored'
                          : '${NumberFormat('0.##').format(data.rank)} / 100',
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (data.rank != null)
                  const Text(
                    'A higher rank means a lower P/E relative to peers, not a higher probability of profit.',
                  )
                else
                  for (final reason in data.reasons) Text(reason),
              ],
            );
          },
        ),
      ],
    );
  }
}
