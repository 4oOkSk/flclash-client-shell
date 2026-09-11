import 'dart:async';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/common/private_client_theme.dart';
import 'package:fl_clash/common/theme.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/manager/theme_manager.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/views/config/private_routing.dart';
import 'package:fl_clash/views/proxies/private_client.dart';
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
  testWidgets('advanced routing restores expansion and scroll independently', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(640, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final container = _container(tester.view.physicalSize);
    addTearDown(container.dispose);
    final visible = ValueNotifier(true);
    addTearDown(visible.dispose);
    final bucket = PageStorageBucket();
    await tester.pumpWidget(
      _RoutingTestApp(
        container: container,
        home: PageStorage(
          bucket: bucket,
          child: ValueListenableBuilder<bool>(
            valueListenable: visible,
            builder: (_, showRouting, _) => showRouting
                ? const PrivateRoutingView()
                : const SizedBox.shrink(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final advanced = find.text(AppLocalizations.current.routeAdvanced);
    await tester.scrollUntilVisible(
      advanced,
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(advanced);
    await tester.pumpAndSettle();
    final offset = tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position
        .pixels;
    expect(offset, greaterThan(0));
    visible.value = false;
    await tester.pumpAndSettle();
    visible.value = true;
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(
      tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position
          .pixels,
      closeTo(offset, 0.1),
    );
    expect(
      ExpansibleController.of(tester.element(advanced)).isExpanded,
      isTrue,
    );
  });

  testWidgets(
    'late checker response is discarded after editing or applying rules',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final container = _container(tester.view.physicalSize);
      addTearDown(container.dispose);
      var pending = Completer<String>();
      await tester.pumpWidget(
        _RoutingTestApp(
          container: container,
          home: PrivateRoutingView(preview: (_) => pending.future),
        ),
      );
      await tester.pumpAndSettle();
      final input = find.byKey(const ValueKey('route-preview-destination'));
      for (final editInput in [true, false]) {
        pending = Completer<String>();
        await tester.enterText(input, '8.8.8.8');
        await tester.tap(
          find.widgetWithText(
            OutlinedButton,
            AppLocalizations.current.routeCheck,
          ),
        );
        await tester.pump();
        if (editInput) {
          await tester.enterText(input, '127.0.0.1');
        } else {
          container
              .read(privateRouteStatusProvider.notifier)
              .value = const PrivateRouteApplyState(
            phase: PrivateRouteApplyPhase.applying,
          );
          await tester.pump();
        }
        pending.complete(
          '{"status":"matched","action":"proxy","rule-index":1}',
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('route-preview-result')),
          findsNothing,
        );
      }
    },
  );

  testWidgets('server rows support large text and distinct aliases', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final container = _container(tester.view.physicalSize);
    addTearDown(container.dispose);
    container.read(groupsProvider.notifier).value = [
      const Group(
        type: GroupType.Selector,
        name: 'HARBORPROXY-SERVER',
        now: 'Backup',
        all: [
          Proxy(name: 'Backup', type: 'Vless'),
          Proxy(name: 'Backup ', type: 'Vless'),
        ],
      ),
    ];
    await tester.pumpWidget(
      _RoutingTestApp(
        container: container,
        textScale: 2,
        throughTheme: true,
        home: const PrivateClientProxiesView(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Backup · 1'), findsOneWidget);
    expect(find.text('Backup · 2'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('ThemeManager preserves system large text on a narrow phone', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final container = _container(tester.view.physicalSize);
    addTearDown(container.dispose);
    await tester.pumpWidget(
      _RoutingTestApp(container: container, textScale: 2, throughTheme: true),
    );
    await tester.pumpAndSettle();
    expect(
      MediaQuery.textScalerOf(
        tester.element(find.byType(PrivateRoutingView)),
      ).scale(16),
      32,
    );
    expect(tester.takeException(), isNull);
  });
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
      await tester.tap(
        find.widgetWithText(
          OutlinedButton,
          AppLocalizations.current.routeCheck,
        ),
      );
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
      await tester.enterText(input, 'example.org');
      await tester.pump();
      expect(find.byKey(const ValueKey('route-preview-result')), findsNothing);
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
      await tester.tap(find.text(AppLocalizations.current.clientAllProxy));
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
  final bool throughTheme;
  final Widget home;

  const _RoutingTestApp({
    required this.container,
    this.textScale = 1,
    this.throughTheme = false,
    this.home = const PrivateRoutingView(),
  });

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
          child: throughTheme ? ThemeManager(child: child!) : child!,
        );
      },
      home: home,
    ),
  );
}
