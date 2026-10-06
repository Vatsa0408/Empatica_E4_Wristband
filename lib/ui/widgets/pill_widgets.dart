import 'package:flutter/material.dart';

import '../signal_ranges.dart';
import '../theme/e4_colors.dart';

/// A pill-shaped icon+label button, filled or outlined. `onPressed == null`
/// renders it dimmed and non-interactive — used for Start/Stop/Scan/
/// Disconnect/Export everywhere in the design.
class PillButton extends StatelessWidget {
  const PillButton({
    super.key,
    required this.label,
    required this.onPressed,
    required this.background,
    required this.foreground,
    this.icon,
    this.outlined = false,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final Color background;
  final Color foreground;
  final bool outlined;

  @override
  Widget build(BuildContext context) {
    final disabled = onPressed == null;
    return Opacity(
      opacity: disabled ? 0.7 : 1,
      child: Material(
        color: outlined ? Colors.transparent : background,
        shape: StadiumBorder(side: outlined ? BorderSide(color: background) : BorderSide.none),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onPressed,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[Icon(icon, size: 18, color: foreground), const SizedBox(width: 6)],
                Text(label, style: TextStyle(color: foreground, fontWeight: FontWeight.w800, fontSize: 13)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A card's expected-range caption, shown under its current value: icon +
/// text (never color alone) so in-range/out-of-range/no-data reads without
/// relying on color perception.
class RangePill extends StatelessWidget {
  const RangePill({super.key, required this.status, required this.caption});

  final RangeStatus status;
  final String caption;

  @override
  Widget build(BuildContext context) {
    final (icon, background, foreground) = switch (status) {
      RangeStatus.noData => (Icons.remove_circle_outline, E4Colors.disconnectedBg, E4Colors.disconnectedFg),
      RangeStatus.ok => (Icons.check_circle_outline, E4Colors.connectedBg, E4Colors.connectedFg),
      RangeStatus.outOfRange => (Icons.warning_amber_rounded, E4Colors.scanningBg, E4Colors.scanningFg),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: background, borderRadius: BorderRadius.circular(999)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: foreground),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              caption,
              style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: foreground),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

/// The Manual/Continuous-style two-option pill toggle, reused wherever the
/// design shows a segmented control.
class SegmentedPill<T> extends StatelessWidget {
  const SegmentedPill({super.key, required this.options, required this.selected, required this.onChanged});

  final List<(T value, String label)> options;
  final T selected;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(color: E4Colors.segmentTrack, borderRadius: BorderRadius.circular(999)),
      child: Row(
        children: [
          for (final option in options)
            Expanded(
              child: GestureDetector(
                onTap: () => onChanged(option.$1),
                child: Container(
                  alignment: Alignment.center,
                  padding: const EdgeInsets.symmetric(vertical: 9),
                  decoration: BoxDecoration(
                    color: option.$1 == selected ? Colors.white : Colors.transparent,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    option.$2,
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                      color: option.$1 == selected ? const Color(0xFF1D1B20) : E4Colors.mutedText,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
