import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/views/views.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('managed client replaces the profiles slot with routing', (
    tester,
  ) async {
    late BuildContext testContext;
    await tester.pumpWidget(
      _LocalizedTestApp(
        child: Builder(
          builder: (context) {
            testContext = context;
            return const SizedBox();
          },
        ),
      ),
    );

    final item = navigation
        .getItems(managedClientMode: true)
        .singleWhere((item) => item.label == PageLabel.profiles);

    expect(item.icon.icon, Icons.route_outlined);
    expect(item.builder(testContext), isA<PrivateRoutingView>());
    expect(
      navigationItemLabel(testContext, item, managedClientMode: true),
      'Routing',
    );
  });

  testWidgets('generic client keeps the upstream profiles slot', (
    tester,
  ) async {
    late BuildContext testContext;
    await tester.pumpWidget(
      _LocalizedTestApp(
        child: Builder(
          builder: (context) {
            testContext = context;
            return const SizedBox();
          },
        ),
      ),
    );

    final item = navigation
        .getItems(managedClientMode: false)
        .singleWhere((item) => item.label == PageLabel.profiles);

    expect(item.icon.icon, Icons.folder);
    expect(item.builder(testContext), isA<ProfilesView>());
    expect(
      navigationItemLabel(testContext, item, managedClientMode: false),
      'Profiles',
    );
  });
}

class _LocalizedTestApp extends StatelessWidget {
  const _LocalizedTestApp({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.delegate.supportedLocales,
      home: child,
    );
  }
}
