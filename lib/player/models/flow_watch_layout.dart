import 'dart:ui';

// Translated from Flow 565d1f7a, PlayerLayoutMode.kt and PlayerDetailPanes.kt.
enum FlowWatchLayout {
  compact,
  medium,
  wide;

  static FlowWatchLayout forWindow(Size window) {
    if (window.height < 480) return compact;
    if (window.width >= 840 && window.width > window.height) return wide;
    if (window.width >= 600) return medium;
    return compact;
  }

  // The pinned Flow fixture reserves 384 dp. Keep 24 dp of it for the gap.
  static const supportingPaneWidth = 360.0;
  static const supportingPaneGap = 24.0;
}
