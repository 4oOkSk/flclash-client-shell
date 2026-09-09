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

  group('applyPrivateRouteOverlaySafely', () {
    test(
      'restores the previous complete policy, never an empty default',
      () async {
        final applied = <PrivateRouteOverlay>[];
        final result = await applyPrivateRouteOverlaySafely(
          overlay: fullOverlay,
          previous: baseOverlay,
          apply: (overlay) async {
            applied.add(overlay);
            return overlay == fullOverlay
                ? 'client route overlay invalid: rules'
                : '';
          },
        );
        expect(applied, [fullOverlay, baseOverlay]);
        expect(result.applied, same(baseOverlay));
        expect(result.fallback, isTrue);
      },
    );

    test(
      'first invalid policy fails closed without stripping blocking rules',
      () async {
        final applied = <PrivateRouteOverlay>[];
        final result = await applyPrivateRouteOverlaySafely(
          overlay: fullOverlay,
          previous: null,
          apply: (overlay) async {
            applied.add(overlay);
            return 'client route overlay invalid: rules';
          },
        );
        expect(applied, [fullOverlay]);
        expect(result.message, isNotEmpty);
        expect(result.applied, isNull);
      },
    );

    test(
      'script failures restore the previous policy without applying partial rules',
      () async {
        final applied = <PrivateRouteOverlay>[];
        final result = await applyPrivateRouteOverlaySafely(
          overlay: baseOverlay,
          previous: fullOverlay,
          buildFailed: true,
          apply: (overlay) async {
            applied.add(overlay);
            return '';
          },
        );
        expect(applied, [fullOverlay]);
        expect(result.applied, same(fullOverlay));
        expect(result.fallback, isTrue);
      },
    );

    test(
      'authentication and transport errors are not hidden by a retry',
      () async {
        var calls = 0;
        final result = await applyPrivateRouteOverlaySafely(
          overlay: fullOverlay,
          previous: baseOverlay,
          apply: (_) async {
            calls++;
            return 'client login required';
          },
        );
        expect(calls, 1);
        expect(result.message, 'client login required');
        expect(result.applied, isNull);
      },
    );

    test('failed restoration is not reported as success', () async {
      final result = await applyPrivateRouteOverlaySafely(
        overlay: fullOverlay,
        previous: baseOverlay,
        apply: (_) async => 'client route overlay invalid: target',
      );
      expect(result.message, isNotEmpty);
      expect(result.applied, isNull);
    });
  });
}
