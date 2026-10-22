import 'dart:async';

import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod/riverpod.dart';

class _StartupAction extends SystemAction {
  final calls = <bool>[];
  bool actual = false;
  bool fail = false;
  Completer<void>? release;

  @override
  Future<void> registerAutoLaunch(bool enabled) async {
    calls.add(enabled);
    await release?.future;
    if (fail) throw StateError('denied');
    actual = enabled;
  }

  @override
  Future<bool> readAutoLaunch() async => actual;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async => AppLocalizations.load(const Locale('en')));

  test('startup preference changes only after OS acknowledgment', () async {
    final action = _StartupAction()..release = Completer<void>();
    final container = ProviderContainer(
      overrides: [systemActionProvider.overrideWith(() => action)],
    );
    addTearDown(container.dispose);
    container.listen(configProvider, (_, _) {});
    final pending = container
        .read(systemActionProvider.notifier)
        .updateAutoLaunch(true);
    await Future<void>.delayed(Duration.zero);
    expect(container.read(appSettingProvider).autoLaunch, false);
    action.release!.complete();
    await pending;
    expect(container.read(appSettingProvider).autoLaunch, true);
  });

  test(
    'failed startup reconciliation clears stale enabled preference',
    () async {
      final action = _StartupAction()..fail = true;
      final container = ProviderContainer(
        overrides: [systemActionProvider.overrideWith(() => action)],
      );
      addTearDown(container.dispose);
      container.listen(configProvider, (_, _) {});
      container
          .read(appSettingProvider.notifier)
          .update((s) => s.copyWith(autoLaunch: true));
      await container
          .read(systemActionProvider.notifier)
          .updateAutoLaunch(true);
      expect(container.read(appSettingProvider).autoLaunch, false);
    },
  );

  test(
    'rapid startup requests are serialized and use the latest explicit value',
    () async {
      final action = _StartupAction()..release = Completer<void>();
      final container = ProviderContainer(
        overrides: [systemActionProvider.overrideWith(() => action)],
      );
      addTearDown(container.dispose);
      container.listen(configProvider, (_, _) {});
      final first = container
          .read(systemActionProvider.notifier)
          .updateAutoLaunch(true);
      final second = container
          .read(systemActionProvider.notifier)
          .updateAutoLaunch(false);
      await Future<void>.delayed(Duration.zero);
      expect(action.calls, [true]);
      action.release!.complete();
      await Future.wait([first, second]);
      expect(action.calls, [true, false]);
      expect(container.read(appSettingProvider).autoLaunch, false);
    },
  );
}
