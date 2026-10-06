import 'package:flutter/material.dart';

/// One line within a [SignalChart]: a series of raw values, its own y-domain
/// (ACC's x/y/z each normalize independently onto the same pixel height in
/// the design, rather than sharing one physical scale) and how to draw it.
/// `opacity` lets ACC overlay x/y/z at different strengths (1 / 0.55 / 0.32).
class ChartSeries {
  const ChartSeries(this.values, this.color, {required this.min, required this.max, this.opacity = 1});

  final List<double> values;
  final Color color;
  final double min;
  final double max;
  final double opacity;
}

/// Maps [values] onto a [size]-sized canvas for a given `[min, max]` domain,
/// clamping out-of-range values rather than overflowing the chart. Pure and
/// side-effect free so it's directly testable (see `test/signal_chart_test.dart`).
List<Offset> chartPoints(List<double> values, Size size, double min, double max) {
  final n = values.length;
  if (n < 2) return const [];
  final range = max - min;
  return [
    for (var i = 0; i < n; i++)
      Offset(
        i / (n - 1) * size.width,
        size.height - (((values[i] - min) / range).clamp(0.0, 1.0)) * size.height,
      ),
  ];
}

/// A small multi-line chart, used for both the dashboard's raw waveform cards
/// (BVP, ACC) and its derived trend cards (HR, EDA, TEMP, IBI). Ports the
/// design's `pathFor`/`areaPath` point math directly.
class SignalChart extends StatelessWidget {
  const SignalChart({super.key, required this.series, this.filled = false, this.height = 64});

  final List<ChartSeries> series;

  /// Fills the area under the first series with a light tint. Only
  /// meaningful (and only used) for single-series trend cards.
  final bool filled;

  final double height;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(painter: _SignalChartPainter(series, filled)),
    );
  }
}

class _SignalChartPainter extends CustomPainter {
  _SignalChartPainter(this.series, this.filled);

  final List<ChartSeries> series;
  final bool filled;

  @override
  void paint(Canvas canvas, Size size) {
    for (final line in series) {
      final points = chartPoints(line.values, size, line.min, line.max);
      if (points.length < 2) continue;

      if (filled) {
        final fillPath = Path()..moveTo(0, size.height);
        for (final point in points) {
          fillPath.lineTo(point.dx, point.dy);
        }
        fillPath.lineTo(size.width, size.height);
        fillPath.close();
        canvas.drawPath(fillPath, Paint()..color = line.color.withValues(alpha: 0.16));
      }

      final linePath = Path()..moveTo(points.first.dx, points.first.dy);
      for (final point in points.skip(1)) {
        linePath.lineTo(point.dx, point.dy);
      }
      canvas.drawPath(
        linePath,
        Paint()
          ..color = line.color.withValues(alpha: line.opacity)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _SignalChartPainter oldDelegate) => true;
}
