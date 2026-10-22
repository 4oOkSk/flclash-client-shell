part of '../action.dart';

@Riverpod(keepAlive: true)
class CoreAction extends _$CoreAction {
  int _requestedRestartRevision = 0;
  Future<void>? _restartOperation;

  @override
  void build() {}

  Future<void> initCore() async {
    final isInit = await coreController.isInit;

    final version = ref.read(versionProvider);
    if (!isInit) {
      final res = await coreController.init(version);
      commonPrint.log('init result: $res');
      if (!res) throw StateError('Core initialization failed');
    } else {
      await ref.read(proxiesActionProvider.notifier).updateGroups();
    }
  }

  Future<void> prepareClientCore() async {
    try {
      await startLifecycle();
    } catch (_) {
      throw const CoreMethodException(
        code: 'transport_error',
        message: 'Core could not start',
      );
    }
    await initCore();
  }

  Future<void> startCore() async {
    ref.read(coreStatusProvider.notifier).value = CoreStatus.connecting;
    try {
      await startLifecycle();
      await initCore();
      ref.read(coreStatusProvider.notifier).value = CoreStatus.connected;
    } catch (error) {
      ref.read(coreStatusProvider.notifier).value = CoreStatus.disconnected;
      globalState.showNotifier(error.toString());
    }
  }

  @protected
  Future<CoreLifecycleResult> startLifecycle() {
    return coreController.start();
  }

  @protected
  Future<CoreLifecycleResult> restartLifecycle() {
    return coreController.restart();
  }

  Future<void> restartCore() {
    _requestedRestartRevision++;
    final activeOperation = _restartOperation;
    if (activeOperation != null) {
      return activeOperation;
    }

    final operation = _runRestartWorker();
    _restartOperation = operation;
    return operation;
  }

  Future<void> _runRestartWorker() async {
    try {
      ref.read(coreStatusProvider.notifier).value = CoreStatus.connecting;
      await restartLifecycle();
      await initCore();
      ref.read(coreStatusProvider.notifier).value = CoreStatus.connected;

      var appliedRevision = 0;
      while (appliedRevision < _requestedRestartRevision) {
        final revision = _requestedRestartRevision;
        if (ref.read(isStartProvider)) {
          await ref
              .read(setupActionProvider.notifier)
              .setRunning(true, initialize: true);
        } else {
          await ref
              .read(setupActionProvider.notifier)
              .applyProfile(force: true);
        }
        appliedRevision = revision;
      }
    } catch (_) {
      ref.read(coreStatusProvider.notifier).value = CoreStatus.disconnected;
      rethrow;
    } finally {
      _restartOperation = null;
    }
  }
}
