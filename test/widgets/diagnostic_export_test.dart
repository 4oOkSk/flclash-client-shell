import 'dart:async';
import 'dart:convert';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/common/diagnostic_journal.dart';
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
import 'package:fl_clash/widgets/list.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:package_info_plus/package_info_plus.dart';

class _CoreHandler extends Mock implements CoreHandlerInterface {}

class _MemoryJournal extends DiagnosticJournal {
  @override
  Future<List<int>> snapshot() async => utf8.encode(
    '{"time":"2026-09-14T00:00:00.000Z","elapsedMs":0,"event":"startup"}\n',
  );
}

class _PendingJournal extends DiagnosticJournal {
  final Completer<List<int>> pending;

  _PendingJournal(this.pending);

  @override
  Future<List<int>> snapshot() => pending.future;
}

void main() {
  late ProviderContainer container;
  late _CoreHandler handler;
  late CoreController controller;
  final reports = <String>[];
  var failClipboard = false;
  var failUpload = false;
  final uploadCalls = <Map<String, Object?>>[];

  setUpAll(() {
    registerFallbackValue(<String, Object?>{});
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
    failUpload = false;
    uploadCalls.clear();
    when(() => handler.clientDiagnosticUpload(any(), any())).thenAnswer((
      call,
    ) async {
      final body = call.positionalArguments[1] as Map<String, Object?>;
      uploadCalls.add(body);
      if (failUpload) return '{"ret":0,"error":"invalid"}';
      return switch (body['action']) {
        'begin' => jsonEncode({'ret': 1, 'id': 'a' * 32}),
        'status' =>
          '{"ret":1,"state":"ready","url":"https://logs.example/files/harborproxylogs/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.jsonl"}',
        _ => '{"ret":1}',
      };
    });
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
        find.descendant(
          of: find.byType(DiagnosticExportItem),
          matching: find.byType(ClientListDivider),
        ),
        findsOneWidget,
      );
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
      final tile = tester.widget<ExpansionTile>(
        find.byKey(const PageStorageKey('tools-advanced')),
      );
      expect(tile.children.first, isA<ClientListDivider>());
      expect(tile.children.last, isNot(isA<ClientListDivider>()));
      for (var index = 0; index < tile.children.length; index++) {
        expect(tile.children[index] is ClientListDivider, index.isEven);
      }
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

  testWidgets('uploads once, copies only the link and ignores duplicate taps', (
    tester,
  ) async {
    final pending = Completer<List<String>>();
    when(
      () => handler.getPlatformDiagnosticLogs(),
    ).thenAnswer((_) => pending.future);
    await tester.pumpWidget(
      _TestApp(
        container: container,
        child: DiagnosticExportItem(
          controller: controller,
          journal: _MemoryJournal(),
        ),
      ),
    );
    final upload = find.text(AppLocalizations.current.clientCopyDiagnostics);
    await tester.tap(upload);
    await tester.pump();
    await tester.tap(upload);
    pending.complete(['host=private.example.com token=do-not-copy-this']);
    await tester.pumpAndSettle();
    expect(reports, [
      'https://logs.example/files/harborproxylogs/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.jsonl',
    ]);
    expect(
      uploadCalls.where((body) => body['action'] == 'begin'),
      hasLength(1),
    );
    expect(
      find.text(AppLocalizations.current.clientDiagnosticUploaded),
      findsOneWidget,
    );
    await tester.tap(find.text(AppLocalizations.current.confirm));
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'clipboard failure leaves a selectable link and retry does not reupload',
    (tester) async {
      failClipboard = true;
      await tester.pumpWidget(
        _TestApp(
          container: container,
          child: DiagnosticExportItem(
            controller: controller,
            journal: _MemoryJournal(),
          ),
        ),
      );
      final upload = find.text(AppLocalizations.current.clientCopyDiagnostics);
      await tester.tap(upload);
      await tester.pumpAndSettle();
      expect(
        find.text(AppLocalizations.current.clientDiagnosticCopyLinkFailed),
        findsOneWidget,
      );
      expect(find.byType(SelectableText), findsOneWidget);
      await tester.tap(find.text(AppLocalizations.current.confirm));
      await tester.pumpAndSettle();
      failClipboard = false;
      await tester.tap(upload);
      await tester.pumpAndSettle();
      expect(reports, hasLength(1));
      expect(
        uploadCalls.where((body) => body['action'] == 'begin'),
        hasLength(1),
      );
      await tester.tap(find.text(AppLocalizations.current.confirm));
      await tester.pumpAndSettle();
      expect(find.byType(CircularProgressIndicator), findsNothing);
    },
  );

  testWidgets(
    'upload failure keeps file export available without a false link',
    (tester) async {
      failUpload = true;
      await tester.pumpWidget(
        _TestApp(
          container: container,
          child: DiagnosticExportItem(
            controller: controller,
            journal: _MemoryJournal(),
          ),
        ),
      );
      await tester.tap(
        find.text(AppLocalizations.current.clientCopyDiagnostics),
      );
      await tester.pumpAndSettle();
      expect(reports, isEmpty);
      expect(
        find.text(AppLocalizations.current.clientCopyDiagnosticsFailed),
        findsOneWidget,
      );
      expect(
        find.text(AppLocalizations.current.clientDiagnosticSave),
        findsOneWidget,
      );
      expect(find.byType(CircularProgressIndicator), findsNothing);
    },
  );

  testWidgets(
    'saving shows progress only on the save row and clears on error',
    (tester) async {
      final pending = Completer<List<int>>();
      await tester.pumpWidget(
        _TestApp(
          container: container,
          child: DiagnosticExportItem(
            controller: controller,
            journal: _PendingJournal(pending),
          ),
        ),
      );
      final save = find.widgetWithText(
        ListItem,
        AppLocalizations.current.clientDiagnosticSave,
      );
      final upload = find.widgetWithText(
        ListItem,
        AppLocalizations.current.clientCopyDiagnostics,
      );
      await tester.tap(save);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));
      expect(
        find.descendant(
          of: save,
          matching: find.byType(CircularProgressIndicator),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: upload,
          matching: find.byType(CircularProgressIndicator),
        ),
        findsNothing,
      );
      pending.completeError(StateError('test storage failure'));
      await tester.pumpAndSettle();
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(uploadCalls, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('leaving during collection does not upload or copy', (
    tester,
  ) async {
    final pending = Completer<List<String>>();
    when(
      () => handler.getPlatformDiagnosticLogs(),
    ).thenAnswer((_) => pending.future);
    await tester.pumpWidget(
      _TestApp(
        container: container,
        child: DiagnosticExportItem(
          controller: controller,
          journal: _MemoryJournal(),
        ),
      ),
    );
    await tester.tap(find.text(AppLocalizations.current.clientCopyDiagnostics));
    await tester.pumpWidget(const SizedBox.shrink());
    pending.complete([]);
    await tester.pumpAndSettle();
    expect(reports, isEmpty);
    expect(uploadCalls, isEmpty);
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
