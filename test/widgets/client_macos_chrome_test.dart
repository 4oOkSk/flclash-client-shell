import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/manager/window_manager.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'macOS reserves native controls across window widths and routes',
    (tester) async {
      const channel = MethodChannel('window_manager');
      final methods = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        methods.add(call.method);
        return false;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final container = ProviderContainer(
        overrides: [versionProvider.overrideWithBuild((_, _) => 27)],
      );
      addTearDown(container.dispose);
      final navigator = GlobalKey<NavigatorState>();
      const pageKey = ValueKey('page');
      for (final width in [380.0, 599.0, 600.0, 680.0, 839.0, 840.0, 1200.0]) {
        final size = Size(width, 700);
        tester.view.physicalSize = size;
        container.read(viewSizeProvider.notifier).value = size;
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              builder: (_, child) => WindowHeaderContainer(child: child!),
              navigatorKey: navigator,
              home: const SizedBox.expand(key: pageKey),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(WindowHeader), findsOneWidget);
        expect(tester.getTopLeft(find.byKey(pageKey)).dy, kHeaderHeight);
        expect(
          container.read(overlayTopOffsetProvider),
          kToolbarHeight + kHeaderHeight,
        );
        navigator.currentState!.push<void>(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('Details')),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.getTopLeft(find.byType(Scaffold)).dy, kHeaderHeight);
        navigator.currentState!.pop();
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
      await tester.drag(find.byType(WindowHeader), const Offset(40, 0));
      await tester.pumpAndSettle();
      expect(methods, contains('startDragging'));
      await tester.tap(find.byType(WindowHeader));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.byType(WindowHeader));
      await tester.pumpAndSettle();
      expect(methods, contains('maximize'));
    },
    skip: !system.isMacOS,
  );
}
