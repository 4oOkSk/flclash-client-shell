import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/state.dart';
import 'package:flutter/material.dart';
import 'package:wifi_ssid/wifi_ssid.dart';

class ConnectivityManager extends StatefulWidget {
  final Function(List<ConnectivityResult> results)? onConnectivityChanged;
  final Widget child;

  const ConnectivityManager({
    super.key,
    this.onConnectivityChanged,
    required this.child,
  });

  @override
  State<ConnectivityManager> createState() => _ConnectivityManagerState();
}

class _ConnectivityManagerState extends State<ConnectivityManager> {
  StreamSubscription<List<ConnectivityResult>>? subscription;

  Future<void> _startConnectivityWatch() async {
    try {
      // connectivity_plus 7.2.0 starts its Linux NetworkManager listener from
      // an async StreamController onListen callback. If NetworkManager is not
      // present, that callback throws outside the stream's onError handler.
      // A catchable preflight prevents the plugin from starting that listener
      // in minimal desktops and build/test environments.
      if (Platform.isLinux) {
        await Connectivity().checkConnectivity();
      }
      if (!mounted) return;
      subscription = Connectivity().onConnectivityChanged.listen(
        _handleConnectivityChanged,
        onError: _handleConnectivityError,
      );
    } catch (error) {
      _handleConnectivityError(error);
    }
  }

  void _handleConnectivityChanged(List<ConnectivityResult> results) {
    if (results.contains(ConnectivityResult.wifi)) {
      unawaited(
        WifiSsidManager.instance
            .getSsid()
            .then((ssid) {
              globalState.container.read(currentSSIDProvider.notifier).value =
                  ssid;
              commonPrint.log('Wi-fi SSID: $ssid ', logLevel: LogLevel.info);
            })
            .catchError((Object error) {
              globalState.container.read(currentSSIDProvider.notifier).value =
                  null;
              commonPrint.log(
                'Wi-fi SSID lookup unavailable: ${error.runtimeType}',
                logLevel: LogLevel.warning,
              );
            }),
      );
    } else {
      globalState.container.read(currentSSIDProvider.notifier).value = null;
    }
    widget.onConnectivityChanged?.call(results);
  }

  void _handleConnectivityError(Object error, [StackTrace? stackTrace]) {
    globalState.container.read(currentSSIDProvider.notifier).value = null;
    commonPrint.log(
      'connectivity watcher unavailable: ${error.runtimeType}',
      logLevel: LogLevel.warning,
    );
  }

  @override
  void initState() {
    super.initState();
    unawaited(_startConnectivityWatch());
  }

  @override
  void dispose() {
    final currentSubscription = subscription;
    if (currentSubscription != null) {
      unawaited(currentSubscription.cancel());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}
