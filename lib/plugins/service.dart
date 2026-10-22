import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/event.dart';
import 'package:fl_clash/core/method.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

abstract mixin class ServiceListener {
  void onServiceEvent(CoreEvent event) {}
}

class Service {
  static Service? _instance;
  late MethodChannel methodChannel;
  ReceivePort? receiver;
  int _startRequestId = 0;
  final _pendingStarts = <int, Completer<bool>>{};

  final ObserverList<ServiceListener> _listeners =
      ObserverList<ServiceListener>();

  factory Service() {
    _instance ??= Service._internal();
    return _instance!;
  }

  Service._internal() {
    methodChannel = const MethodChannel('$packageName/service');
    methodChannel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'startCompleted':
          final result = Map<Object?, Object?>.from(call.arguments as Map);
          final id = result['requestId'];
          final completion = _pendingStarts[id];
          if (completion != null && !completion.isCompleted) {
            completion.complete(result['started'] == true);
          }
          break;
        case 'event':
          final data = call.arguments as String? ?? '';
          final methodCall = CoreMethodCall.fromJson(
            Map<String, Object?>.from(json.decode(data) as Map),
          );
          for (final event in coreEventsFromData(methodCall.arguments)) {
            for (final listener in _listeners) {
              try {
                listener.onServiceEvent(event);
              } catch (error) {
                commonPrint.log(
                  'Unable to dispatch Android Core event '
                  '${event.type.name}: $error',
                  logLevel: LogLevel.error,
                );
              }
            }
          }
          break;
        default:
          throw MissingPluginException();
      }
    });
  }

  Future<CoreMethodResponse?> invokeMethod(CoreMethodCall call) async {
    final data = await methodChannel.invokeMethod<String>(
      'invokeMethod',
      json.encode(call),
    );
    if (data == null) {
      return null;
    }
    final dataJson = await data.commonToJSON<dynamic>();
    return CoreMethodResponse.fromJson(dataJson);
  }

  Future<bool> start({Duration timeout = const Duration(seconds: 60)}) async {
    final id = ++_startRequestId;
    final completion = Completer<bool>();
    _pendingStarts[id] = completion;
    final elapsed = Stopwatch()..start();
    try {
      final accepted = await methodChannel
          .invokeMethod<bool>('start', {'requestId': id})
          .timeout(timeout);
      if (accepted != true) return false;
      final remaining = timeout - elapsed.elapsed;
      if (remaining <= Duration.zero)
        throw TimeoutException('VPN start timed out');
      return await completion.future.timeout(remaining);
    } on TimeoutException {
      await methodChannel
          .invokeMethod<bool>('cancelStart', {'requestId': id})
          .timeout(const Duration(seconds: 5), onTimeout: () => false)
          .catchError((Object _) => false);
      return false;
    } finally {
      _pendingStarts.remove(id);
    }
  }

  void _cancelPendingStarts() {
    for (final completion in _pendingStarts.values) {
      if (!completion.isCompleted) completion.complete(false);
    }
    _pendingStarts.clear();
  }

  Future<bool> stop() async {
    _cancelPendingStarts();
    return await methodChannel.invokeMethod<bool>('stop') ?? false;
  }

  Future<String> init() async {
    return await methodChannel.invokeMethod<String>('init') ?? '';
  }

  Future<String> syncState(SharedState state) async {
    return await methodChannel.invokeMethod<String>(
          'syncState',
          json.encode(state),
        ) ??
        '';
  }

  Future<bool> shutdown() async {
    _cancelPendingStarts();
    return await methodChannel.invokeMethod<bool>('shutdown') ?? true;
  }

  Future<DateTime?> getRunTime() async {
    final ms = await methodChannel.invokeMethod<int>('getRunTime') ?? 0;
    if (ms == 0) {
      return null;
    }
    return DateTime.fromMillisecondsSinceEpoch(ms);
  }

  Future<List<String>> getDiagnosticLogs() async {
    final data =
        await methodChannel.invokeMethod<String>('getDiagnosticLogs') ?? '';
    return data
        .split('\n')
        .where((line) => line.trim().isNotEmpty)
        .toList(growable: false);
  }

  bool get hasListeners {
    return _listeners.isNotEmpty;
  }

  void addListener(ServiceListener listener) {
    _listeners.add(listener);
  }

  void removeListener(ServiceListener listener) {
    _listeners.remove(listener);
  }
}

Service? get service => system.isAndroid ? Service() : null;
