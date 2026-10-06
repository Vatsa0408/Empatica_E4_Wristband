import 'package:flutter/material.dart';

/// Color palette from the M3 Expressive design (Claude Design project
/// `777c388a-24af-4bbc-99b8-30ddb8ad7391`, "E4 Integrator - M3 Expressive").
/// Kept in one place instead of repeating hex literals across every screen.
class E4Colors {
  const E4Colors._();

  static const primary = Color(0xFF4B3FCB);
  static const surfaceTint = Color(0xFFEFE9F5);
  static const surface = Color(0xFFFEF7FF);
  static const surfaceDim = Color(0xFFF7F1FA);
  static const outline = Color(0xFFE6DFEC);
  static const neutralText = Color(0xFF49454F);
  static const mutedText = Color(0xFF79747E);
  static const emptyStateText = Color(0xFF938F99);

  // Connection status.
  static const disconnectedBg = Color(0xFFE7E0EB);
  static const disconnectedFg = Color(0xFF79747E);
  static const scanningBg = Color(0xFFFFE8C7);
  static const scanningFg = Color(0xFF8B5000);
  static const connectingBg = Color(0xFFE4DFFF);
  static const connectingFg = Color(0xFF4B3FCB);
  static const connectedBg = Color(0xFFD7F2DD);
  static const connectedFg = Color(0xFF146C2E);

  // Per-signal chart colors + tints.
  static const bvp = Color(0xFF4B3FCB);
  static const bvpTint = Color(0xFFEDE9FF);
  static const acc = Color(0xFF8B5000);
  static const accTint = Color(0xFFFFEFD6);
  static const hr = Color(0xFFB3435E);
  static const hrTint = Color(0xFFFFE3E9);
  static const eda = Color(0xFF12695B);
  static const edaTint = Color(0xFFD9F5EA);
  static const temp = Color(0xFFB34700);
  static const tempTint = Color(0xFFFFE6CE);
  static const ibi = Color(0xFF2E5AAC);
  static const ibiTint = Color(0xFFEDF0FF);
  static const batteryTint = Color(0xFFEFF5E7);
  static const batteryLow = Color(0xFFB3261E);
  static const batteryNormal = Color(0xFF3B3844);

  // Buttons / pills.
  static const segmentTrack = Color(0xFFEDE7F3);
  static const stopBg = Color(0xFFFFDAD6);
  static const stopFg = Color(0xFFB3261E);
  static const disabledBg = Color(0xFFE6E0E9);
  static const disabledFg = Color(0xFF938F99);
  static const navSelectedBg = Color(0xFFE4DFFF);
  static const cardOutline = Color(0xFFCAC4D0);

  // History export pill.
  static const exportBg = Color(0xFFE4DFFF);
  static const exportFg = Color(0xFF4B3FCB);
  static const exportedBg = Color(0xFFEDE7F3);
  static const exportedFg = Color(0xFF79747E);
}
