import 'dart:async';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/common/theme.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/views/connection/connections.dart';
import 'package:fl_clash/views/connection/item.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  String title(int index) => 'tcp://host-$index.com:443';
  late ProviderContainer container;

  setUp(() {
    container = ProviderContainer();
    globalState.container = container;
  });

  tearDown(() {
    container.dispose();
  });

  List<TrackerInfo> buildConnections(int count) {
    return List.generate(
      count,
      (index) => TrackerInfo(
        id: '$index',
        start: DateTime(2024),
        metadata: Metadata(
          network: 'tcp',
          host: 'host-$index.com',
          destinationPort: '443',
        ),
        chains: const ['proxy-a'],
        rule: 'MATCH',
        rulePayload: '',
      ),
    );
  }

  Future<void> pumpConnections(
    WidgetTester tester, {
    required Future<List<TrackerInfo>> Function() connectionsReader,
    Future<void> Function(String)? connectionCloser,
    Future<void> Function()? allConnectionsCloser,
    bool isPageActive = true,
  }) async {
    tester.view.physicalSize = const Size(600, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: _TestApp(
          child: PageActivityScope(
            isActive: isPageActive,
            child: ConnectionsView(
              connectionsReader: connectionsReader,
              connectionCloser: connectionCloser,
              allConnectionsCloser: allConnectionsCloser,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets(
    'read failure keeps a labelled old snapshot and retry clears it',
    (tester) async {
      var failed = false;
      await pumpConnections(
        tester,
        connectionsReader: () async {
          if (failed) throw StateError('synthetic');
          return buildConnections(1);
        },
      );
      await tester.pump();
      failed = true;
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(find.text(title(0)), findsOneWidget);
      expect(
        find.text(AppLocalizations.current.connectionSnapshotStale),
        findsOneWidget,
      );
      failed = false;
      await tester.tap(find.byTooltip(AppLocalizations.current.retry));
      await tester.pump();
      expect(
        find.text(AppLocalizations.current.connectionSnapshotStale),
        findsNothing,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'one close rejects repeat taps, awaits result and reports failure',
    (tester) async {
      var calls = 0, reads = 0;
      final pending = Completer<void>();
      await pumpConnections(
        tester,
        connectionsReader: () async {
          reads++;
          return buildConnections(1);
        },
        connectionCloser: (_) {
          calls++;
          return pending.future;
        },
      );
      await tester.pump();
      final close = find.byTooltip(AppLocalizations.current.close);
      await tester.tap(close);
      await tester.pump();
      final button = tester.widget<IconButton>(
        find.byWidgetPredicate(
          (widget) =>
              widget is IconButton &&
              widget.tooltip == AppLocalizations.current.close,
        ),
      );
      expect(button.onPressed, isNull);
      expect(calls, 1);
      expect(reads, 1);
      pending.completeError(StateError('synthetic'));
      await tester.pump();
      expect(
        find.text(AppLocalizations.current.connectionCloseFailed),
        findsOneWidget,
      );
      expect(find.text(title(0)), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('bulk close confirms and refreshes only after acknowledgement', (
    tester,
  ) async {
    var calls = 0, reads = 0;
    final pending = Completer<void>();
    await pumpConnections(
      tester,
      connectionsReader: () async {
        reads++;
        return buildConnections(calls == 0 ? 1 : 0);
      },
      allConnectionsCloser: () {
        calls++;
        return pending.future;
      },
    );
    await tester.pump();
    await tester.tap(
      find.byTooltip(AppLocalizations.current.closeAllConnections),
    );
    await tester.pump(const Duration(milliseconds: 250));
    expect(calls, 0);
    await tester.tap(
      find.widgetWithText(
        TextButton,
        AppLocalizations.current.closeAllConnections,
      ),
    );
    await tester.pump(const Duration(milliseconds: 250));
    expect(calls, 1);
    expect(reads, 1);
    pending.complete();
    await tester.pump();
    await tester.pump();
    expect(reads, 2);
    expect(find.byType(TrackerInfoItem), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('ConnectionsView lazily builds every connection', (tester) async {
    final connections = buildConnections(100);

    await pumpConnections(tester, connectionsReader: () async => connections);
    await tester.pump();

    final builtItems = find.byType(TrackerInfoItem).evaluate().length;
    expect(builtItems, greaterThan(0));
    expect(builtItems, lessThan(connections.length));
    expect(find.text(title(0)), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text(title(99)),
      800,
      scrollable: find.byWidgetPredicate(
        (widget) =>
            widget is Scrollable &&
            widget.axisDirection == AxisDirection.down &&
            widget.controller != null,
      ),
    );

    expect(find.text(title(99)), findsOneWidget);
    expect(tester.takeException(), null);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('ConnectionsView polls only while the page is active', (
    tester,
  ) async {
    var readCount = 0;

    Future<List<TrackerInfo>> readConnections() async {
      readCount++;
      return const [];
    }

    await pumpConnections(
      tester,
      connectionsReader: readConnections,
      isPageActive: false,
    );
    await tester.pump(const Duration(seconds: 3));

    expect(readCount, 0);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: _TestApp(
          child: PageActivityScope(
            isActive: true,
            child: ConnectionsView(connectionsReader: readConnections),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(readCount, 1);

    await tester.pump(const Duration(seconds: 1));
    await tester.pump();

    expect(readCount, 2);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: _TestApp(
          child: PageActivityScope(
            isActive: false,
            child: ConnectionsView(connectionsReader: readConnections),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 3));

    expect(readCount, 2);
    expect(tester.takeException(), null);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('ConnectionsView stops polling while the app is paused', (
    tester,
  ) async {
    var readCount = 0;

    Future<List<TrackerInfo>> readConnections() async {
      readCount++;
      return const [];
    }

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await pumpConnections(tester, connectionsReader: readConnections);
    await tester.pump();

    expect(readCount, 1);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(seconds: 4));

    expect(readCount, 1);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();

    expect(readCount, 2);
    expect(tester.takeException(), null);

    await tester.pumpWidget(const SizedBox.shrink());
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
        globalState.measure = Measure.of(context, 1);
        globalState.theme = CommonTheme.of(context, 1);
        return child!;
      },
      home: child,
    );
  }
}
