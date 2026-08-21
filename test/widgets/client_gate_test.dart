import 'package:fl_clash/common/theme.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/pages/client_gate.dart';
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('restores the client session only after core initialization', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    var sessionChecks = 0;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: _TestApp(
          child: ClientGate(
            sessionCheck: () async {
              sessionChecks += 1;
              return false;
            },
            child: const Text('home'),
          ),
        ),
      ),
    );

    await tester.pump();
    expect(sessionChecks, 0);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    container.read(initProvider.notifier).value = true;
    await tester.pumpAndSettle();

    expect(sessionChecks, 1);
    expect(find.byType(TextField), findsNWidgets(3));
  });

  testWidgets('enters the app with an existing encrypted session', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    var configSetups = 0;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: _TestApp(
          child: ClientGate(
            sessionCheck: () async => true,
            configSetup: () async {
              configSetups += 1;
              return '';
            },
            child: const Text('home'),
          ),
        ),
      ),
    );

    container.read(initProvider.notifier).value = true;
    await tester.pumpAndSettle();

    expect(configSetups, 1);
    expect(find.text('home'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
  });
}

class _TestApp extends StatelessWidget {
  final Widget child;

  const _TestApp({required this.child});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: globalState.navigatorKey,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.delegate.supportedLocales,
      builder: (context, child) {
        globalState.theme = CommonTheme.of(context, 1);
        return child!;
      },
      home: child,
    );
  }
}
