import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

const _seed = Color(0xFF7C3AED);
const _bg = Color(0xFF0C0E18);
const _surface = Color(0xFF13162A);
const _surfaceHigh = Color(0xFF1C2040);

class CodTheme {
  static ThemeData get dark {
    final base = ThemeData.dark(useMaterial3: true);
    final scheme = ColorScheme.fromSeed(
      seedColor: _seed,
      brightness: Brightness.dark,
    ).copyWith(
      surface: _bg,
      surfaceContainerLow: _surface,
      surfaceContainerHigh: _surfaceHigh,
      surfaceContainer: _surface,
      onSurface: const Color(0xFFE8E8F0),
      primary: _seed,
      secondary: const Color(0xFF3B82F6),
    );

    return base.copyWith(
      colorScheme: scheme,
      scaffoldBackgroundColor: _bg,
      textTheme: GoogleFonts.interTextTheme(base.textTheme).apply(
        bodyColor: scheme.onSurface,
        displayColor: scheme.onSurface,
      ),
      cardTheme: CardThemeData(
        color: _surface,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: EdgeInsets.zero,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: _surfaceHigh,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: _bg,
        indicatorColor: _seed.withValues(alpha: 0.25),
        labelTextStyle: WidgetStateProperty.all(
          GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w500),
        ),
        elevation: 0,
      ),
      dividerTheme: const DividerThemeData(color: _surfaceHigh, space: 1),
      appBarTheme: AppBarTheme(
        backgroundColor: _bg,
        elevation: 0,
        scrolledUnderElevation: 0,
        titleTextStyle: GoogleFonts.inter(
          fontSize: 18,
          fontWeight: FontWeight.w600,
          color: scheme.onSurface,
        ),
        iconTheme: IconThemeData(color: scheme.onSurface),
      ),
    );
  }
}
