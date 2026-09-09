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

typedef PrivateRouteOverlayApplyResult = ({
  String message,
  bool fallback,
  PrivateRouteOverlay? applied,
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

Future<PrivateRouteOverlayApplyResult> applyPrivateRouteOverlaySafely({
  required PrivateRouteOverlay overlay,
  required PrivateRouteOverlay? previous,
  required Future<String> Function(PrivateRouteOverlay overlay) apply,
  bool buildFailed = false,
}) async {
  final message = buildFailed
      ? 'client route overlay invalid: script'
      : await apply(overlay);
  if (message.isEmpty) {
    return (message: '', fallback: false, applied: overlay);
  }
  if (!message.startsWith('client route overlay invalid') || previous == null) {
    return (message: message, fallback: false, applied: null);
  }
  final restored = await apply(previous);
  return (
    message: restored,
    fallback: true,
    applied: restored.isEmpty ? previous : null,
  );
}
