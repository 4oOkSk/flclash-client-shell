import 'dart:async';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/common/private_client_theme.dart';
import 'package:fl_clash/common/theme.dart';
import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/core/interface.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/views/diagnostic_export.dart';
import 'package:fl_clash/views/tools.dart';
import 'package:fl_clash/views/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:package_info_plus/package_info_plus.dart';

class _CoreHandler extends Mock implements CoreHandlerInterface {}

void main() {
  late ProviderContainer container;
  late _CoreHandler handler;
  late CoreController controller;
  final reports = <String>[];
  var failClipboard = false;

  setUpAll(() {
    globalState.appEnv = 'stable';
    globalState.coreSHA256 = '';
    globalState.packageInfo = PackageInfo(
      appName: 'Test client',
      packageName: 'example.test',
      version: '0.0.1',
      buildNumber: '1',
    );
  });

  setUp(() {
    container = ProviderContainer(
      overrides: [
        privateClientAccountInfoProvider.overrideWith((_) async => null),
        moreToolsSelectorStateProvider.overrideWithValue(
          const MoreToolsSelectorState(navigationItems: []),
        ),
      ],
    );
    globalState.container = container;
    handler = _CoreHandler();
    controller = CoreController.test(handler);
    when(() => handler.getPlatformDiagnosticLogs()).thenAnswer(
      (_) async => ['host=private.example.com token=do-not-copy-this'],
    );
    when(() => handler.clientDiagnostics()).thenAnswer(
      (_) async => '{"session_present":true,"unexpected_server":"secret-node"}',
    );
    when(
      () => handler.getConnections(),
    ).thenAnswer((_) async => <TrackerInfo>[]);
    reports.clear();
    failClipboard = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            if (failClipboard) throw PlatformException(code: 'clipboard-error');
            reports.add((call.arguments as Map)['text'] as String);
          }
          return null;
        });
  });

  tearDown(() {
    container.dispose();
    CoreController.resetInstance();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  testWidgets(
    'diagnostic menu retains export without other destinations',
    (tester) async {
      await tester.pumpWidget(
        _TestApp(container: container, child: const ToolsView()),
      );
      await tester.pumpAndSettle();
      final diagnostics = find.text(AppLocalizations.current.clientDiagnostics);
      await tester.ensureVisible(diagnostics);
      await tester.tap(diagnostics);
      await tester.pumpAndSettle();
      expect(find.byType(DiagnosticExportItem), findsOneWidget);
      expect(
        find.text(AppLocalizations.current.clientCopyDiagnostics),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
    skip: !kPrivateClientMode,
  );

  testWidgets(
    'account expansion state does not overwrite the saved scroll offset',
    (tester) async {
      final visible = ValueNotifier(true);
      addTearDown(visible.dispose);
      final bucket = PageStorageBucket();
      await tester.pumpWidget(
        _TestApp(
          container: container,
          child: PageStorage(
            bucket: bucket,
            child: ValueListenableBuilder<bool>(
              valueListenable: visible,
              builder: (_, showAccount, _) =>
                  showAccount ? const ToolsView() : const SizedBox.shrink(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final diagnostics = find.text(AppLocalizations.current.clientDiagnostics);
      await tester.ensureVisible(diagnostics);
      await tester.tap(diagnostics);
      await tester.pumpAndSettle();
      expect(find.byType(DiagnosticExportItem), findsOneWidget);

      visible.value = false;
      await tester.pumpAndSettle();
      visible.value = true;
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byType(DiagnosticExportItem), findsOneWidget);
      final advanced = find.text(AppLocalizations.current.advancedConfig);
      await tester.scrollUntilVisible(
        advanced,
        250,
        scrollable: find.byType(Scrollable).first,
      );
      expect(tester.takeException(), isNull);
      final advancedTile = find.ancestor(
        of: advanced,
        matching: find.byType(ExpansionTile),
      );
      expect(
        ExpansibleController.of(tester.element(advanced)).isExpanded,
        isFalse,
      );
      await tester.tap(advancedTile);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
    skip: !kPrivateClientMode,
  );

  for (final size in [const Size(640, 700), const Size(390, 800)]) {
    testWidgets(
      'expanded diagnostics survives a settings round trip at $size',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        container.read(viewSizeProvider.notifier).value = size;
        await tester.pumpWidget(
          _TestApp(container: container, child: const ToolsView()),
        );
        await tester.pumpAndSettle();
        final diagnostics = find.text(
          AppLocalizations.current.clientDiagnostics,
        );
        await tester.ensureVisible(diagnostics);
        await tester.tap(diagnostics);
        await tester.pumpAndSettle();
        final theme = find.text(AppLocalizations.current.theme);
        await tester.scrollUntilVisible(
          theme,
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.tap(theme);
        await tester.pumpAndSettle();
        expect(find.byType(ThemeView), findsOneWidget);
        globalState.navigatorKey.currentState!.pop();
        await tester.pumpAndSettle();
        expect(find.byType(ThemeView), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.scrollUntilVisible(
          diagnostics,
          -200,
          scrollable: find.byType(Scrollable).first,
        );
        expect(find.byType(DiagnosticExportItem), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
      skip: !kPrivateClientMode,
    );
  }

  testWidgets('copies redacted diagnostics and ignores duplicate taps', (
    tester,
  ) async {
    final pending = Completer<List<String>>();
    when(
      () => handler.getPlatformDiagnosticLogs(),
    ).thenAnswer((_) => pending.future);
    await tester.pumpWidget(
      _TestApp(
        container: container,
        child: DiagnosticExportItem(controller: controller),
      ),
    );
    final copy = find.text(AppLocalizations.current.clientCopyDiagnostics);
    await tester.tap(copy);
    await tester.pump();
    await tester.tap(copy);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    pending.complete(['host=private.example.com token=do-not-copy-this']);
    await tester.pumpAndSettle();
    expect(reports, hasLength(1));
    expect(reports.single, contains('diagnostic report'));
    expect(reports.single, contains('client.sessionPresent=true'));
    expect(reports.single, contains('collection.connections=ok'));
    expect(
      reports.single,
      contains('probe.scope=core-outbound only (not browser or VPN path)'),
    );
    for (final secret in [
      'private.example.com',
      'do-not-copy-this',
      'secret-node',
    ]) {
      expect(reports.single, isNot(contains(secret)));
    }
    expect(find.text(AppLocalizations.current.copySuccess), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    verify(() => handler.getPlatformDiagnosticLogs()).called(1);
  });

  testWidgets('clipboard failure clears busy state and allows retry', (
    tester,
  ) async {
    failClipboard = true;
    await tester.pumpWidget(
      _TestApp(
        container: container,
        child: DiagnosticExportItem(controller: controller),
      ),
    );
    final copy = find.text(AppLocalizations.current.clientCopyDiagnostics);
    await tester.tap(copy);
    await tester.pumpAndSettle();
    expect(
      find.text(AppLocalizations.current.clientCopyDiagnosticsFailed),
      findsOneWidget,
    );
    expect(find.byType(CircularProgressIndicator), findsNothing);
    failClipboard = false;
    await tester.tap(copy);
    await tester.pumpAndSettle();
    expect(reports, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('collection failures are explicit instead of appearing healthy', (
    tester,
  ) async {
    when(
      () => handler.clientDiagnostics(),
    ).thenAnswer((_) async => 'invalid json');
    when(
      () => handler.getConnections(),
    ).thenAnswer((_) async => throw StateError('secret-node'));
    await tester.pumpWidget(
      _TestApp(
        container: container,
        child: DiagnosticExportItem(controller: controller),
      ),
    );
    await tester.tap(find.text(AppLocalizations.current.clientCopyDiagnostics));
    await tester.pumpAndSettle();

    expect(reports, hasLength(1));
    expect(
      reports.single,
      contains('collection.runtime=unavailable:FormatException'),
    );
    expect(
      reports.single,
      contains('collection.connections=unavailable:StateError'),
    );
    expect(reports.single, isNot(contains('secret-node')));
  });

  testWidgets('leaving during collection does not write to the clipboard', (
    tester,
  ) async {
    final pending = Completer<List<String>>();
    when(
      () => handler.getPlatformDiagnosticLogs(),
    ).thenAnswer((_) => pending.future);
    await tester.pumpWidget(
      _TestApp(
        container: container,
        child: DiagnosticExportItem(controller: controller),
      ),
    );
    await tester.tap(find.text(AppLocalizations.current.clientCopyDiagnostics));
    await tester.pumpWidget(const SizedBox.shrink());
    pending.complete([]);
    await tester.pumpAndSettle();
    expect(reports, isEmpty);
    expect(tester.takeException(), isNull);
  });
}

class _TestApp extends StatelessWidget {
  final ProviderContainer container;
  final Widget child;

  const _TestApp({required this.container, required this.child});

  @override
  Widget build(BuildContext context) {
    return UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        navigatorKey: globalState.navigatorKey,
        theme: classicClientTheme(ThemeData()),
        locale: const Locale('en'),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
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
  }
}
