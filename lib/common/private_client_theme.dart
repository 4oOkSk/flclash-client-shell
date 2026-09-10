import 'package:flutter/material.dart';

ThemeData classicClientTheme(ThemeData base) {
  final dark = base.brightness == Brightness.dark;
  final primary = dark ? const Color(0xff90caf9) : const Color(0xff1976d2);
  final surface = dark ? const Color(0xff22272c) : Colors.white;
  final background = dark ? const Color(0xff171b1f) : const Color(0xfff5f6f8);
  final selection = dark ? const Color(0xff203c52) : const Color(0xffe3f2fd);
  const shape = RoundedRectangleBorder(
    borderRadius: BorderRadius.all(Radius.circular(4)),
  );
  final scheme =
      ColorScheme.fromSeed(
        seedColor: const Color(0xff1976d2),
        brightness: base.brightness,
      ).copyWith(
        primary: primary,
        primaryContainer: selection,
        secondary: primary,
        secondaryContainer: selection,
        onSecondaryContainer: primary,
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
    textTheme: base.textTheme.copyWith(
      titleLarge: base.textTheme.titleLarge?.copyWith(
        fontSize: 20,
        fontWeight: FontWeight.w500,
        letterSpacing: 0,
      ),
      titleMedium: base.textTheme.titleMedium?.copyWith(letterSpacing: 0),
      bodyLarge: base.textTheme.bodyLarge?.copyWith(letterSpacing: 0),
      bodyMedium: base.textTheme.bodyMedium?.copyWith(letterSpacing: 0),
      labelLarge: base.textTheme.labelLarge?.copyWith(letterSpacing: 0),
    ),
    colorScheme: scheme,
    scaffoldBackgroundColor: background,
    canvasColor: surface,
    dividerColor: scheme.outlineVariant,
    splashFactory: InkRipple.splashFactory,
    appBarTheme: AppBarThemeData(
      backgroundColor: background,
      foregroundColor: scheme.onSurface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: base.textTheme.titleLarge?.copyWith(
        color: scheme.onSurface,
        fontSize: 20,
        fontWeight: FontWeight.w500,
        letterSpacing: 0,
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
      backgroundColor: background,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      indicatorShape: shape,
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: background,
      indicatorColor: selection,
      indicatorShape: shape,
      selectedIconTheme: IconThemeData(color: primary, size: 24),
      unselectedIconTheme: IconThemeData(
        color: scheme.onSurfaceVariant,
        size: 24,
      ),
    ),
    floatingActionButtonTheme: base.floatingActionButtonTheme.copyWith(
      shape: shape,
    ),
  );
}
