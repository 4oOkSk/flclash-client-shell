part of '../action.dart';

enum _SetupTaskResult { completed, handoffToCoreRestart }

class _RunRequest {
  final bool running;
  final bool initialize;

  const _RunRequest({required this.running, required this.initialize});
}

@Riverpod(keepAlive: true)
class SetupAction extends _$SetupAction {
  Timer? _runtimeTimer;
  final _setupScheduler = SerialTaskScheduler();
  final _listenerScheduler = SerialTaskScheduler();
  final _privateRouteSetupQueue = PrivateRouteSetupQueue();
  bool _privateRouteFallbackNotified = false;
  _RunRequest? _latestRunRequest;
  DateTime? _startTime;

  bool get _isRunning => _startTime != null && _startTime!.isBeforeNow;

  @override
  void build() {}

  SetupParams get _setupParams {
    final selectedMap = ref.read(selectedMapProvider);
    final testUrl = ref.read(
      appSettingProvider.select((state) => state.testUrl),
    );
    return SetupParams(selectedMap: selectedMap, testUrl: testUrl);
  }

  void fullSetup() {
    if (!ref.read(initProvider)) return;
    ref.read(delayDataSourceProvider.notifier).value = {};
    unawaited(_runSetup(force: true));
    ref.read(logsProvider.notifier).value = FixedList(500);
    ref.read(requestsProvider.notifier).value = FixedList(500);
  }

  void _setLocalRunning(bool running) {
    _runtimeTimer?.cancel();
    _runtimeTimer = null;
    if (!running) {
      _startTime = null;
      debouncer.cancel(FunctionTag.applyProfile);
      _updateRunTime();
      return;
    }

    _startTime ??= DateTime.now();
    _refreshRunningState();
    _runtimeTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _refreshRunningState(),
    );
  }

  void _refreshRunningState() {
    _updateRunTime();
    unawaited(ref.read(commonActionProvider.notifier).updateTraffic());
  }

  void _updateRunTime() {
    final startTime = _startTime;
    ref.read(runTimeProvider.notifier).value = startTime == null
        ? null
        : DateTime.now().millisecondsSinceEpoch -
              startTime.millisecondsSinceEpoch;
  }

  Future<void> _updateStartTime() async {
    _startTime = await service?.getRunTime();
  }

  Future<void> initStatus() async {
    if (!globalState.needInitStatus) {
      commonPrint.log('init status cancel');
      return;
    }
    commonPrint.log('init status');
    _enforcePrivateClientSettings();
    if (kPrivateClientMode && !await coreController.clientHasSession()) {
      return;
    }
    if (system.isAndroid) {
      await _updateStartTime();
    }
    final shouldRun = _isRunning || ref.read(appSettingProvider).autoRun;
    if (shouldRun) {
      await setRunning(true, initialize: true);
    } else {
      await applyProfile(force: true);
    }
  }

  Future<void> setRunning(bool running, {bool initialize = false}) {
    if (running && !initialize && !ref.read(initProvider)) {
      return Future.value();
    }

    if (running) {
      _enforcePrivateClientSettings();
    }
    final request = _RunRequest(
      running: running,
      initialize: running && initialize,
    );
    _latestRunRequest = request;
    _setLocalRunning(running);
    if (request.initialize) {
      globalState.needInitStatus = false;
    }
    return running ? _start(request) : _stop(request);
  }

  Future<void> _start(_RunRequest request) async {
    if (request.initialize) {
      try {
        await applyProfile(
          force: true,
          preloadInvoke: () => _setCoreRunning(request),
        );
      } catch (_) {
        if (_isCurrent(request)) {
          await setRunning(false);
        }
      }
      return;
    }

    if (kPrivateClientMode) {
      try {
        await applyProfile(
          force: true,
          preloadInvoke: () => _setCoreRunning(request),
        );
      } catch (_) {
        if (_isCurrent(request)) {
          await setRunning(false);
        }
        rethrow;
      }
      return;
    }

    await _setCoreRunning(request);
    if (_isCurrent(request)) {
      applyProfileDebounce(force: true, silence: true);
    }
  }

  Future<void> _stop(_RunRequest request) async {
    await _setCoreRunning(request);
    if (!_isCurrent(request)) {
      return;
    }
    resetCoreTraffic();
    ref.read(trafficsProvider.notifier).clear();
    ref.read(totalTrafficProvider.notifier).value = const Traffic();
    ref.read(checkIpNumProvider.notifier).add();
  }

  Future<void> _setCoreRunning(_RunRequest request) {
    return _listenerScheduler.run(() async {
      if (!_isCurrent(request)) {
        return;
      }
      if (request.running && ref.read(suspendProvider)) {
        return;
      }
      await setCoreRunning(request.running);
    });
  }

  bool _isCurrent(_RunRequest request) => identical(_latestRunRequest, request);

  Future<void> updateConfigDebounce() async {
    debouncer.call(FunctionTag.updateConfig, updateConfig);
  }

  @protected
  Future<bool> setCoreRunning(bool running) {
    return running
        ? coreController.startListener()
        : coreController.stopListener();
  }

  @protected
  void resetCoreTraffic() {
    coreController.resetTraffic();
  }

  @visibleForTesting
  Future<void> updateConfig() async {
    await globalState.safeRun(() async {
      final updateParams = ref.read(updateParamsProvider);
      final shouldContinueSetup = await requestAdmin(updateParams.tun.enable);
      if (!shouldContinueSetup) {
        await _restartCoreAfterAuthorization();
        return;
      }
      final message = await coreController.updateConfig(
        updateParams.copyWith.tun(
          enable: _getEffectiveTunEnable(updateParams.tun.enable),
        ),
      );
      ref.read(checkIpNumProvider.notifier).add();
      if (message.isNotEmpty) throw message;
    });
  }

  void tryCheckIp() {
    final isTimeout = ref.read(
      networkDetectionProvider.select(
        (state) => state.ipInfo == null && state.isLoading == false,
      ),
    );
    if (!isTimeout) return;
    ref.read(checkIpNumProvider.notifier).add();
  }

  void applyProfileDebounce({bool silence = false, bool force = false}) {
    debouncer.call(FunctionTag.applyProfile, (silence, force) {
      applyProfile(silence: silence, force: force);
    }, args: [silence, force]);
  }

  void changeMode(Mode mode) {
    if (kPrivateClientMode) return;
    ref
        .read(patchClashConfigProvider.notifier)
        .update((state) => state.copyWith(mode: mode));
    if (mode == Mode.global) {
      ref
          .read(proxiesActionProvider.notifier)
          .updateCurrentGroupName(GroupName.GLOBAL.name);
    }
  }

  void autoApplyProfile() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      applyProfile();
    });
  }

  Future<void> applyProfile({
    bool silence = false,
    bool force = false,
    Future<void> Function()? preloadInvoke,
  }) {
    return _runSetup(
      force: force,
      silence: silence,
      preloadInvoke: preloadInvoke,
    );
  }

  Future<void> _runSetup({
    bool silence = false,
    bool force = false,
    Future<void> Function()? preloadInvoke,
  }) async {
    final result = await _setupScheduler.run(() {
      return _setupConfig(
        force: force,
        silence: silence,
        preloadInvoke: preloadInvoke,
        onUpdated: () async {
          await ref.read(proxiesActionProvider.notifier).updateGroups();
          await ref.read(providersProvider.notifier).syncProviders();
        },
      );
    });
    if (result != _SetupTaskResult.handoffToCoreRestart) {
      return;
    }
    // Release the current serial task before restartCore reapplies the profile.
    await _restartCoreAfterAuthorization();
  }

  Future<void> _restartCoreAfterAuthorization() async {
    try {
      await ref.read(coreActionProvider.notifier).restartCore();
    } catch (_) {
      ref.read(authorizedTunEnableProvider.notifier).value =
          TunAuthorizationState.none;
      rethrow;
    }
  }

  Future<VM2<String, String>> getProfile({
    required SetupState setupState,
    required PatchClashConfig patchConfig,
  }) async {
    final profileId = setupState.profileId;
    if (profileId == null) return const VM2('', '');
    final defaultUA = globalState.packageInfo.ua;
    final networkVM2 = ref.read(
      networkSettingProvider.select(
        (state) => VM2(state.appendSystemDns, state.routeMode),
      ),
    );
    final overrideDns = ref.read(overrideDnsProvider);
    final appendSystemDns = networkVM2.a;
    final routeMode = networkVM2.b;
    final configMap = await coreController.getConfig(profileId);
    String? scriptContent;
    final List<Rule> addedRules = [];
    final List<ProxyGroup> proxyGroups = [];
    final List<Rule> rules = [];
    if (setupState.overwriteType == OverwriteType.script) {
      scriptContent = await setupState.script?.content;
    } else if (setupState.overwriteType == OverwriteType.standard) {
      addedRules.addAll(setupState.addedRules);
    } else {
      proxyGroups.addAll(setupState.proxyGroups);
      rules.addAll(setupState.rules);
    }
    final realPatchConfig = patchConfig.copyWith(
      tun: patchConfig.tun.getRealTun(routeMode),
    );
    Map<String, dynamic> rawConfig = configMap;
    if (scriptContent?.isNotEmpty == true) {
      rawConfig = await handleEvaluate(scriptContent!, rawConfig);
    }
    final directory = await appPath.profilesPath;
    final res = makeRealProfileTask(
      MakeRealProfileState(
        rules: rules,
        proxyGroups: proxyGroups,
        profilesPath: directory,
        profileId: profileId,
        rawConfig: rawConfig,
        realPatchConfig: realPatchConfig,
        overrideDns: overrideDns,
        appendSystemDns: appendSystemDns,
        addedRules: addedRules,
        defaultUA: defaultUA,
      ),
    );
    return res;
  }

  Future<String> getProfileWithId(int profileId) async {
    try {
      final setupState = await ref.read(setupStateProvider(profileId).future);
      final patchClashConfig = ref.read(patchClashConfigProvider);
      final res = await getProfile(
        setupState: setupState,
        patchConfig: patchClashConfig,
      );
      return res.a;
    } catch (e) {
      globalState.showNotifier(e.toString());
    }
    return '';
  }

  void _enforcePrivateClientSettings() {
    if (!kPrivateClientMode) return;
    ref.read(networkSettingProvider.notifier).update(
      (state) => state.systemProxy
          ? state.copyWith(systemProxy: false)
          : state,
    );
    ref.read(patchClashConfigProvider.notifier).update(
      (state) {
        if (state.mode == Mode.rule &&
            !state.allowLan &&
            state.tun.enable) {
          return state;
        }
        return state.copyWith(
          mode: Mode.rule,
          allowLan: false,
          tun: state.tun.copyWith(enable: true),
        );
      },
    );
    if (system.isAndroid) {
      ref.read(vpnSettingProvider.notifier).update(
        (state) => state.enable ? state : state.copyWith(enable: true),
      );
    }
  }

  Future<String> setupPrivateClientProfile({
    Future<void> Function()? preloadInvoke,
  }) {
    _enforcePrivateClientSettings();
    return _privateRouteSetupQueue.enqueue(
      () => _setupPrivateClientProfileImpl(preloadInvoke: preloadInvoke),
    );
  }

  Future<String> _setupPrivateClientProfileImpl({
    Future<void> Function()? preloadInvoke,
  }) async {
    final selectedMap = await preferences.getPrivateClientSelectedMap();
    privateClientSelectedMap
      ..clear()
      ..addAll(selectedMap);
    ref.invalidate(selectedMapProvider);
    final testUrl = ref.read(
      appSettingProvider.select((state) => state.testUrl),
    );
    final managedRouting = PrivateManagedRouting(
      mode: ref.read(networkSettingProvider).managedRouteMode,
      rejectIpv6: !effectiveClientCoreIpv6(
        configured: ref.read(patchClashConfigProvider).ipv6,
        privateClientMode: true,
        isAndroid: system.isAndroid,
      ),
    );
    var routeOverlay = PrivateRouteOverlay(managedRouting: managedRouting);
    var baseRouteOverlay = routeOverlay;
    var routeOverlayFallback = false;
    try {
      final rulesState = ref.read(globalRulesProvider);
      final rules = await selectPrivateRouteSnapshot(
        hasOptimisticValue: rulesState.hasValue,
        optimisticValue: rulesState.hasValue
            ? rulesState.requireValue
            : const <Rule>[],
        loadCold: () => database.rulesDao.queryGlobalAddedRules().get(),
      );
      final ruleProviders = await preferences.getPrivateRuleProviders();
      final scriptId = await preferences.getPrivateRouteScriptId();
      final scriptsState = ref.read(scriptsProvider);
      final script = await selectPrivateRouteScriptSnapshot(
        scriptId: scriptId,
        hasOptimisticValue: scriptsState.hasValue,
        optimisticScripts: scriptsState.hasValue
            ? scriptsState.requireValue
            : const <Script>[],
        loadCold: (id) => database.scriptsDao.get(id).getSingleOrNull(),
      );
      final routeTargets = <String>{
        ...ref
            .read(groupsProvider)
            .where((item) => item.hidden != true)
            .map((item) => item.name),
        ...selectedMap.keys,
      };
      final result = await buildPrivateRouteOverlayPreservingBase(
        rules: rules,
        ruleProviders: ruleProviders,
        routeTargets: routeTargets,
        managedRouting: managedRouting,
        script: script,
      );
      routeOverlay = result.overlay;
      baseRouteOverlay = result.baseOverlay;
      routeOverlayFallback = result.fallback;
    } catch (_) {
      routeOverlayFallback = true;
    }
    final applyResult = await applyPrivateRouteOverlayFallbacks(
      overlay: routeOverlay,
      baseOverlay: baseRouteOverlay,
      managedRouting: managedRouting,
      fallback: routeOverlayFallback,
      apply: (overlay) => coreController.setupFromClient(
        endpoint: kClientApiBase,
        refreshInterval: kEnrollAutoUpdateDuration,
        selectedMap: selectedMap,
        testUrl: testUrl,
        routeOverlay: overlay,
      ),
    );
    final message = applyResult.message;
    routeOverlayFallback = applyResult.fallback;
    if (message.isNotEmpty && !message.endsWith('is empty')) {
      return message;
    }
    ref.invalidate(privateClientAccountInfoProvider);
    final updateMessage = await coreController.updateConfig(
      ref.read(updateParamsProvider).copyWith.tun(
        enable: _getEffectiveTunEnable(
          ref.read(patchClashConfigProvider).tun.enable,
        ),
      ),
    );
    if (updateMessage.isNotEmpty) return updateMessage;
    await preloadInvoke?.call();
    ref.read(checkIpNumProvider.notifier).add();
    await ref.read(proxiesActionProvider.notifier).updateGroups();
    await ref.read(providersProvider.notifier).syncProviders();
    final notification = resolvePrivateRouteFallbackNotification(
      fallback: routeOverlayFallback,
      wasNotified: _privateRouteFallbackNotified,
    );
    _privateRouteFallbackNotified = notification.nextNotified;
    if (notification.notify) {
      globalState.showNotifier(currentAppLocalizations.privateRouteFallback);
    }
    return '';
  }

  bool _getEffectiveTunEnable(bool enableTun) {
    final authorizationState = ref.read(authorizedTunEnableProvider);
    return enableTun && authorizationState == TunAuthorizationState.authorized;
  }

  @protected
  Future<AuthorizeCode> authorizeCore() {
    return system.authorizeCore();
  }

  @protected
  bool get isAndroidPlatform => system.isAndroid;

  @visibleForTesting
  Future<bool> requestAdmin(bool enableTun) async {
    if (!enableTun) {
      return true;
    }
    final authorizationState = ref.read(authorizedTunEnableProvider);
    final requiresAuthorization = requiresPrivilegedTunCoreAuthorization(
      isAndroid: isAndroidPlatform,
      requestedTun: enableTun,
      effectiveTun: authorizationState == TunAuthorizationState.authorized,
    );
    if (!requiresAuthorization) {
      if (isAndroidPlatform) {
        ref.read(authorizedTunEnableProvider.notifier).value =
            TunAuthorizationState.authorized;
      }
      return true;
    }
    if (authorizationState != TunAuthorizationState.none) {
      return true;
    }

    final authorizationNotifier = ref.read(
      authorizedTunEnableProvider.notifier,
    );
    authorizationNotifier.value = TunAuthorizationState.unauthorized;

    final code = await authorizeCore();

    switch (code) {
      case AuthorizeCode.success:
        authorizationNotifier.value = TunAuthorizationState.authorized;
        return false;
      case AuthorizeCode.none:
        authorizationNotifier.value = TunAuthorizationState.authorized;
        return true;
      case AuthorizeCode.error:
      case AuthorizeCode.coreHashMismatch:
        if (kPrivateClientMode) {
          throw StateError(
            'TUN authorization failed (${code.diagnosticCode})',
          );
        }
        return true;
    }
  }

  Future<_SetupTaskResult> _setupConfig({
    bool force = false,
    bool silence = false,
    Future<void> Function()? preloadInvoke,
    FutureOr Function()? onUpdated,
  }) async {
    if (kPrivateClientMode) {
      _enforcePrivateClientSettings();
      final shouldContinueSetup = await requestAdmin(true);
      if (!shouldContinueSetup) {
        return _SetupTaskResult.handoffToCoreRestart;
      }
      await globalState.loadingRun(
        () async {
          final message = await setupPrivateClientProfile(
            preloadInvoke: preloadInvoke,
          );
          if (message.isNotEmpty) throw message;
        },
        silence: true,
        tag: !silence ? LoadingTag.proxies : null,
      );
      return _SetupTaskResult.completed;
    }
    if (kEmbeddedEnrollBlob.isNotEmpty) {
      await globalState.loadingRun(
        () async {
          final message = await coreController.setupFromEnroll(
            blob: kEmbeddedEnrollBlob,
            refreshInterval: kEnrollAutoUpdateDuration,
            selectedMap: ref.read(selectedMapProvider),
            testUrl: ref.read(appSettingProvider).testUrl,
          );
          if (message.isNotEmpty && !message.endsWith('is empty')) {
            throw message;
          }
          await preloadInvoke?.call();
          ref.read(checkIpNumProvider.notifier).add();
          await onUpdated?.call();
        },
        silence: true,
        tag: !silence ? LoadingTag.proxies : null,
      );
      return _SetupTaskResult.completed;
    }
    var profile = ref.read(currentProfileProvider);
    final nextProfile = await profile?.checkAndUpdateAndCopy();
    if (nextProfile != null) {
      profile = nextProfile;
      ref.read(profilesProvider.notifier).put(nextProfile);
    }
    commonPrint.log('setup ===> ${profile?.realLabel}');
    final patchConfig = ref.read(patchClashConfigProvider);
    final shouldContinueSetup = await requestAdmin(patchConfig.tun.enable);
    if (!shouldContinueSetup) {
      return _SetupTaskResult.handoffToCoreRestart;
    }
    final effectiveTunEnable = _getEffectiveTunEnable(patchConfig.tun.enable);
    final realPatchConfig = patchConfig.copyWith.tun(
      enable: effectiveTunEnable,
    );
    final setupState = await ref.read(setupStateProvider(profile?.id).future);
    final vm2 = await getProfile(
      setupState: setupState,
      patchConfig: realPatchConfig,
    );
    final yamlString = vm2.a;
    final yamlMd5 = vm2.b;
    if (yamlMd5 == globalState.lastConfigMd5 && force == false) {
      return _SetupTaskResult.completed;
    }
    if (system.isAndroid) {
      globalState.lastVpnState = ref.read(vpnStateProvider);
      final sharedState = ref.read(sharedStateProvider);
      await preferences.saveShareState(sharedState);
    }
    await globalState.loadingRun(
      () async {
        final configFilePath = await appPath.configFilePath;
        await File(configFilePath).safeWriteAsString(yamlString);
        final message = await coreController.setupConfig(
          params: _setupParams,
          preloadInvoke: preloadInvoke,
        );
        if (message.isNotEmpty && !message.endsWith('is empty')) {
          throw message;
        }
        globalState.lastConfigMd5 = yamlMd5;
        ref.read(checkIpNumProvider.notifier).add();
        await onUpdated?.call();
      },
      silence: true,
      tag: !silence ? LoadingTag.proxies : null,
    );
    return _SetupTaskResult.completed;
  }
}
