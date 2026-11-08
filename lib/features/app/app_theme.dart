import 'package:flutter/material.dart';

class AppTheme {
  static const accent = Color(0xFFE50914);
  static const focusBorder = Color(0xFFFF2D2D);
  static const bg = Color(0xFF0B0E14);
  static const surface = Color(0xFF141A22);
  static const card = Color(0xFF1A222D);

  static ThemeData get dark => ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: bg,
        primaryColor: accent,
        colorScheme: const ColorScheme.dark(
          primary: accent,
          secondary: Color(0xFF7B5CFF),
          surface: surface,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.transparent,
          elevation: 0,
          centerTitle: false,
        ),
        useMaterial3: true,
      );
}
