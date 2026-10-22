import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/common/theme.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/views/profiles/add.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('profile import offers file and validated URL actions', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    globalState.container = container;
    container.read(viewSizeProvider.notifier).value = const Size(800, 600);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
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
          home: const Scaffold(body: AddProfileView()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(ListItem), findsNWidgets(2));
    expect(find.byIcon(Icons.upload_file_sharp), findsOneWidget);
    await tester.tap(find.byIcon(Icons.link));
    await tester.pumpAndSettle();
    expect(find.byType(InputDialog), findsOneWidget);
    await tester.enterText(find.byType(TextFormField), 'not-a-url');
    await tester.tap(find.text(AppLocalizations.current.submit));
    await tester.pumpAndSettle();
    expect(find.byType(InputDialog), findsOneWidget);
    expect(
      find.text(
        AppLocalizations.current.urlTip(AppLocalizations.current.value),
      ),
      findsOneWidget,
    );
    await tester.tap(find.text(AppLocalizations.current.cancel));
    await tester.pumpAndSettle();
    expect(find.byType(InputDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
