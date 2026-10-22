import 'package:fl_clash/common/client_diagnostics.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('client runtime diagnostics expose only known aggregate fields', () {
    final status = parseClientRuntimeDiagnostics('''
{
  "core_version": "1.10.0",
  "geoip": {"present": true, "age_seconds": 11, "size_bytes": 12},
  "geosite": {"present": true, "age_seconds": 13, "size_bytes": 14},
  "last_geo_update_at": 125,
  "last_geo_update_type": "GEOIP",
  "last_geo_update_result": "success",
  "unexpected_server": "private.example.com"
}
''');

    expect(status['core.version'], '1.10.0');
    expect(status['geo.geositeSizeBytes'], 14);
    expect(status.values, isNot(contains('private.example.com')));
  });

  test('DNS service failures are not inferred from retained logs', () {
    final status = parseClientRuntimeDiagnostics(
      '{"dns":{"completed":12,"failed":4,"timeouts":3,"last_failure_at":123},"protect_failures":2}',
    );
    expect(status['dns.failed'], 4);
    expect(status['dns.timeouts'], 3);
    expect(status['vpn.protectFailures'], 2);
    expect(parseClientRuntimeDiagnostics('{}')['dns.failed'], 'unavailable');
  });
}
