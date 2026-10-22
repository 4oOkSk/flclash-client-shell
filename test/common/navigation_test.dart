import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/views/views.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('primary destinations use the generic client pages', () {
    final items = navigation.getItems(hasProxies: true);
    for (final mode in [
      NavigationItemMode.mobile,
      NavigationItemMode.desktop,
    ]) {
      expect(
        items
            .where((item) => item.modes.contains(mode))
            .map((item) => item.label),
        containsAll([
          PageLabel.dashboard,
          PageLabel.proxies,
          PageLabel.profiles,
          PageLabel.tools,
        ]),
      );
    }
  });

  testWidgets('profiles slot keeps the upstream profiles view', (tester) async {
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

    final item = navigation.getItems().singleWhere(
      (item) => item.label == PageLabel.profiles,
    );

    expect(item.icon.icon, Icons.folder);
    expect(item.builder(testContext), isA<ProfilesView>());
    expect(navigationItemLabel(testContext, item), 'Profiles');
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
