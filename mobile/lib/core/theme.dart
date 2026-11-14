import 'package:flutter/material.dart';

class AppColors {
  static const bg = Color(0xFF090C11);
  static const surface = Color(0xFF121821);
  static const surfaceHi = Color(0xFF1A2230);
  static const outline = Color(0xFF263040);
  static const accent = Color(0xFF38BDF8);
  static const accent2 = Color(0xFF818CF8);
  static const good = Color(0xFF34D399);
  static const bad = Color(0xFFF87171);
  static const warn = Color(0xFFFBBF24);
  static const text = Color(0xFFE8ECF3);
  static const textDim = Color(0xFF8A96A8);
  static const attack = Color(0xFFFB923C);
  static const defense = Color(0xFF60A5FA);

  static const accentGradient = LinearGradient(colors: [accent, accent2], begin: Alignment.topLeft, end: Alignment.bottomRight);
}

Color parseHex(String? hex, {Color fallback = AppColors.accent}) {
  if (hex == null || !hex.startsWith('#') || hex.length != 7) return fallback;
  final v = int.tryParse(hex.substring(1), radix: 16);
  return v == null ? fallback : Color(0xFF000000 | v);
}

const tabular = [FontFeature.tabularFigures()];

ThemeData buildTheme() {
  final base = ThemeData.dark(useMaterial3: true);
  final text = base.textTheme.apply(bodyColor: AppColors.text, displayColor: AppColors.text);
  return base.copyWith(
    scaffoldBackgroundColor: AppColors.bg,
    colorScheme: const ColorScheme.dark(
      primary: AppColors.accent,
      secondary: AppColors.accent2,
      surface: AppColors.surface,
      error: AppColors.bad,
    ),
    textTheme: text,
    splashFactory: InkSparkle.splashFactory,
    cardTheme: CardThemeData(
      color: AppColors.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: const BorderSide(color: AppColors.outline, width: 0.8)),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: AppColors.surface,
      height: 68,
      indicatorColor: AppColors.accent.withValues(alpha: 0.16),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (s) => TextStyle(fontSize: 11.5, fontWeight: s.contains(WidgetState.selected) ? FontWeight.w700 : FontWeight.w500, color: s.contains(WidgetState.selected) ? AppColors.text : AppColors.textDim),
      ),
      iconTheme: WidgetStateProperty.resolveWith((s) => IconThemeData(color: s.contains(WidgetState.selected) ? AppColors.accent : AppColors.textDim)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.surfaceHi,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: AppColors.accent, width: 1.4)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.accent,
        side: BorderSide(color: AppColors.accent.withValues(alpha: 0.5)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: AppColors.surface,
      showDragHandle: true,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: AppColors.surfaceHi,
      selectedColor: AppColors.accent.withValues(alpha: 0.2),
      side: BorderSide.none,
      showCheckmark: false,
      labelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.textDim),
      secondaryLabelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.accent),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
    ),
    dividerTheme: const DividerThemeData(color: AppColors.outline, thickness: 0.8, space: 1),
  );
}
