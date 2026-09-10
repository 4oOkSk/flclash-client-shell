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
      expect(tester.getSize(find.byType(WindowHeader)).height, kToolbarHeight);
      await tester.tap(find.byIcon(Icons.remove));
      await tester.pump();
      expect(methods, contains('minimize'));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('inline root heading preserves a nested page title and back', (
    tester,
  ) async {
    await tester.pumpWidget(
      _ChromeTestApp(
        child: ClientWindowChromeScope(
          inlinePageTitles: true,
          child: Navigator(
            onGenerateRoute: (_) => MaterialPageRoute<void>(
              builder: (context) => CommonScaffold(
                title: 'Routing',
                managedRoot: true,
                body: Center(
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
    final rootTheme = Theme.of(tester.element(find.byType(AppBar)));
    expect(
      rootTheme.appBarTheme.backgroundColor,
      rootTheme.scaffoldBackgroundColor,
    );
    await tester.tap(find.text('Advanced'));
    await tester.pumpAndSettle();
    expect(find.text('Advanced routing'), findsOneWidget);
    expect(find.byType(BackButton), findsOneWidget);
    final detailTheme = Theme.of(tester.element(find.byType(AppBar).last));
    expect(
      detailTheme.appBarTheme.backgroundColor,
      detailTheme.colorScheme.primary,
    );
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('Routing'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
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
