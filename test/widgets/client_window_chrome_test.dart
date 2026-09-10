import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/common/private_client_theme.dart';
import 'package:fl_clash/common/theme.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/manager/window_manager.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'managed header keeps window controls reachable at narrow sizes',
    (tester) async {
      final methods = <String>[];
      const channel = MethodChannel('window_manager');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        methods.add(call.method);
        if (call.method == 'isMaximized' || call.method == 'isAlwaysOnTop') {
          return false;
        }
        return null;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      tester.view.physicalSize = const Size(380, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        const _ChromeTestApp(
          child: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(1.5)),
            child: Column(
              children: [
                WindowHeader(managed: true),
                Expanded(child: SizedBox()),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(appName), findsOneWidget);
      expect(tester.getSize(find.byType(WindowHeader)).height, 48);
      await tester.tap(find.byIcon(Icons.remove));
      await tester.pump();
      expect(methods, contains('minimize'));
      expect(tester.takeException(), isNull);
    },
  );

  for (final size in [const Size(390, 844), const Size(1440, 900)]) {
    testWidgets(
      'root omits title space and retains nested navigation at $size',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          _ChromeTestApp(
            child: MediaQuery(
              data: MediaQueryData(
                size: size,
                padding: const EdgeInsets.only(top: 24),
              ),
              child: Navigator(
                onGenerateRoute: (_) => MaterialPageRoute<void>(
                  builder: (context) => CommonScaffold(
                    title: 'Routing',
                    managedRoot: true,
                    body: Align(
                      key: const ValueKey('root-body'),
                      alignment: Alignment.topLeft,
                      child: TextButton(
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const CommonScaffold(
                              title: 'Advanced routing',
                              body: SizedBox(),
                            ),
                          ),
                        ),
                        child: const Text('Advanced'),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Routing'), findsNothing);
        expect(find.byType(AppBar), findsNothing);
        expect(
          tester.getTopLeft(find.byKey(const ValueKey('root-body'))).dy,
          24,
        );
        expect(
          tester.getSize(find.byKey(const ValueKey('root-body'))).width,
          lessThanOrEqualTo(1040),
        );
        await tester.tap(find.text('Advanced'));
        await tester.pumpAndSettle();
        expect(find.text('Advanced routing'), findsOneWidget);
        expect(find.byType(BackButton), findsOneWidget);
        final detailTheme = Theme.of(tester.element(find.byType(AppBar).last));
        expect(
          detailTheme.appBarTheme.backgroundColor,
          detailTheme.scaffoldBackgroundColor,
        );
        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
        expect(find.text('Routing'), findsNothing);
        expect(find.byType(AppBar), findsNothing);
        expect(find.text('Advanced'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('managed root preserves an action-bearing toolbar', (
    tester,
  ) async {
    var invoked = false;
    await tester.pumpWidget(
      _ChromeTestApp(
        child: CommonScaffold(
          title: 'Routing',
          managedRoot: true,
          actions: [
            IconButton(
              onPressed: () => invoked = true,
              icon: const Icon(Icons.refresh),
            ),
          ],
          body: const SizedBox(),
        ),
      ),
    );
    await tester.tap(find.byIcon(Icons.refresh));
    expect(invoked, isTrue);
    expect(find.text('Routing'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final brightness in Brightness.values) {
    test('managed chrome shares a neutral canvas in $brightness', () {
      final theme = classicClientTheme(ThemeData(brightness: brightness));
      expect(theme.appBarTheme.backgroundColor, theme.scaffoldBackgroundColor);
      expect(
        theme.navigationRailTheme.backgroundColor,
        theme.scaffoldBackgroundColor,
      );
      expect(
        theme.navigationBarTheme.backgroundColor,
        theme.scaffoldBackgroundColor,
      );
      expect(theme.appBarTheme.foregroundColor, theme.colorScheme.onSurface);
      expect(
        theme.appBarTheme.backgroundColor,
        isNot(theme.colorScheme.primary),
      );
    });
  }
}

class _ChromeTestApp extends StatelessWidget {
  final Widget child;

  const _ChromeTestApp({required this.child});

  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: classicClientTheme(ThemeData(useMaterial3: true)),
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    supportedLocales: AppLocalizations.delegate.supportedLocales,
    builder: (context, child) {
      globalState.measure = Measure.of(context, 1);
      globalState.theme = CommonTheme.of(context, 1);
      return child!;
    },
    home: child,
  );
}
