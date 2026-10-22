part of '../action.dart';

@Riverpod(keepAlive: true)
class SystemAction extends _$SystemAction {
  SystemExitCoordinator? _exitCoordinator;
  final _autoLaunchScheduler = SerialTaskScheduler();

  @override
  void build() {}

  Future<List<Package>> getPackages() async {
    if (ref.read(isMobileViewProvider)) {
      await Future.delayed(commonDuration);
    }
    if (ref.read(packagesProvider).isEmpty) {
      ref.read(packagesProvider.notifier).value =
          await app?.getPackages() ?? [];
    }
    return ref.read(packagesProvider);
  }

  Future<void> handleExit([bool needSave = false]) {
    final coordinator = _exitCoordinator ??= SystemExitCoordinator(
      watchdogDuration: exitWatchdogDuration,
      closeWindow: closeWindow,
      closeCore: closeCore,
      exitApplication: exitApplication,
    );
    return coordinator.exit(cleanup: () => cleanupExitResources(needSave));
  }

  @protected
  Duration get exitWatchdogDuration => const Duration(seconds: 3);

  @protected
  Future<void> cleanupExitResources(bool needSave) async {
    await Future.wait([
      if (needSave) preferences.saveConfig(ref.read(configProvider)),
      if (macOS != null) macOS!.updateDns(true),
      if (proxy != null) proxy!.stopProxy(),
      if (tray != null) tray!.destroy(),
    ]);
  }

  @protected
  Future<void> closeWindow() async {
    await window?.close();
  }

  @protected
  Future<void> closeCore() async {
    await coreController.close();
    commonPrint.log('exit');
  }

  @protected
  Future<void> exitApplication() {
    return system.exit();
  }

  Future<void> handleClose([bool exit = true]) async {
    if (ref.read(appSettingProvider).minimizeOnExit || !exit) {
      if (system.isDesktop) {
        await preferences.saveConfig(ref.read(configProvider));
      }
      await system.back();
    } else {
      await handleExit();
    }
  }

  Future<void> updateVisible() async {
    final visible = await window?.isVisible;
    if (visible != null && !visible) {
      window?.show();
    } else {
      window?.hide();
    }
  }

  void updateTun() {
    ref
        .read(patchClashConfigProvider.notifier)
        .update((state) => state.copyWith.tun(enable: !state.tun.enable));
  }

  void updateSystemProxy() {
    ref
        .read(networkSettingProvider.notifier)
        .update((state) => state.copyWith(systemProxy: !state.systemProxy));
  }

  @protected
  Future<void> registerAutoLaunch(bool enabled) async {
    await autoLaunch?.updateStatus(enabled);
  }

  @protected
  Future<bool> readAutoLaunch() async => await autoLaunch?.isEnable ?? false;

  Future<void> updateAutoLaunch([bool? enabled]) {
    return _autoLaunchScheduler.run(() async {
      final requested = enabled ?? !ref.read(appSettingProvider).autoLaunch;
      try {
        await registerAutoLaunch(requested);
        ref
            .read(appSettingProvider.notifier)
            .update((state) => state.copyWith(autoLaunch: requested));
      } catch (error) {
        final actual = await readAutoLaunch().catchError((_) => false);
        ref
            .read(appSettingProvider.notifier)
            .update((state) => state.copyWith(autoLaunch: actual));
        commonPrint.log(
          'Auto launch registration failed: $error',
          logLevel: LogLevel.warning,
        );
        globalState.showNotifier(currentAppLocalizations.autoLaunchFailed);
      }
    });
  }

  Future<void> updateTray() async {
    tray?.update(
      trayState: ref.read(trayStateProvider),
      traffic: ref.read(
        trafficsProvider.select(
          (state) => state.list.safeLast(const Traffic()),
        ),
      ),
    );
  }

  Future<void> updateLocalIp() async {
    ref.read(localIpProvider.notifier).value = null;
    await Future.delayed(commonDuration);
    ref.read(localIpProvider.notifier).value = await utils.getLocalIpAddress();
  }
}
