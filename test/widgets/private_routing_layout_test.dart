import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/common/private_client_theme.dart';
import 'package:fl_clash/common/theme.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/views/config/private_routing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

ProviderContainer _container(Size size) {
  final container = ProviderContainer(
    overrides: [
      globalRulesProvider.overrideWithBuild(
        (_, _) => Stream.value([
          const Rule(id: 1, content: 'example.com', ruleTarget: 'DIRECT'),
        ]),
      ),
    ],
  );
  globalState.container = container;
  container.read(viewSizeProvider.notifier).value = size;
  container.read(privateRouteStatusProvider.notifier).value =
      const PrivateRouteApplyState(phase: PrivateRouteApplyPhase.applied);
  return container;
}

void main() {
  testWidgets(
    'responsive routing preserves check input and validation result',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final container = _container(tester.view.physicalSize);
      addTearDown(container.dispose);
      await tester.pumpWidget(_RoutingTestApp(container: container));
      await tester.pumpAndSettle();
      final radios = find.byType(RadioListTile<ManagedRouteMode>);
      expect(radios, findsNWidgets(3));
      expect(
        tester.getTopLeft(radios.at(0)).dy,
        tester.getTopLeft(radios.at(2)).dy,
      );
      final exceptions = find.byKey(const ValueKey('route-exceptions-panel'));
      final checker = find.byKey(const ValueKey('route-check-panel'));
      expect(
        tester.getTopLeft(checker).dx,
        greaterThan(tester.getTopLeft(exceptions).dx),
      );
      expect(tester.getTopLeft(checker).dy, tester.getTopLeft(exceptions).dy);
      final input = find.byKey(const ValueKey('route-preview-destination'));
      await tester.enterText(input, '10.0.0.0/8');
      await tester.tap(find.widgetWithText(OutlinedButton, 'Check routing'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('route-preview-result')),
        findsOneWidget,
      );
      expect(
        find.text(AppLocalizations.current.routeInvalidDestination),
        findsOneWidget,
      );

      tester.view.physicalSize = const Size(420, 1600);
      await tester.pumpWidget(
        _RoutingTestApp(container: container, textScale: 1.4),
      );
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(radios.at(2)).dy,
        greaterThan(tester.getTopLeft(radios.at(0)).dy),
      );
      expect(
        tester.getTopLeft(checker).dy,
        greaterThan(tester.getBottomLeft(exceptions).dy),
      );
      expect(tester.widget<TextField>(input).controller!.text, '10.0.0.0/8');
      expect(
        find.text(AppLocalizations.current.routeInvalidDestination),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'busy routing stays disabled and reconnect still requires confirmation',
    (tester) async {
      tester.view.physicalSize = const Size(1100, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final container = _container(tester.view.physicalSize);
      addTearDown(container.dispose);
      container.read(privateRouteStatusProvider.notifier).value =
          const PrivateRouteApplyState(phase: PrivateRouteApplyPhase.applying);
      await tester.pumpWidget(_RoutingTestApp(container: container));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Proxy all'));
      await tester.pump();
      expect(
        container.read(networkSettingProvider).managedRouteMode,
        ManagedRouteMode.bypassMainland,
      );
      expect(
        tester
            .widget<PopupMenuButton<String>>(
              find.byType(PopupMenuButton<String>),
            )
            .enabled,
        isFalse,
      );

      container.read(privateRouteStatusProvider.notifier).value =
          const PrivateRouteApplyState(phase: PrivateRouteApplyPhase.failed);
      await tester.pumpAndSettle();
      expect(
        find.text(AppLocalizations.current.routeApplyFailed),
        findsOneWidget,
      );
      await tester.tap(find.byIcon(Icons.more_horiz));
      await tester.pumpAndSettle();
      await tester.tap(find.text(AppLocalizations.current.routeReconnect));
      await tester.pumpAndSettle();
      expect(
        find.textContaining(AppLocalizations.current.routeReconnectConfirm),
        findsOneWidget,
      );
      await tester.tap(find.text(AppLocalizations.current.cancel));
      await tester.pumpAndSettle();
      expect(
        find.textContaining(AppLocalizations.current.routeReconnectConfirm),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );
}

class _RoutingTestApp extends StatelessWidget {
  final ProviderContainer container;
  final double textScale;

  const _RoutingTestApp({required this.container, this.textScale = 1});

  @override
  Widget build(BuildContext context) => UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      navigatorKey: globalState.navigatorKey,
      theme: classicClientTheme(ThemeData(useMaterial3: true)),
      locale: const Locale('en'),
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.delegate.supportedLocales,
      builder: (context, child) {
        globalState.measure = Measure.of(context, textScale);
        globalState.theme = CommonTheme.of(context, textScale);
        return MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        );
      },
      home: const PrivateRoutingView(),
    ),
  );
}
