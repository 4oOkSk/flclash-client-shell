import 'package:fl_clash/common/private_client_theme.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/views/config/private_route_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'simple editor saves normalized routing intent and rejects credential URLs',
    (tester) async {
      Rule? saved;
      await tester.pumpWidget(
        MaterialApp(
          theme: classicClientTheme(ThemeData(useMaterial3: true)),
          locale: const Locale('en'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.delegate.supportedLocales,
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  saved = await showDialog<Rule>(
                    context: context,
                    builder: (_) => const PrivateRouteEditor(),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('route-destination')),
        'https://user:password@example.com',
      );
      await tester.tap(find.text('Save and apply'));
      await tester.pumpAndSettle();
      expect(saved, isNull);
      expect(find.byType(PrivateRouteEditor), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('route-destination')),
        'https://Example.com/a?b=1',
      );
      await tester.tap(find.text('Save and apply'));
      await tester.pumpAndSettle();
      expect(saved?.rawValue, 'DOMAIN-SUFFIX,example.com,HARBORPROXY-SERVER');
      expect(tester.takeException(), isNull);
    },
  );
}
