/// Chart primitives for the parent Progress screen.
///
/// Hand-drawn on purpose: no charting package, so the marks obey the house
/// rules exactly. Single hue (a darker step of brand mango, the only colour a
/// mark ever wears), hairline recessive grid, 4px rounded caps anchored to the
/// baseline, a 2px surface gap between bars, and labels on at most three bars.
/// Every value is also carried as a Semantics label, so a screen reader gets
/// the whole chart as text rather than a picture.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme.dart';

/// Bar height as a fraction of the plot.
///
/// Guards the two ways this goes wrong: a window where nothing happened has a
/// max of 0 and must render flat rather than divide by zero, and a value above
/// the max (a fixed-scale chart, a gateway rounding up) must not overflow the
/// plot. `!(max > 0)` rather than `max <= 0` so NaN is caught too.
double barFraction(double value, double max) {
  if (!(max > 0) || !(value > 0)) return 0;
  return (value / max).clamp(0.0, 1.0);
}

/// Which bars get a printed value: the tallest, the last with data, and the
/// first with data - never every bar. Priority runs tallest, last, first, and
/// a candidate closer than [minGap] slots to one already kept is dropped so
/// two labels can never collide.
Set<int> labelledBarIndices(List<double> values, {int minGap = 4}) {
  final withData = <int>[
    for (var i = 0; i < values.length; i++)
      if (values[i] > 0) i,
  ];
  if (withData.isEmpty) return const <int>{};

  var tallest = withData.first;
  for (final i in withData) {
    if (values[i] > values[tallest]) tallest = i;
  }

  final kept = <int>[];
  for (final i in [tallest, withData.last, withData.first]) {
    if (kept.every((k) => (k - i).abs() >= minGap)) kept.add(i);
  }
  return kept.toSet();
}

/// Left edge of a fixed-width label box centred on [centre], held inside the
/// plot so a label on the first or last column is never clipped by the card.
double labelLeft(double centre, double plotWidth, double boxWidth) {
  if (plotWidth <= boxWidth) return (plotWidth - boxWidth) / 2;
  return (centre - boxWidth / 2).clamp(0.0, plotWidth - boxWidth);
}

/// One day's column.
class ColumnDatum {
  const ColumnDatum({
    required this.value,
    required this.valueLabel,
    required this.caption,
    required this.semantics,
    this.tick,
    this.present = true,
  });

  final double value;

  /// Value on the cap, e.g. "40 min". Only rendered on labelled bars.
  final String valueLabel;

  /// Shown under the chart when this bar is tapped, e.g. "Tue 2 Sep - 40 min".
  final String caption;

  /// The whole datum as a sentence for a screen reader.
  final String semantics;

  /// Axis tick under this column; null for the columns that get none.
  final String? tick;

  /// False when there is no measurement for the day, which is not the same as
  /// a measured zero. No bar is drawn either way, but the wording differs.
  final bool present;
}

/// Single-series column chart, one bar per day including the empty ones.
class DayColumnChart extends StatefulWidget {
  const DayColumnChart({
    super.key,
    required this.data,
    this.fixedMax,
    this.plotHeight = 132,
    this.hint,
  });

  final List<ColumnDatum> data;

  /// Set for a chart whose ceiling is meaningful on its own (a rate is always
  /// out of 100%). Left null, the scale is the window's own tallest day.
  final double? fixedMax;
  final double plotHeight;

  /// Muted line shown under the plot until a bar is tapped.
  final String? hint;

  @override
  State<DayColumnChart> createState() => _DayColumnChartState();
}

class _DayColumnChartState extends State<DayColumnChart> {
  int? _selected;

  @override
  void didUpdateWidget(DayColumnChart old) {
    super.didUpdateWidget(old);
    // The range selector can shorten the window under a selection.
    if (_selected != null && _selected! >= widget.data.length) _selected = null;
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    if (data.isEmpty) return const SizedBox.shrink();

    final values = [for (final d in data) d.value];
    final max =
        widget.fixedMax ?? values.fold<double>(0, (m, v) => math.max(m, v));
    final labelled = labelledBarIndices(values);
    final selected = _selected;

    // The top of the plot is reserved for a cap label, so the tallest bar can
    // never push its own number out of the box.
    const capBand = 18.0;
    const gap = 2.0;
    final usable = widget.plotHeight - capBand;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 6,
      children: [
        LayoutBuilder(
          builder: (context, c) {
            final n = data.length;
            final slot = (c.maxWidth - gap * (n - 1)) / n;
            final barW = slot.clamp(2.0, 24.0);
            double centre(int i) => i * (slot + gap) + slot / 2;

            return SizedBox(
              height: widget.plotHeight,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned.fill(
                    child: CustomPaint(painter: _GridPainter(usable: usable)),
                  ),
                  for (var i = 0; i < n; i++)
                    if (barFraction(data[i].value, max) > 0)
                      Positioned(
                        left: centre(i) - barW / 2,
                        width: barW,
                        bottom: 0,
                        height: math.max(
                          3,
                          barFraction(data[i].value, max) * usable,
                        ),
                        child: const DecoratedBox(
                          decoration: BoxDecoration(
                            color: HgColors.mangoDeep,
                            // Rounded at the data end, square on the baseline.
                            borderRadius: BorderRadius.vertical(
                              top: Radius.circular(4),
                            ),
                          ),
                        ),
                      ),
                  // Labels sit above the cap in a box wider than the slot, so
                  // they stay centred and unclipped on a 30 day window.
                  for (var i = 0; i < n; i++)
                    if (labelled.contains(i) || selected == i)
                      Positioned(
                        left: labelLeft(centre(i), c.maxWidth, 64),
                        width: 64,
                        bottom:
                            math.max(
                              3,
                              barFraction(data[i].value, max) * usable,
                            ) +
                            2,
                        child: Text(
                          data[i].valueLabel,
                          textAlign: TextAlign.center,
                          style: HgText.body(
                            size: 12,
                            weight: FontWeight.w800,
                            color: selected == i
                                ? HgColors.ink
                                : HgColors.brown,
                          ),
                        ),
                      ),
                  // Full-height hit targets, one per slot, on top of the marks.
                  for (var i = 0; i < n; i++)
                    Positioned(
                      left: i * (slot + gap),
                      width: slot + gap,
                      top: 0,
                      bottom: 0,
                      child: Semantics(
                        button: true,
                        label: data[i].semantics,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => setState(
                            () => _selected = selected == i ? null : i,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            );
          },
        ),
        _AxisBand(data: data, gap: gap),
        if (selected != null || widget.hint != null)
          Text(
            selected != null ? data[selected].caption : widget.hint!,
            style: HgText.body(
              size: 13,
              weight: FontWeight.w700,
              color: selected != null ? HgColors.ink : HgColors.muted,
            ),
          ),
      ],
    );
  }
}

/// Axis ticks, positioned on the same slot centres as the bars.
class _AxisBand extends StatelessWidget {
  const _AxisBand({required this.data, required this.gap});

  final List<ColumnDatum> data;
  final double gap;

  @override
  Widget build(BuildContext context) {
    if (data.every((d) => d.tick == null)) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, c) {
        final n = data.length;
        final slot = (c.maxWidth - gap * (n - 1)) / n;
        return SizedBox(
          height: 16,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              for (var i = 0; i < n; i++)
                if (data[i].tick != null)
                  Positioned(
                    left: labelLeft(
                      i * (slot + gap) + slot / 2,
                      c.maxWidth,
                      64,
                    ),
                    width: 64,
                    top: 0,
                    child: Text(
                      data[i].tick!,
                      textAlign: TextAlign.center,
                      style: HgText.body(size: 12, color: HgColors.muted),
                    ),
                  ),
            ],
          ),
        );
      },
    );
  }
}

/// Baseline plus two hairlines. Solid, one step off the card, never dashed.
class _GridPainter extends CustomPainter {
  const _GridPainter({required this.usable});

  final double usable;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = HgColors.line
      ..strokeWidth = 1;
    for (final f in const [0.0, 0.5, 1.0]) {
      // Half-pixel offset keeps a 1px line crisp and off the clip edge.
      final y = size.height - usable * f - 0.5;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(_GridPainter old) => old.usable != usable;
}

/// One row of the channel-mix chart.
class BarRow {
  const BarRow({
    required this.label,
    required this.valueLabel,
    required this.value,
    required this.semantics,
  });

  final String label;
  final String valueLabel;
  final double value;
  final String semantics;
}

/// Horizontal bars, one hue, direct-labelled. Long channel titles are why this
/// is horizontal and not a column chart, and it is never a pie: the reader is
/// comparing lengths, which a wedge makes harder.
class HorizontalBars extends StatelessWidget {
  const HorizontalBars({super.key, required this.rows});

  final List<BarRow> rows;

  @override
  Widget build(BuildContext context) {
    final max = rows.fold<double>(0, (m, r) => math.max(m, r.value));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 14,
      children: [
        for (final r in rows)
          Semantics(
            label: r.semantics,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 6,
              children: [
                Row(
                  spacing: 10,
                  children: [
                    Expanded(
                      child: Text(
                        r.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: HgText.body(size: 15, color: HgColors.ink),
                      ),
                    ),
                    Text(
                      r.valueLabel,
                      style: HgText.body(size: 14, color: HgColors.brown),
                    ),
                  ],
                ),
                SizedBox(
                  height: 10,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: FractionallySizedBox(
                      widthFactor: math.max(
                        barFraction(r.value, max),
                        // A channel with any minutes at all keeps a visible
                        // stub rather than vanishing entirely.
                        r.value > 0 ? 0.02 : 0.0,
                      ),
                      heightFactor: 1,
                      child: const DecoratedBox(
                        decoration: BoxDecoration(
                          color: HgColors.mangoDeep,
                          // Rounded at the data end, square at the baseline.
                          borderRadius: BorderRadius.horizontal(
                            right: Radius.circular(4),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
