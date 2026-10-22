part of '../action.dart';

@Riverpod(keepAlive: true)
class BackupAction extends _$BackupAction {
  final _restoreScheduler = SerialTaskScheduler();
  @override
  void build() {}

  Future<String> backup() => _backup();

  Future<String> _backup() async {
    final res = await Future.wait([
      database.profilesDao.fileNames().get(),
      database.scriptsDao.fileNames().get(),
    ]);
    final profileFileNames = res[0];
    final scriptFileNames = res[1];
    final configMap = ref.read(configProvider).toJson();
    configMap['version'] = await preferences.getVersion();
    return backupTask(configMap, [...profileFileNames, ...scriptFileNames]);
  }

  Future<void> restore(RestoreOption option) =>
      _restoreScheduler.run(() => _restore(option));

  @protected
  Future<MigrationData> loadRestoreData() => restoreTask();

  Future<void> _restore(RestoreOption option) async {
    final restoreStrategy = ref.read(
      appSettingProvider.select((state) => state.restoreStrategy),
    );
    final isOverride = restoreStrategy == RestoreStrategy.override;
    final migrationData = await loadRestoreData();
    Config? config;
    RestoreFileTransaction? files;
    try {
      final oldConfig = ref.read(configProvider);
      final configMap = migrationData.configMap;
      final restoreSettings =
          option != RestoreOption.onlyProfiles && configMap != null;
      config = restoreSettings ? Config.fromJson(configMap) : null;
      if (config != null) {
        config = config.copyWith(
          patchClashConfig: config.patchClashConfig.copyWith(
            geoXUrl: defaultGeoXUrl,
          ),
        );
      }
      var preferencesTouched = false;
      try {
        final profileId = config?.currentProfileId;
        if (profileId != null &&
            !migrationData.profiles.any((p) => p.id == profileId) &&
            (isOverride ||
                !(await database.profilesDao.query().get()).any(
                  (p) => p.id == profileId,
                ))) {
          throw const FormatException('Backed-up active profile is missing');
        }
        final root = migrationData.stagedRoot;
        if (root == null) {
          throw const FormatException('Missing restore staging directory');
        }
        final targets = <String, String>{};
        for (final profile in migrationData.profiles) {
          final source = '$root/profiles/${profile.id}.yaml';
          final error = await coreController.validateConfig(source);
          if (error.isNotEmpty) throw FormatException(error);
          targets[source] = await appPath.getProfilePath('${profile.id}');
        }
        for (final script in migrationData.scripts) {
          targets['$root/scripts/${script.id}.js'] = await script.path;
        }
        files = RestoreFileTransaction(
          home: Directory(await appPath.homeDirPath),
          files: targets,
        );
        await database.transaction(() async {
          await database.restore(
            migrationData.profiles,
            migrationData.scripts,
            migrationData.rules,
            migrationData.links,
            migrationData.proxyGroups,
            isOverride: isOverride,
          );
          await files!.replace();
          preferencesTouched = config != null;
          if (config != null && !await preferences.saveConfig(config)) {
            throw StateError('Unable to persist restored settings');
          }
        });
      } catch (error, stack) {
        final failures = <Object>[];
        Future<void> recover(Future<void> Function() operation) async {
          try {
            await operation();
          } catch (failure) {
            failures.add(failure);
          }
        }

        await recover(() async => files?.rollback());
        if (preferencesTouched) {
          await recover(() async {
            if (!await preferences.saveConfig(oldConfig)) {
              throw StateError('Unable to restore previous settings');
            }
          });
        }
        if (failures.isNotEmpty) {
          throw StateError(
            'Restore failed; recovery is incomplete. Previous file backups have been retained.',
          );
        }
        Error.throwWithStackTrace(error, stack);
      }
      await files.cleanup();
    } finally {
      final root = migrationData.restoreRoot;
      if (root != null) await Directory(root).safeDelete(recursive: true);
    }
    final restoredConfig = config;
    if (restoredConfig != null) {
      ref
          .read(davSettingProvider.notifier)
          .update((_) => restoredConfig.davProps);
      ref.read(patchClashConfigProvider.notifier).value =
          restoredConfig.patchClashConfig;
      ref.read(appSettingProvider.notifier).value =
          restoredConfig.appSettingProps;
      ref.read(currentProfileIdProvider.notifier).value =
          restoredConfig.currentProfileId;
      ref.read(themeSettingProvider.notifier).value = restoredConfig.themeProps;
      ref.read(windowSettingProvider.notifier).value =
          restoredConfig.windowProps;
      ref.read(vpnSettingProvider.notifier).value = restoredConfig.vpnProps;
      ref.read(proxiesStyleSettingProvider.notifier).value =
          restoredConfig.proxiesStyleProps;
      ref.read(overrideDnsProvider.notifier).value = restoredConfig.overrideDns;
      ref.read(networkSettingProvider.notifier).value =
          restoredConfig.networkProps;
      ref.read(hotKeyActionsProvider.notifier).value =
          restoredConfig.hotKeyActions;
      ref.read(excludeSSIDsProvider.notifier).value =
          restoredConfig.excludeSSIDs;
    }
  }
}
