import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/common/theme.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/state.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/views/dashboard/dashboard.dart';
import 'package:fl_clash/views/dashboard/widgets/private_client_account.dart';
import 'package:fl_clash/widgets/grid.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'standalone account summary grows for tall text instead of clipping',
    (tester) async {
      final container = ProviderContainer(
        overrides: [
          privateClientAccountInfoProvider.overrideWith((_) async => null),
        ],
      );
      addTearDown(container.dispose);
      globalState.container = container;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: _TestApp(
            child: Builder(
              builder: (context) => Theme(
                data: Theme.of(context).copyWith(
                  textTheme: Theme.of(context).textTheme.copyWith(
                    bodySmall: const TextStyle(fontSize: 18, height: 2.5),
                  ),
                ),
                child: const Scaffold(
                  body: SingleChildScrollView(
                    child: SizedBox(
                      width: 390,
                      child: PrivateClientAccountCard(adaptive: true),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        find.text(AppLocalizations.current.clientDataRemaining),
        findsOneWidget,
      );
      expect(
        tester.getSize(find.byType(PrivateClientAccountCard)).height,
        greaterThan(100),
      );
    },
  );

  testWidgets('account and website cards follow locale changes and errors', (
    tester,
  ) async {
    var failAccount = false;
    final container = ProviderContainer(
      overrides: [
        privateClientAccountInfoProvider.overrideWith((_) async {
          if (failAccount) throw StateError('account unavailable');
          return const PrivateClientAccountInfo(
            remainingBytes: 1048576,
            expireAt: 1800000000,
          );
        }),
      ],
    );
    addTearDown(container.dispose);
    globalState.container = container;
    for (final locale in [const Locale('en'), const Locale('zh', 'CN')]) {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: _TestApp(
            locale: locale,
            child: const Scaffold(
              body: SizedBox(
                width: 360,
                child: Column(
                  children: [
                    PrivateClientAccountCard(adaptive: true),
                    PrivateClientWebsiteCard(),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final text = AppLocalizations.current;
      for (final label in [
        text.clientAccountOverview,
        text.clientDataRemaining,
        text.clientExpiresOn,
        text.clientOfficialWebsite,
        text.clientVisitWebsite,
      ]) {
        expect(find.text(label), findsOneWidget);
      }
      if (locale.languageCode == 'en') {
        expect(find.textContaining(RegExp(r'[\u4e00-\u9fff]')), findsNothing);
      }
      failAccount = true;
      container.invalidate(privateClientAccountInfoProvider);
      await tester.pumpAndSettle();
      expect(find.text(text.clientAccountUnavailable), findsOneWidget);
      expect(tester.takeException(), isNull);
      failAccount = false;
      container.invalidate(privateClientAccountInfoProvider);
    }
  });

  testWidgets('dashboard limits a wide grid to 16 centered columns', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final container = ProviderContainer(
      overrides: [
        dashboardStateProvider.overrideWithValue(
          const DashboardState(dashboardWidgets: []),
        ),
      ],
    );
    addTearDown(container.dispose);
    globalState.container = container;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const _TestApp(child: DashboardView()),
      ),
    );
    await tester.pump();

    final grid = find.byType(Grid);
    expect(tester.widget<Grid>(grid).crossAxisCount, 16);
    expect(tester.getSize(grid).width, 1120);
    expect(tester.getTopLeft(grid).dx, 240);
    expect(tester.takeException(), null);
  });
}

class _TestApp extends StatelessWidget {
  final Widget child;
  final Locale locale;

  const _TestApp({required this.child, this.locale = const Locale('en')});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      locale: locale,
      navigatorKey: globalState.navigatorKey,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
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
}
