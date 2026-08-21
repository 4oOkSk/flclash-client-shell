import 'package:fl_clash/common/client_diagnostics.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('client runtime diagnostics expose only known aggregate fields', () {
    final status = parseClientRuntimeDiagnostics('''
{
  "session_present": true,
  "cache_present": true,
  "cache_age_seconds": 42,
  "last_refresh_at": 123,
  "last_refresh_result": "online-updated",
  "last_refresh_status": "2xx",
  "last_refresh_duration_ms": 81,
  "last_apply_at": 124,
  "last_apply_result": "success",
  "secure_storage": "windows-dpapi",
  "core_version": "1.10.0",
  "geoip": {"present": true, "age_seconds": 11, "size_bytes": 12},
  "geosite": {"present": true, "age_seconds": 13, "size_bytes": 14},
  "last_geo_update_at": 125,
  "last_geo_update_type": "GEOIP",
  "last_geo_update_result": "success",
  "unexpected_server": "private.example.com"
}
''');

    expect(status['client.sessionPresent'], isTrue);
    expect(status['client.lastRefreshStatus'], '2xx');
    expect(status['client.secureStorage'], 'windows-dpapi');
    expect(status['geo.geositeSizeBytes'], 14);
    expect(status.values, isNot(contains('private.example.com')));
  });

  test('Android TUN activity follows the platform VPN evidence', () {
    expect(
      diagnosticTunActive(
        isAndroid: true,
        runtimeTunEnabled: false,
        platformTunEstablished: true,
      ),
      isTrue,
    );
    expect(
      diagnosticTunActive(
        isAndroid: true,
        runtimeTunEnabled: true,
        platformTunEstablished: false,
      ),
      isFalse,
    );
    expect(
      diagnosticTunActive(
        isAndroid: false,
        runtimeTunEnabled: true,
        platformTunEstablished: false,
      ),
      isTrue,
    );
  });

  test('log and connection summaries contain counts only', () {
    final logs = [
      const Log(
        logLevel: LogLevel.error,
        payload: 'dns resolver error for private.example.com',
        dateTime: 'now',
      ),
      const Log(
        logLevel: LogLevel.info,
        payload: '[TCP] private.example.com routed',
        dateTime: 'now',
      ),
    ];
    final tracker = TrackerInfo(
      id: 'secret-id',
      start: DateTime.fromMillisecondsSinceEpoch(0),
      metadata: const Metadata(network: 'tcp', host: 'private.example.com'),
      chains: const ['DIRECT'],
      rule: 'secret-rule',
      rulePayload: 'secret-payload',
    );

    expect(buildDiagnosticLogSummary(logs), {
      'recent.errorCount': 1,
      'recent.warningCount': 0,
      'recent.trafficEventCount': 1,
      'recent.dnsErrorCount': 1,
      'recent.tunErrorCount': 0,
      'recent.apiErrorCount': 0,
    });
    expect(buildConnectionSummary([tracker]), {
      'routes.activeConnections': 1,
      'routes.activeDirect': 1,
      'routes.activeProxy': 0,
      'routes.activeTcp': 1,
      'routes.activeUdp': 0,
    });
  });

  test('probe diagnostics discard URL and proxy names', () {
    const delay = Delay(
      name: 'Private Node',
      url: 'https://private.example.com/probe',
      value: 123,
    );

    final status = diagnosticProbeResult('selectedProxy', delay);
    expect(status['probe.selectedProxy.success'], isTrue);
    expect(status['probe.selectedProxy.latencyMs'], 123);
    expect(status.values, isNot(contains('Private Node')));
    expect(status.values, isNot(contains(delay.url)));
  });
}
