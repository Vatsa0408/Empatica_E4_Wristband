import 'package:e4_integrator/ui/widgets/signal_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('chartPoints returns nothing for fewer than 2 values', () {
    expect(chartPoints([], const Size(100, 50), 0, 1), isEmpty);
    expect(chartPoints([5], const Size(100, 50), 0, 1), isEmpty);
  });

  test('chartPoints spans the full width and clamps out-of-domain values', () {
    final points = chartPoints([-10, 0, 10, 999], const Size(100, 50), 0, 10);

    expect(points.length, 4);
    expect(points.first.dx, 0); // first sample at x=0
    expect(points.last.dx, 100); // last sample at x=width

    // -10 is below min -> clamped to the bottom (y == height).
    expect(points[0].dy, 50);
    // 999 is above max -> clamped to the top (y == 0).
    expect(points[3].dy, 0);
    // 0 sits at the low end of [0,10] -> still near the bottom.
    expect(points[1].dy, 50);
  });
}
