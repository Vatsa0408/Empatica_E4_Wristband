/// The design's three visual tiers (mobile/tablet/desktop), mapped onto
/// width via Flutter's own breakpoints rather than the design preview's
/// literal fixed frame sizes (390/1112/1440).
enum Breakpoint { compact, medium, expanded }

Breakpoint breakpointFor(double width) {
  if (width < 600) return Breakpoint.compact;
  if (width < 1240) return Breakpoint.medium;
  return Breakpoint.expanded;
}
