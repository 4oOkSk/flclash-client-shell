import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/common/theme.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/views/connection/item.dart';
import 'package:fl_clash/views/logs.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final width in [360.0, 900.0]) {
    testWidgets(
      'private details hide node endpoints at width $width',
      (tester) async {
        final container = ProviderContainer();
        globalState.container = container;
        addTearDown(container.dispose);
        tester.view.physicalSize = Size(width, 1200);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final tracker = TrackerInfo(
          id: 'endpoint',
          start: DateTime(2026),
          metadata: const Metadata(
            type: 'Tun',
            host: 'private-node.example.com',
            destinationIP: '192.0.2.10',
            destinationPort: '8443',
            network: 'tcp',
            specialRules: 'node.example.com:8443',
          ),
          chains: const ['Private-Node'],
          rule: 'Domain',
          rulePayload: 'node.example.com:8443',
          diagnosticDestination: 'server-endpoint',
        );

        Widget app(Widget child) => UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            locale: const Locale('en'),
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
            home: Scaffold(body: child),
          ),
        );

        await tester.pumpWidget(
          app(TrackerInfoDetailView(trackerInfo: tracker)),
        );
        await tester.pumpAndSettle();
        expect(find.text('[server-endpoint]'), findsNWidgets(2));
        for (final secret in [
          'node.example.com',
          '192.0.2.10',
          '8443',
          'Private-Node',
        ]) {
          expect(find.textContaining(secret), findsNothing);
        }
        expect(find.text('tcp'), findsOneWidget);
        expect(tester.takeException(), isNull);

        await tester.pumpWidget(
          app(
            const LogItem(
              log: Log(
                payload:
                    '[TCP] 198.18.0.1:1234 --> [server-endpoint] using Private-Node',
                dateTime: 'now',
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('[TCP] [server-endpoint]'), findsOneWidget);
        expect(find.textContaining('Private-Node'), findsNothing);
        expect(tester.takeException(), isNull);

        final ordinary = tracker.copyWith(
          diagnosticDestination: 'destination',
          metadata: const Metadata(
            host: 'example.com',
            destinationIP: '203.0.113.10',
            destinationPort: '443',
          ),
          rulePayload: '',
        );
        await tester.pumpWidget(
          app(TrackerInfoDetailView(trackerInfo: ordinary)),
        );
        await tester.pumpAndSettle();
        expect(find.text('example.com'), findsOneWidget);
        expect(find.text('203.0.113.10:443'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
      skip: !kPrivateClientMode,
    );
  }
}
