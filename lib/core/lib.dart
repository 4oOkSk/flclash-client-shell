import 'dart:async';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/plugins/service.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';

import 'desktop/model.dart';
import 'interface.dart';
import 'method.dart';

class CoreLib extends CoreHandlerInterface {
  static CoreLib? _instance;

  Completer<bool> _connectedCompleter = Completer<bool>();
  Future<CoreLifecycleResult>? _closeOperation;
  int _lifecycleRevision = 0;
  int _methodCallId = 0;
  bool _closed = false;
  final _lifecycleScheduler = SerialTaskScheduler();
  Future<CoreLifecycleResult>? _startOperation;
  bool _startIsRestart = false;
  bool _runningRequested = false;

  CoreLib._internal();

  factory CoreLib() {
    _instance ??= CoreLib._internal();
    return _instance!;
  }

  @override
  Future<CoreLifecycleResult> start() => _queueStart();

  Future<CoreLifecycleResult> _queueStart({bool restart = false}) {
    if (_closed) {
      throw StateError('Core lifecycle is closed');
    }
    final active = _startOperation;
    if (active != null && _runningRequested && (!restart || _startIsRestart)) {
      return active;
    }
    _runningRequested = true;
    final revision = ++_lifecycleRevision;
    late final Future<CoreLifecycleResult> operation;
    operation = _lifecycleScheduler
        .run(() async {
          if (restart) {
            final result = await _shutdown(revision);
            if (result.outcome == CoreLifecycleOutcome.superseded) {
              return result;
            }
          }
          return _start(revision);
        })
        .whenComplete(() {
          if (identical(_startOperation, operation)) _startOperation = null;
        });
    _startOperation = operation;
    _startIsRestart = restart;
    return operation;
  }

  Future<CoreLifecycleResult> _start(int revision) async {
    if (_closed || revision != _lifecycleRevision) {
      return CoreLifecycleResult(
        revision: revision,
        outcome: CoreLifecycleOutcome.superseded,
      );
    }
    if (_connectedCompleter.isCompleted) {
      return CoreLifecycleResult(
        revision: revision,
        outcome: CoreLifecycleOutcome.coalesced,
      );
    }
    final initializationError = await service?.init() ?? '';
    if (initializationError.isNotEmpty) {
      await service?.shutdown();
      throw StateError(initializationError);
    }
    if (_closed || revision != _lifecycleRevision) {
      await service?.shutdown();
      return CoreLifecycleResult(
        revision: revision,
        outcome: CoreLifecycleOutcome.superseded,
      );
    }
    _connectedCompleter.complete(true);
    final syncError =
        await service?.syncState(
          globalState.container.read(sharedStateProvider),
        ) ??
        '';
    if (syncError.isNotEmpty) {
      _connectedCompleter = Completer<bool>();
      await service?.shutdown();
      throw StateError(syncError);
    }
    if (_closed || revision != _lifecycleRevision) {
      _connectedCompleter = Completer<bool>();
      await service?.shutdown();
      return CoreLifecycleResult(
        revision: revision,
        outcome: CoreLifecycleOutcome.superseded,
      );
    }
    return CoreLifecycleResult(
      revision: revision,
      outcome: CoreLifecycleOutcome.applied,
    );
  }

  @override
  Future<CoreLifecycleResult> restart() => _queueStart(restart: true);

  @override
  Future<CoreLifecycleResult> stop() => _stop();

  Future<CoreLifecycleResult> _stop({bool allowClosed = false}) {
    if (_closed && !allowClosed) {
      throw StateError('Core lifecycle is closed');
    }
    _runningRequested = false;
    final revision = ++_lifecycleRevision;
    return _lifecycleScheduler.run(() => _shutdown(revision));
  }

  Future<CoreLifecycleResult> _shutdown(int revision) async {
    if (revision != _lifecycleRevision) {
      return CoreLifecycleResult(
        revision: revision,
        outcome: CoreLifecycleOutcome.superseded,
      );
    }
    final connected = _connectedCompleter.isCompleted;
    final stopped = await service?.shutdown() ?? true;
    if (!stopped) throw StateError('Android Core service shutdown failed');
    if (connected && service != null) {
      final shutdown = await invokeMethod<bool>(method: CoreMethod.shutdown);
      if (shutdown != true) throw StateError('Android Core shutdown failed');
    }
    _connectedCompleter = Completer<bool>();
    return CoreLifecycleResult(
      revision: revision,
      outcome: revision != _lifecycleRevision
          ? CoreLifecycleOutcome.superseded
          : connected
          ? CoreLifecycleOutcome.applied
          : CoreLifecycleOutcome.coalesced,
    );
  }

  @override
  Future<CoreLifecycleResult> close() {
    return _closeOperation ??= _close();
  }

  Future<CoreLifecycleResult> _close() async {
    _closed = true;
    return _stop(allowClosed: true);
  }

  @override
  Future<bool> startListener() async {
    final listenerStarted = await super.startListener();
    if (!listenerStarted) return false;
    final serviceStarted = await service?.start() ?? false;
    if (!serviceStarted) await super.stopListener();
    return listenerStarted && serviceStarted;
  }

  @override
  Future<bool> stopListener() async {
    final serviceStopped = await service?.stop() ?? false;
    final listenerStopped = await super.stopListener();
    return serviceStopped && listenerStopped;
  }

  @override
  Future<List<String>> getPlatformDiagnosticLogs() async =>
      await service?.getDiagnosticLogs() ?? const [];

  @override
  Future<T?> invokeMethod<T>({
    required CoreMethod method,
    Object? arguments,
    Duration? timeout,
  }) async {
    try {
      await _connectedCompleter.future.timeout(const Duration(seconds: 10));
    } catch (error) {
      commonPrint.log(
        'Invoke method ${method.name} before connection timed out: $error',
        logLevel: coreFailureLogLevel(error),
      );
      return null;
    }
    final id = '${++_methodCallId}';
    final response = await service
        ?.invokeMethod(
          CoreMethodCall(id: id, method: method, arguments: arguments),
        )
        .withTimeout(timeout: timeout, onTimeout: () => null);
    if (response == null) {
      return null;
    }
    return response.unwrap<T>();
  }
}

CoreLib? get coreLib => system.isAndroid ? CoreLib() : null;
