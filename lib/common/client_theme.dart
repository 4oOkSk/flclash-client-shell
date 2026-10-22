import 'package:flutter/material.dart';

ColorScheme clientBrandColorScheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  return ColorScheme.fromSeed(
    seedColor: const Color(0xff0b57d0),
    brightness: brightness,
  ).copyWith(
    primary: Color(dark ? 0xffa8c7fa : 0xff0b57d0),
    onPrimary: Color(dark ? 0xff082b57 : 0xffffffff),
    primaryContainer: Color(dark ? 0xff142d50 : 0xffd3e3fd),
    onPrimaryContainer: Color(dark ? 0xffa8c7fa : 0xff0842a0),
    secondaryContainer: Color(dark ? 0xff142d50 : 0xffe8f0fe),
    onSecondaryContainer: Color(dark ? 0xffa8c7fa : 0xff0842a0),
    surface: Color(dark ? 0xff000000 : 0xfff0f4f9),
    surfaceContainerLowest: Color(dark ? 0xff000000 : 0xffffffff),
    surfaceContainerLow: Color(dark ? 0xff111418 : 0xffffffff),
    surfaceContainer: Color(dark ? 0xff171b21 : 0xfff8fafd),
    surfaceContainerHigh: Color(dark ? 0xff1c222b : 0xfff8fafd),
    onSurface: Color(dark ? 0xffe9ebef : 0xff1f1f1f),
    onSurfaceVariant: Color(dark ? 0xff9ba2ad : 0xff62676f),
    outline: Color(dark ? 0xff59616e : 0xff62676f),
    outlineVariant: Color(dark ? 0xff2a3039 : 0xffdfe5ed),
  );
}

/// Shared client surfaces; the user palette and pure-black mode stay intact.
ThemeData expressiveClientTheme(ThemeData base) {
  final scheme = base.colorScheme;
  final canvas = scheme.surface;
  final cardShape = RoundedRectangleBorder(
    borderRadius: const BorderRadius.all(Radius.circular(16)),
    side: BorderSide(color: scheme.outlineVariant),
  );
  const controlShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.all(Radius.circular(12)),
  );
  return base.copyWith(
    colorScheme: scheme,
    textTheme: base.textTheme.copyWith(
      headlineMedium: base.textTheme.headlineMedium?.copyWith(
        fontSize: 24,
        fontWeight: FontWeight.w600,
      ),
      titleMedium: base.textTheme.titleMedium?.copyWith(
        fontWeight: FontWeight.w600,
      ),
    ),
    scaffoldBackgroundColor: canvas,
    canvasColor: canvas,
    dividerColor: scheme.outlineVariant,
    splashFactory: InkRipple.splashFactory,
    appBarTheme: AppBarThemeData(
      backgroundColor: canvas,
      foregroundColor: scheme.onSurface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
    ),
    cardTheme: CardThemeData(
      color: scheme.surfaceContainerLow,
      elevation: 0,
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      shape: cardShape,
    ),
    listTileTheme: ListTileThemeData(
      iconColor: scheme.onSurfaceVariant,
      textColor: scheme.onSurface,
      titleTextStyle: base.textTheme.bodyLarge?.copyWith(
        color: scheme.onSurface,
      ),
      subtitleTextStyle: base.textTheme.bodyMedium?.copyWith(
        color: scheme.onSurfaceVariant,
      ),
      minVerticalPadding: 12,
      contentPadding: const EdgeInsets.symmetric(horizontal: 20),
    ),
    expansionTileTheme: ExpansionTileThemeData(
      backgroundColor: scheme.surfaceContainerLow,
      collapsedBackgroundColor: scheme.surfaceContainerLow,
      textColor: scheme.onSurface,
      collapsedTextColor: scheme.onSurface,
      iconColor: scheme.onSurfaceVariant,
      collapsedIconColor: scheme.onSurfaceVariant,
      shape: const Border(),
      collapsedShape: const Border(),
      tilePadding: const EdgeInsets.symmetric(horizontal: 20),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: scheme.surfaceContainerLow,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(18)),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: controlShape,
        minimumSize: const Size(64, 48),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        shape: controlShape,
        minimumSize: const Size(64, 48),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
    ),
    inputDecorationTheme: InputDecorationThemeData(
      filled: false,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      border: OutlineInputBorder(
        borderRadius: const BorderRadius.all(Radius.circular(10)),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: const BorderRadius.all(Radius.circular(10)),
        borderSide: BorderSide(color: scheme.primary, width: 2),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: scheme.surfaceContainer,
      elevation: 0,
      indicatorColor: scheme.secondaryContainer,
      indicatorShape: controlShape,
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: scheme.surfaceContainerLow,
      indicatorColor: scheme.secondaryContainer,
      indicatorShape: controlShape,
      selectedIconTheme: IconThemeData(color: scheme.onSecondaryContainer),
      unselectedIconTheme: IconThemeData(color: scheme.onSurfaceVariant),
    ),
    navigationDrawerTheme: NavigationDrawerThemeData(
      backgroundColor: scheme.surfaceContainerLow,
      elevation: 0,
      indicatorColor: scheme.secondaryContainer,
      indicatorShape: controlShape,
      indicatorSize: const Size(188, 56),
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return base.textTheme.titleSmall?.copyWith(
          fontSize: 16,
          color: selected
              ? scheme.onSecondaryContainer
              : scheme.onSurfaceVariant,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
        );
      }),
    ),
    drawerTheme: base.drawerTheme.copyWith(
      shape: const RoundedRectangleBorder(),
    ),
    floatingActionButtonTheme: base.floatingActionButtonTheme.copyWith(
      shape: controlShape,
      elevation: 1,
    ),
  );
}
