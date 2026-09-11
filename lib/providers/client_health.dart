import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:fl_clash/core/core.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

enum ClientHealthPhase {
  stopped,
  checking,
  reachable,
  unavailable,
  offline,
  paused,
}

class ClientHealthState {
  final ClientHealthPhase phase;
  final DateTime? checkedAt;
  final int? latencyMs;

  const ClientHealthState(this.phase, {this.checkedAt, this.latencyMs});
}

final clientHealthProbeProvider = Provider<Future<int> Function()>((ref) {
  return () async =>
      (await coreController.getDelay(
        'https://www.gstatic.com/generate_204',
        'HARBORPROXY-SERVER',
      )).value ??
      -1;
});

final clientHealthProvider = NotifierProvider<ClientHealth, ClientHealthState>(
  ClientHealth.new,
);

class ClientHealth extends Notifier<ClientHealthState> {
  Timer? _timer;
  int _revision = 0;
  bool? _underlay;

  @override
  ClientHealthState build() {
    ref.listen(isStartProvider, (_, _) => refresh());
    ref.listen(suspendProvider, (_, _) => refresh());
    ref.listen(checkIpNumProvider, (_, _) => refresh());
    ref.onDispose(() {
      _revision++;
      _timer?.cancel();
    });
    _timer = Timer(Duration.zero, refresh);
    return const ClientHealthState(ClientHealthPhase.stopped);
  }

  void networkChanged(List<ConnectivityResult> results) {
    _underlay =
        results.isEmpty ||
            results.every((item) => item == ConnectivityResult.none)
        ? false
        : results.any(
            (item) =>
                item != ConnectivityResult.vpn &&
                item != ConnectivityResult.none,
          )
        ? true
        : null;
    refresh();
  }

  void refresh() {
    final revision = ++_revision;
    _timer?.cancel();
    if (!ref.read(isStartProvider)) {
      state = const ClientHealthState(ClientHealthPhase.stopped);
    } else if (_underlay == false) {
      state = const ClientHealthState(ClientHealthPhase.offline);
    } else if (ref.read(suspendProvider)) {
      state = const ClientHealthState(ClientHealthPhase.paused);
    } else {
      state = const ClientHealthState(ClientHealthPhase.checking);
      _timer = Timer(const Duration(seconds: 1), () => _probe(revision));
    }
  }

  Future<void> _probe(int revision) async {
    int delay;
    try {
      delay = await ref
          .read(clientHealthProbeProvider)()
          .timeout(const Duration(seconds: 8));
    } catch (_) {
      delay = -1;
    }
    if (!ref.mounted || revision != _revision) return;
    state = ClientHealthState(
      delay >= 0 ? ClientHealthPhase.reachable : ClientHealthPhase.unavailable,
      checkedAt: DateTime.now(),
      latencyMs: delay >= 0 ? delay : null,
    );
    _timer = Timer(const Duration(seconds: 60), refresh);
  }
}
