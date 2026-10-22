import 'dart:convert';

import 'package:fl_clash/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('old native shared state ignores retired Crashlytics setting', () {
    const state = SharedState(
      setupParams: SetupParams(
        selectedMap: {'Saved group': 'Saved server'},
        testUrl: 'https://saved.example/check',
      ),
      vpnOptions: VpnOptions(
        enable: true,
        port: 7890,
        ipv6: false,
        dnsHijacking: true,
        accessControlProps: AccessControlProps(
          enable: true,
          rejectList: ['saved.application'],
        ),
        allowBypass: false,
        systemProxy: false,
        bypassDomain: ['saved.example'],
        stack: 'gvisor',
      ),
      startTip: 'Start',
      stopTip: 'Stop',
      stopText: 'Disconnect',
      currentProfileName: 'Saved profile',
    );
    final old = jsonDecode(jsonEncode(state.toJson())) as Map<String, Object?>;
    old['crashlytics'] = true;
    old['onlyStatisticsProxy'] = false;
    final restored = SharedState.fromJson(old);
    expect(restored, state);
    expect(restored.toJson(), isNot(contains('crashlytics')));
    expect(restored.toJson(), isNot(contains('onlyStatisticsProxy')));
    expect(restored.needSyncSharedState, state.copyWith(setupParams: null));
  });
}
