import 'dart:io';

import 'package:fl_clash/common/proxy.dart';
import 'package:fl_clash/common/print.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/config.dart';
import 'package:fl_clash/providers/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class ProxyManager extends ConsumerStatefulWidget {
  final Widget child;

  const ProxyManager({super.key, required this.child});

  @override
  ConsumerState createState() => _ProxyManagerState();
}

class _ProxyManagerState extends ConsumerState<ProxyManager> {
  Future<void> _pendingUpdate = Future.value();

  void _disableSystemProxyPreference() {
    if (!mounted) return;
    final setting = ref.read(networkSettingProvider);
    if (!setting.systemProxy) return;
    ref
        .read(networkSettingProvider.notifier)
        .update((state) => state.copyWith(systemProxy: false));
  }

  Future<bool> _waitForLocalProxy(int port) async {
    if (port <= 0 || port > 65535) return false;
    for (var attempt = 0; attempt < 20; attempt++) {
      try {
        final socket = await Socket.connect(
          InternetAddress.loopbackIPv4,
          port,
          timeout: const Duration(milliseconds: 250),
        );
        socket.destroy();
        return true;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
    return false;
  }

  Future<void> _updateProxy(ProxyState proxyState) async {
    final proxyPlugin = proxy;
    if (proxyPlugin == null) return;
    final isStart = proxyState.isStart;
    final systemProxy = proxyState.systemProxy;
    final port = proxyState.port;
    bool? result;
    if (isStart && systemProxy) {
      if (!await _waitForLocalProxy(port)) {
        await proxyPlugin.stopProxy();
        _disableSystemProxyPreference();
        commonPrint.log(
          'system proxy not enabled: local listener unavailable',
          logLevel: LogLevel.warning,
        );
        return;
      }
      result = await proxyPlugin.startProxy(port, proxyState.bassDomain);
    } else {
      result = await proxyPlugin.stopProxy();
    }
    if (result == false) {
      if (isStart && systemProxy) {
        await proxyPlugin.stopProxy();
        _disableSystemProxyPreference();
      }
      commonPrint.log('update system proxy failed', logLevel: LogLevel.warning);
    }
  }

  void _scheduleUpdateProxy(ProxyState proxyState) {
    _pendingUpdate = _pendingUpdate
        .then((_) => _updateProxy(proxyState))
        .catchError((Object error) {
          commonPrint.log(
            'update system proxy failed: $error',
            logLevel: LogLevel.warning,
          );
        });
  }

  @override
  void initState() {
    super.initState();
    ref.listenManual(proxyStateProvider, (prev, next) {
      if (prev != next) {
        _scheduleUpdateProxy(next);
      }
    }, fireImmediately: true);
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}
