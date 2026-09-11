import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:fl_clash/providers/client_health.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('offline and stop invalidate a late successful health probe', (
    tester,
  ) async {
    final pending = Completer<int>();
    var count = 0;
    final container = ProviderContainer(
      overrides: [
        suspendProvider.overrideWithValue(false),
        clientHealthProbeProvider.overrideWithValue(() {
          count++;
          return pending.future;
        }),
      ],
    );
    addTearDown(container.dispose);
    container.read(runTimeProvider.notifier).value = 0;
    final health = container.read(clientHealthProvider.notifier);
    health.networkChanged([ConnectivityResult.wifi]);
    await tester.pump(const Duration(seconds: 1));
    expect(count, 1);
    health.networkChanged([ConnectivityResult.none]);
    expect(
      container.read(clientHealthProvider).phase,
      ClientHealthPhase.offline,
    );
    pending.complete(12);
    await tester.pump();
    expect(
      container.read(clientHealthProvider).phase,
      ClientHealthPhase.offline,
    );
    container.read(runTimeProvider.notifier).value = null;
    await tester.pump();
    expect(
      container.read(clientHealthProvider).phase,
      ClientHealthPhase.stopped,
    );
    await tester.pump(const Duration(minutes: 2));
    expect(count, 1);
  });

  testWidgets(
    'network recovery is debounced and health does not choose another server',
    (tester) async {
      var count = 0;
      final container = ProviderContainer(
        overrides: [
          suspendProvider.overrideWithValue(false),
          clientHealthProbeProvider.overrideWithValue(
            () async => ++count == 1 ? -1 : 42,
          ),
        ],
      );
      addTearDown(container.dispose);
      container.read(runTimeProvider.notifier).value = 1;
      final health = container.read(clientHealthProvider.notifier);
      health.networkChanged([ConnectivityResult.wifi]);
      health.networkChanged([ConnectivityResult.mobile]);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(count, 1);
      expect(
        container.read(clientHealthProvider).phase,
        ClientHealthPhase.unavailable,
      );
      health.refresh();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(
        container.read(clientHealthProvider).phase,
        ClientHealthPhase.reachable,
      );
      expect(container.read(clientHealthProvider).latencyMs, 42);
      container.read(runTimeProvider.notifier).value = null;
      expect(
        container.read(clientHealthProvider).phase,
        ClientHealthPhase.stopped,
      );
      await tester.pump(const Duration(milliseconds: 1));
    },
  );
}
