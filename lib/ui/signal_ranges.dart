import '../model/e4_sample.dart';

/// Whether a signal's latest value sits inside its expected range, outside
/// it, or there's no data yet to judge. Rendered as an icon + caption (never
/// color alone) by `RangePill` — see `widgets/pill_widgets.dart`.
enum RangeStatus { noData, ok, outOfRange }

/// One signal's documented expected range plus the caption shown under its
/// dashboard card. Ranges per CLAUDE.md/task spec; all are approximate
/// guidance, not hard device limits, so are deliberately generous.
class SignalRangeSpec {
  const SignalRangeSpec({required this.caption, this.min, this.max, this.artifactAbs});

  /// Caption shown under the card's value, e.g. "40-180 bpm".
  final String caption;

  /// Inclusive lower/upper bound. Null means "no bound on this side".
  final double? min;
  final double? max;

  /// BVP-only: it has no true device max (arbitrary filtered units), so
  /// instead of min/max this flags |value| above this as a likely motion
  /// artifact.
  final double? artifactAbs;
}

/// Single source of truth for every signal's expected-range caption, keyed
/// by [E4Signal]. [E4Signal.tag] has no numeric value and isn't shown on the
/// dashboard, so it's omitted.
const Map<E4Signal, SignalRangeSpec> signalRangeSpecs = {
  E4Signal.bvp: SignalRangeSpec(caption: 'arbitrary units — flagged if |value| > 1000 (motion artifact)', artifactAbs: 1000),
  E4Signal.hr: SignalRangeSpec(caption: '40-180 bpm', min: 40, max: 180),
  E4Signal.ibi: SignalRangeSpec(caption: '0.33-1.5 s (resting ~0.6-1.1)', min: 0.33, max: 1.5),
  E4Signal.eda: SignalRangeSpec(caption: '0.01-100 µS (typical 0.5-20)', min: 0.01, max: 100),
  E4Signal.temp: SignalRangeSpec(caption: '30-37 °C on skin', min: 30, max: 37),
  E4Signal.acc: SignalRangeSpec(caption: '±128 raw (64 = 1g, ±2g full scale)', min: -128, max: 127),
  E4Signal.battery: SignalRangeSpec(caption: '0-100%', min: 0, max: 100),
};

/// Classifies [value] for [signal] against [signalRangeSpecs]. `null`
/// (no sample yet) is always [RangeStatus.noData]; a signal missing from the
/// table is always [RangeStatus.ok] (nothing documented to flag).
RangeStatus rangeStatusFor(E4Signal signal, double? value) {
  if (value == null) return RangeStatus.noData;
  final spec = signalRangeSpecs[signal];
  if (spec == null) return RangeStatus.ok;
  if (spec.artifactAbs != null) {
    return value.abs() > spec.artifactAbs! ? RangeStatus.outOfRange : RangeStatus.ok;
  }
  final belowMin = spec.min != null && value < spec.min!;
  final aboveMax = spec.max != null && value > spec.max!;
  return (belowMin || aboveMax) ? RangeStatus.outOfRange : RangeStatus.ok;
}
