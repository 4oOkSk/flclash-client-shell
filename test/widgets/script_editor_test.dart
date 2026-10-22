import 'dart:async';
import 'dart:io';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/common/theme.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/pages/editor.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/views/config/scripts.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:re_editor/re_editor.dart';
import 'package:re_highlight/styles/atom-one-dark.dart';

import '../support/ui_visual.dart';

class _Paths extends PathProviderPlatform {
  final String root;
  _Paths(this.root);
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getTemporaryPath() async => root;
  @override
  Future<String?> getApplicationCachePath() async => root;
}

class _Saver extends ScriptAction {
  final calls = <(Script, String)>[];
  bool reject = false;
  Completer<Script>? pending;
  @override
  Future<Script> save(Script script, String content) async {
    calls.add((script, content));
    if (reject) throw ScriptNameConflict();
    return pending == null ? script : await pending!.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late PathProviderPlatform previous;
  late Script script;
  late _Saver saver;
  late ProviderContainer container;
  const body = 'function main(config) { return config; }';
  setUpAll(() async {
    await loadUiVisualFonts();
    root = await Directory.systemTemp.createTemp('script-editor-');
    previous = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(root.path);
    script = Script(
      id: 1,
      label: 'original',
      lastUpdateTime: DateTime.utc(2026),
    );
    final file = File(await script.path);
    await file.parent.create(recursive: true);
    await file.writeAsString(body);
  });
  tearDownAll(() async {
    PathProviderPlatform.instance = previous;
    await root.delete(recursive: true);
  });
  setUp(() {
    saver = _Saver();
    container = ProviderContainer(
      overrides: [
        scriptActionProvider.overrideWith(() => saver),
        scriptsProvider.overrideWithBuild((_, _) => Stream.value([script])),
      ],
    );
    globalState.container = container;
    container.read(viewSizeProvider.notifier).value = const Size(390, 800);
  });
  tearDown(() => container.dispose());

  Future<void> framesUntil(
    WidgetTester tester,
    bool Function() condition,
  ) async {
    for (var i = 0; i < 60; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 20));
      if (condition()) return;
    }
    fail('UI operation did not finish');
  }

  Future<void> openEditor(WidgetTester tester, {bool dark = false}) async {
    tester.view.physicalSize = const Size(390, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          navigatorKey: globalState.navigatorKey,
          theme: (dark ? ThemeData.dark() : ThemeData.light()).copyWith(
            textTheme: (dark ? ThemeData.dark() : ThemeData.light()).textTheme
                .apply(
                  fontFamily: uiVisualFont.isEmpty ? null : 'ClientVisual',
                ),
          ),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.delegate.supportedLocales,
          builder: (context, child) {
            globalState.theme = CommonTheme.of(context, 1);
            globalState.measure = Measure.of(context, 1);
            return RepaintBoundary(key: uiVisualKey, child: child!);
          },
          home: const ScriptsView(),
        ),
      ),
    );
    await framesUntil(
      tester,
      () => find.text('original').evaluate().isNotEmpty,
    );
    await tester.tap(find.text('original'));
    await tester.pump();
    await tester.tap(find.text(AppLocalizations.current.edit));
    await framesUntil(
      tester,
      () => find.byType(EditorPage).evaluate().isNotEmpty,
    );
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets(
    'title-only edit asks before leaving; cancel preserves it and save pops once',
    (tester) async {
      await openEditor(tester);
      await tester.enterText(find.byType(TextField).first, 'renamed');
      final cancelBack = globalState.navigatorKey.currentState!.maybePop();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text(AppLocalizations.current.saveChanges), findsOneWidget);
      await captureUi(tester, 'secondary-script-unsaved');
      await tester.tap(
        find.widgetWithText(TextButton, AppLocalizations.current.cancel),
      );
      await tester.pump(const Duration(milliseconds: 300));
      await cancelBack;
      expect(find.byType(EditorPage), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField).first).controller?.text,
        'renamed',
      );
      expect(saver.calls, isEmpty);
      final saveBack = globalState.navigatorKey.currentState!.maybePop();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(
        find.widgetWithText(TextButton, AppLocalizations.current.save),
      );
      await framesUntil(
        tester,
        () => find.byType(EditorPage).evaluate().isEmpty,
      );
      await saveBack;
      expect(find.byType(ScriptsView), findsOneWidget);
      expect(saver.calls, hasLength(1));
      expect(saver.calls.single.$1.label, 'renamed');
      expect(saver.calls.single.$2, body);
    },
  );

  testWidgets(
    'authoritative save failure leaves the editor and its draft intact',
    (tester) async {
      saver.reject = true;
      await openEditor(tester);
      await tester.enterText(find.byType(TextField).first, 'renamed');
      await tester.pump();
      await tester.tap(find.byTooltip(AppLocalizations.current.save));
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.text(
          AppLocalizations.current.existsTip(AppLocalizations.current.name),
        ),
        findsOneWidget,
      );
      expect(find.byType(EditorPage), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField).first).controller?.text,
        'renamed',
      );
      expect(saver.calls, hasLength(1));
      expect(
        await tester.runAsync(
          () async => File(await script.path).readAsString(),
        ),
        body,
      );
    },
  );

  testWidgets(
    'dismissing the save choice retains the draft; discard leaves without writing',
    (tester) async {
      await openEditor(tester);
      await tester.enterText(find.byType(TextField).first, 'unsaved');
      await globalState.navigatorKey.currentState!.maybePop();
      await tester.pump(const Duration(milliseconds: 300));
      await globalState.navigatorKey.currentState!.maybePop();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(EditorPage), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField).first).controller?.text,
        'unsaved',
      );
      await globalState.navigatorKey.currentState!.maybePop();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(
        find.widgetWithText(
          TextButton,
          AppLocalizations.current.discardChanges,
        ),
      );
      await framesUntil(
        tester,
        () => find.byType(EditorPage).evaluate().isEmpty,
      );
      expect(saver.calls, isEmpty);
      expect(find.byType(ScriptsView), findsOneWidget);
      expect(
        await tester.runAsync(
          () async => File(await script.path).readAsString(),
        ),
        body,
      );
    },
  );

  testWidgets(
    'dark syntax theme and pending-save guard keep one editable transaction',
    (tester) async {
      saver.pending = Completer<Script>();
      await openEditor(tester, dark: true);
      final editor = tester.widget<CodeEditor>(find.byType(CodeEditor));
      expect(editor.style?.codeTheme?.theme, atomOneDarkTheme);
      await captureUi(tester, 'secondary-script-dark');
      await tester.enterText(find.byType(TextField).first, 'renamed');
      await tester.pump();
      final save = tester
          .widget<IconButton>(
            find.byWidgetPredicate(
              (widget) =>
                  widget is IconButton &&
                  widget.tooltip == AppLocalizations.current.save,
            ),
          )
          .onPressed!;
      save();
      save();
      await tester.pump();
      expect(saver.calls, hasLength(1));
      expect(
        tester.widget<TextField>(find.byType(TextField).first).enabled,
        isFalse,
      );
      expect(
        tester.widget<CodeEditor>(find.byType(CodeEditor)).readOnly,
        isTrue,
      );
      saver.pending!.complete(script);
      await framesUntil(
        tester,
        () => find.byType(EditorPage).evaluate().isEmpty,
      );
    },
  );
}
