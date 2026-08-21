import 'dart:async';

import 'package:fl_clash/models/models.dart';

import 'javascript.dart';

typedef PrivateRouteOverlayBuilder =
    Future<PrivateRouteOverlay> Function({
      required Iterable<Rule> rules,
      required List<PrivateRuleProviderConfig> ruleProviders,
      required Iterable<String> routeTargets,
      PrivateManagedRouting? managedRouting,
      Script? script,
    });

typedef PrivateRouteOverlayBuildResult = ({
  PrivateRouteOverlay overlay,
  PrivateRouteOverlay baseOverlay,
  bool fallback,
});

typedef PrivateRouteOverlayApplyResult = ({String message, bool fallback});

typedef PrivateRouteFallbackNotificationResult = ({
  bool notify,
  bool nextNotified,
});

Future<T> selectPrivateRouteSnapshot<T>({
  required bool hasOptimisticValue,
  required T optimisticValue,
  required Future<T> Function() loadCold,
}) {
  if (hasOptimisticValue) {
    return Future.value(optimisticValue);
  }
  return loadCold();
}

Future<Script?> selectPrivateRouteScriptSnapshot({
  required int? scriptId,
  required bool hasOptimisticValue,
  required List<Script> optimisticScripts,
  required Future<Script?> Function(int id) loadCold,
}) {
  if (scriptId == null) {
    return Future.value();
  }
  return selectPrivateRouteSnapshot(
    hasOptimisticValue: hasOptimisticValue,
    optimisticValue: optimisticScripts.get(scriptId),
    loadCold: () => loadCold(scriptId),
  );
}

class PrivateRouteSetupQueue {
  Future<void> _tail = Future.value();
  final Object _zoneKey = Object();

  Future<T> enqueue<T>(Future<T> Function() job) {
    // A privileged desktop TUN authorization restarts the core while the
    // current private-route setup is still running.  That restart can request
    // another setup before the outer one completes.  Waiting behind our own
    // queued job would deadlock, so execute only same-zone re-entrant work
    // inline.  Independent callers remain FIFO-serialized below.
    if (identical(Zone.current[_zoneKey], this)) {
      return job();
    }
    final completer = Completer<T>();
    final ready = _tail.then<void>((_) {}, onError: (_, _) {});
    _tail = ready.then<void>((_) async {
      try {
        completer.complete(
          await runZoned(job, zoneValues: <Object?, Object?>{_zoneKey: this}),
        );
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }
}

Future<PrivateRouteOverlay> buildPrivateRouteOverlay({
  required Iterable<Rule> rules,
  required List<PrivateRuleProviderConfig> ruleProviders,
  required Iterable<String> routeTargets,
  PrivateManagedRouting? managedRouting,
  Script? script,
}) async {
  final base = PrivateRouteOverlay(
    rules: rules.map((item) => item.rawValue).toList(growable: false),
    ruleProviders: List.unmodifiable(ruleProviders),
    managedRouting: managedRouting,
  );
  final scriptContent = await script?.content;
  if (scriptContent == null || scriptContent.trim().isEmpty) {
    return base;
  }
  final result = await handleEvaluate(
    scriptContent,
    base.toScriptConfig(routeTargets),
  );
  return PrivateRouteOverlay.fromScriptResult(
    result,
    managedRouting: managedRouting,
  );
}

Future<PrivateRouteOverlayBuildResult> buildPrivateRouteOverlayPreservingBase({
  required Iterable<Rule> rules,
  required List<PrivateRuleProviderConfig> ruleProviders,
  required Iterable<String> routeTargets,
  PrivateManagedRouting? managedRouting,
  Script? script,
  PrivateRouteOverlayBuilder builder = buildPrivateRouteOverlay,
}) async {
  final baseOverlay = await builder(
    rules: rules,
    ruleProviders: ruleProviders,
    routeTargets: routeTargets,
    managedRouting: managedRouting,
  );
  if (script == null) {
    return (overlay: baseOverlay, baseOverlay: baseOverlay, fallback: false);
  }
  try {
    final overlay = await builder(
      rules: rules,
      ruleProviders: ruleProviders,
      routeTargets: routeTargets,
      managedRouting: managedRouting,
      script: script,
    );
    return (overlay: overlay, baseOverlay: baseOverlay, fallback: false);
  } catch (_) {
    return (overlay: baseOverlay, baseOverlay: baseOverlay, fallback: true);
  }
}

Future<PrivateRouteOverlayApplyResult> applyPrivateRouteOverlayFallbacks({
  required PrivateRouteOverlay overlay,
  required PrivateRouteOverlay baseOverlay,
  required PrivateManagedRouting managedRouting,
  required Future<String> Function(PrivateRouteOverlay overlay) apply,
  bool fallback = false,
}) async {
  final managedOverlay = PrivateRouteOverlay(managedRouting: managedRouting);
  var message = await apply(overlay);
  if (!message.startsWith('client route overlay invalid')) {
    return (message: message, fallback: fallback);
  }
  fallback = true;
  if (!identical(overlay, baseOverlay)) {
    message = await apply(baseOverlay);
  }
  if (message.startsWith('client route overlay invalid') &&
      (baseOverlay.rules.isNotEmpty || baseOverlay.ruleProviders.isNotEmpty)) {
    message = await apply(managedOverlay);
  }
  return (message: message, fallback: fallback);
}

PrivateRouteFallbackNotificationResult resolvePrivateRouteFallbackNotification({
  required bool fallback,
  required bool wasNotified,
}) {
  return (notify: fallback && !wasNotified, nextNotified: fallback);
}
