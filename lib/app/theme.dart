import 'package:flutter/material.dart';

abstract final class AppColors {
  static const navy = Color(0xFF12375E),
      blue = Color(0xFF0078A8),
      teal = Color(0xFF00A7C7),
      muted = Color(0xFF718096),
      canvas = Color(0xFFF8FAFC);
}

ThemeData buildTheme() => ThemeData(
  useMaterial3: true,
  fontFamily: 'Arial',
  scaffoldBackgroundColor: AppColors.canvas,
  colorScheme: ColorScheme.fromSeed(
    seedColor: AppColors.blue,
    primary: AppColors.blue,
    surface: Colors.white,
  ),
  textTheme: const TextTheme(
    headlineSmall: TextStyle(
      fontWeight: FontWeight.w800,
      color: AppColors.navy,
    ),
    titleLarge: TextStyle(fontWeight: FontWeight.w800, color: AppColors.navy),
    titleMedium: TextStyle(fontWeight: FontWeight.w700, color: AppColors.navy),
    bodyMedium: TextStyle(color: AppColors.muted, fontWeight: FontWeight.w600),
  ),
  inputDecorationTheme: InputDecorationTheme(
    filled: true,
    fillColor: Colors.white,
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: const BorderSide(color: Color(0xFFE4E8EE)),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: const BorderSide(color: AppColors.blue, width: 1.5),
    ),
  ),
);
