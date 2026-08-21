import 'dart:async';

import 'package:fl_clash/common/private_route.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const managedRouting = PrivateManagedRouting(
    mode: ManagedRouteMode.bypassOverseas,
  );
  const baseOverlay = PrivateRouteOverlay(
    rules: ['DOMAIN,example.com,REJECT'],
    managedRouting: managedRouting,
  );
  const fullOverlay = PrivateRouteOverlay(
    rules: ['DOMAIN,example.net,REJECT', 'DOMAIN,example.com,REJECT'],
    managedRouting: managedRouting,
  );

  group('selectPrivateRouteSnapshot', () {
    test('optimistic state ahead of DAO wins', () async {
      var coldLoads = 0;
      final snapshot = await selectPrivateRouteSnapshot(
        hasOptimisticValue: true,
        optimisticValue: const ['optimistic'],
        loadCold: () async {
          coldLoads += 1;
          return const ['stale'];
        },
      );

      expect(snapshot, ['optimistic']);
      expect(coldLoads, 0);
    });

    test('loading state falls back to DAO', () async {
      var coldLoads = 0;
      final snapshot = await selectPrivateRouteSnapshot(
        hasOptimisticValue: false,
        optimisticValue: const <String>[],
        loadCold: () async {
          coldLoads += 1;
          return const ['persisted'];
        },
      );

      expect(snapshot, ['persisted']);
      expect(coldLoads, 1);
    });

    test('optimistic empty delete does not resurrect stale DAO rows', () async {
      var coldLoads = 0;
      final snapshot = await selectPrivateRouteSnapshot(
        hasOptimisticValue: true,
        optimisticValue: const <String>[],
        loadCold: () async {
          coldLoads += 1;
          return const ['deleted-but-not-flushed'];
        },
      );

      expect(snapshot, isEmpty);
      expect(coldLoads, 0);
    });

    test('missing cold script does not clear a newer active id', () async {
      var activeScriptId = 1;
      final coldLoadStarted = Completer<void>();
      final finishColdLoad = Completer<void>();
      final scriptFuture = selectPrivateRouteScriptSnapshot(
        scriptId: activeScriptId,
        hasOptimisticValue: false,
        optimisticScripts: const [],
        loadCold: (id) async {
          expect(id, 1);
          coldLoadStarted.complete();
          await finishColdLoad.future;
          return null;
        },
      );

      await coldLoadStarted.future;
      activeScriptId = 2;
      finishColdLoad.complete();

      expect(await scriptFuture, isNull);
      expect(activeScriptId, 2);
    });
  });

  group('PrivateRouteSetupQueue', () {
    test('runs same-zone re-entrant work without waiting on itself', () async {
      final queue = PrivateRouteSetupQueue();
      final events = <String>[];

      await queue
          .enqueue(() async {
            events.add('outer-start');
            await queue.enqueue(() async {
              events.add('inner');
            });
            events.add('outer-end');
          })
          .timeout(const Duration(seconds: 1));

      expect(events, ['outer-start', 'inner', 'outer-end']);
    });

    test('runs jobs in FIFO order and the second reads latest state', () async {
      final queue = PrivateRouteSetupQueue();
      final firstStarted = Completer<void>();
      final releaseFirst = Completer<void>();
      final events = <String>[];
      var latest = 'A';

      final first = queue.enqueue(() async {
        events.add('first-start');
        firstStarted.complete();
        await releaseFirst.future;
        events.add('first-end');
        return 'first';
      });
      await firstStarted.future;
      final second = queue.enqueue(() async {
        events.add('second-start');
        return latest;
      });
      latest = 'B';
      await Future<void>.delayed(Duration.zero);
      expect(events, ['first-start']);

      releaseFirst.complete();
      expect(await first, 'first');
      expect(await second, 'B');
      expect(events, ['first-start', 'first-end', 'second-start']);
    });

    test('continues after the first job throws', () async {
      final queue = PrivateRouteSetupQueue();
      final first = queue.enqueue<String>(() async {
        throw StateError('first failed');
      });
      final second = queue.enqueue(() async => 'second ran');

      await expectLater(first, throwsStateError);
      expect(await second, 'second ran');
    });
  });

  group('buildPrivateRouteOverlayPreservingBase', () {
    test('keeps local overlay when script build throws', () async {
      final calls = <bool>[];
      final result = await buildPrivateRouteOverlayPreservingBase(
        rules: const [
          Rule(
            id: 1,
            ruleAction: RuleAction.DOMAIN,
            content: 'example.com',
            ruleTarget: 'REJECT',
          ),
        ],
        ruleProviders: const [],
        routeTargets: const ['DIRECT', 'REJECT'],
        managedRouting: managedRouting,
        script: Script(
          id: 2,
          label: 'test',
          lastUpdateTime: DateTime.fromMillisecondsSinceEpoch(0),
        ),
        builder:
            ({
              required rules,
              required ruleProviders,
              required routeTargets,
              managedRouting,
              script,
            }) async {
              calls.add(script != null);
              expect(rules, hasLength(1));
              expect(ruleProviders, isEmpty);
              expect(routeTargets, contains('REJECT'));
              expect(managedRouting, isNotNull);
              if (script != null) throw StateError('script failed');
              return baseOverlay;
            },
      );

      expect(calls, [false, true]);
      expect(result.overlay, baseOverlay);
      expect(result.baseOverlay, baseOverlay);
      expect(result.fallback, isTrue);
    });
  });

  group('applyPrivateRouteOverlayFallbacks', () {
    test('retries base after full overlay is rejected', () async {
      final applied = <PrivateRouteOverlay>[];
      final result = await applyPrivateRouteOverlayFallbacks(
        overlay: fullOverlay,
        baseOverlay: baseOverlay,
        managedRouting: managedRouting,
        apply: (overlay) async {
          applied.add(overlay);
          return overlay == fullOverlay
              ? 'client route overlay invalid: full'
              : '';
        },
      );

      expect(applied, [fullOverlay, baseOverlay]);
      expect(result.message, isEmpty);
      expect(result.fallback, isTrue);
    });

    test('retries managed-only after base overlay is rejected', () async {
      final applied = <PrivateRouteOverlay>[];
      final result = await applyPrivateRouteOverlayFallbacks(
        overlay: baseOverlay,
        baseOverlay: baseOverlay,
        managedRouting: managedRouting,
        apply: (overlay) async {
          applied.add(overlay);
          return overlay == baseOverlay
              ? 'client route overlay invalid: base'
              : '';
        },
      );

      expect(applied, hasLength(2));
      expect(applied.first, same(baseOverlay));
      expect(applied.last.rules, isEmpty);
      expect(applied.last.ruleProviders, isEmpty);
      expect(applied.last.managedRouting, same(managedRouting));
      expect(result.message, isEmpty);
      expect(result.fallback, isTrue);
    });

    test('retries managed-only after full and base are rejected', () async {
      final applied = <PrivateRouteOverlay>[];
      final result = await applyPrivateRouteOverlayFallbacks(
        overlay: fullOverlay,
        baseOverlay: baseOverlay,
        managedRouting: managedRouting,
        apply: (overlay) async {
          applied.add(overlay);
          return overlay.rules.isNotEmpty
              ? 'client route overlay invalid: rules'
              : '';
        },
      );

      expect(applied, hasLength(3));
      expect(applied[0], same(fullOverlay));
      expect(applied[1], same(baseOverlay));
      expect(applied[2].rules, isEmpty);
      expect(applied[2].ruleProviders, isEmpty);
      expect(applied[2].managedRouting, same(managedRouting));
      expect(result.message, isEmpty);
      expect(result.fallback, isTrue);
    });

    test('does not duplicate an already managed-only request', () async {
      const managedOverlay = PrivateRouteOverlay(
        managedRouting: managedRouting,
      );
      final applied = <PrivateRouteOverlay>[];
      final result = await applyPrivateRouteOverlayFallbacks(
        overlay: managedOverlay,
        baseOverlay: managedOverlay,
        managedRouting: managedRouting,
        apply: (overlay) async {
          applied.add(overlay);
          return 'client route overlay invalid: managed';
        },
      );

      expect(applied, [managedOverlay]);
      expect(result.message, 'client route overlay invalid: managed');
      expect(result.fallback, isTrue);
    });
  });

  test('fallback notification is emitted once and resets after recovery', () {
    var state = resolvePrivateRouteFallbackNotification(
      fallback: false,
      wasNotified: false,
    );
    expect(state, (notify: false, nextNotified: false));

    state = resolvePrivateRouteFallbackNotification(
      fallback: true,
      wasNotified: state.nextNotified,
    );
    expect(state, (notify: true, nextNotified: true));

    state = resolvePrivateRouteFallbackNotification(
      fallback: true,
      wasNotified: state.nextNotified,
    );
    expect(state, (notify: false, nextNotified: true));

    state = resolvePrivateRouteFallbackNotification(
      fallback: false,
      wasNotified: state.nextNotified,
    );
    expect(state, (notify: false, nextNotified: false));

    state = resolvePrivateRouteFallbackNotification(
      fallback: true,
      wasNotified: state.nextNotified,
    );
    expect(state, (notify: true, nextNotified: true));
  });
}
