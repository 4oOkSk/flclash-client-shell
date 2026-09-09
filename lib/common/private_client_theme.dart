import 'package:flutter/material.dart';

ThemeData classicClientTheme(ThemeData base) {
  final dark = base.brightness == Brightness.dark;
  final primary = dark ? const Color(0xff90caf9) : const Color(0xff1976d2);
  final surface = dark ? const Color(0xff22272c) : Colors.white;
  final background = dark ? const Color(0xff171b1f) : const Color(0xfff5f5f5);
  const shape = RoundedRectangleBorder(
    borderRadius: BorderRadius.all(Radius.circular(3)),
  );
  final scheme =
      ColorScheme.fromSeed(
        seedColor: const Color(0xff1976d2),
        brightness: base.brightness,
      ).copyWith(
        primary: primary,
        surface: surface,
        surfaceContainerLowest: surface,
        surfaceContainerLow: surface,
        surfaceContainer: surface,
        surfaceContainerHigh: surface,
        surfaceContainerHighest: dark
            ? const Color(0xff39434b)
            : const Color(0xffe0e0e0),
        surfaceTint: Colors.transparent,
      );
  return base.copyWith(
    colorScheme: scheme,
    scaffoldBackgroundColor: background,
    canvasColor: surface,
    dividerColor: scheme.outlineVariant,
    splashFactory: InkRipple.splashFactory,
    appBarTheme: AppBarThemeData(
      backgroundColor: dark ? const Color(0xff173c5b) : const Color(0xff2196f3),
      foregroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      elevation: 2,
      scrolledUnderElevation: 2,
      centerTitle: false,
      titleTextStyle: base.textTheme.titleLarge?.copyWith(
        color: Colors.white,
        fontWeight: FontWeight.w500,
      ),
    ),
    cardTheme: CardThemeData(
      color: surface,
      surfaceTintColor: Colors.transparent,
      elevation: 1,
      shape: shape,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: surface,
      surfaceTintColor: Colors.transparent,
      shape: shape,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: shape,
        minimumSize: const Size(64, 44),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        shape: shape,
        minimumSize: const Size(64, 44),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(shape: shape),
    ),
    inputDecorationTheme: const InputDecorationThemeData(
      border: UnderlineInputBorder(),
      filled: false,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: surface,
      surfaceTintColor: Colors.transparent,
      indicatorShape: shape,
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: surface,
      indicatorShape: shape,
    ),
    floatingActionButtonTheme: base.floatingActionButtonTheme.copyWith(
      shape: shape,
    ),
  );
}
