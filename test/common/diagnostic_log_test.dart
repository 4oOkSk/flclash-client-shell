import 'package:fl_clash/common/diagnostic_log.dart';
import 'package:fl_clash/models/common.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('node markers and unclassified endpoints never retain server ports', () {
    expect(
      sanitizeVisitedDestination('[server-endpoint]:8443'),
      '[server-endpoint]',
    );
    expect(
      sanitizeVisitedDestination('[server-endpoint]'),
      '[server-endpoint]',
    );
    expect(
      sanitizeClientLog(
        '[TCP] 198.18.0.1:1234 --> [server-endpoint] using Private-Node',
      ),
      '[TCP] [server-endpoint]',
    );
    for (final endpoint in [
      'node.example.com:8443',
      '192.0.2.10:8443',
      '[2001:db8::10]:8443',
    ]) {
      final value = sanitizeClientLog('[APP] dial $endpoint timeout');
      expect(value, contains('timeout'));
      expect(value, isNot(contains('8443')));
      expect(value, isNot(contains(endpoint)));
    }
  });

  test('diagnostic log sanitizer removes sensitive client data', () {
    const secret =
        'server=192.0.2.10 host=api.private.example.com '
        'uuid=11111111-1111-4111-8111-111111111111 '
        'email=user@example.com token=abcdefghijklmnopqrstuvwxyz123456 '
        'endpoint=https://api.private.example.com/secret-route '
        r'path=C:\Users\Alice\secret.yaml using Tokyo-Private-01';
    final sanitized = sanitizeDiagnosticLog(secret);
    expect(sanitized, contains('server=[redacted]'));
    expect(sanitized, contains('endpoint=[redacted]'));
    for (final value in [
      '192.0.2.10',
      'api.private.example.com',
      '11111111-1111-4111-8111-111111111111',
      'user@example.com',
      'abcdefghijklmnopqrstuvwxyz123456',
      'Tokyo-Private-01',
    ]) {
      expect(sanitized, isNot(contains(value)));
    }
  });

  test('traffic flow logs expose only the visited destination', () {
    expect(
      sanitizeClientLog(
        '[TCP] 198.18.0.1:1234 --> example.com:443 using Private-Node',
      ),
      '[TCP] example.com:443',
    );
    expect(
      sanitizeDiagnosticLog('[TCP] private flow'),
      '[traffic event redacted]',
    );
  });

  test('unclassified app URL logs do not expose endpoints or route data', () {
    expect(
      sanitizeClientLog(
        '[APP] find https://example.com/private/path?token=secret proxy=Private-Node',
      ),
      '[APP] find [url] proxy=[redacted]',
    );
    expect(
      sanitizeClientLog('connected using Private-Node'),
      isNot(contains('Private-Node')),
    );
  });

  test('destination validation rejects address-like server labels', () {
    for (final value in [
      'deadbeef',
      'dead:beef',
      '::::',
      'abc',
      '999.999.999.999:443',
      'example.com:65536',
    ]) {
      expect(sanitizeVisitedDestination(value), isNull);
    }
    expect(sanitizeVisitedDestination('example.com:443'), 'example.com:443');
    expect(
      sanitizeVisitedDestination('[2001:db8::1]:443'),
      '[2001:db8::1]:443',
    );
    expect(
      sanitizeVisitedDestination('https://example.com/path?token=secret'),
      'https://example.com',
    );
  });

  test('tracker destinations use metadata and never proxy chains', () {
    final tracker = TrackerInfo(
      id: 'one',
      start: DateTime.fromMillisecondsSinceEpoch(0),
      metadata: const Metadata(
        network: 'tcp',
        host: 'play.googleapis.com',
        destinationPort: '443',
      ),
      chains: const ['Private-Node'],
      rule: 'MATCH',
      rulePayload: '',
    );
    expect(trackerVisitedDestination(tracker), 'play.googleapis.com:443');
    expect(
      trackerVisitedDestination(
        tracker.copyWith(metadata: tracker.metadata.copyWith(type: 'Inner')),
      ),
      isNull,
    );
    expect(
      trackerVisitedDestination(
        tracker.copyWith(diagnosticDestination: 'server-endpoint'),
      ),
      '[server-endpoint]',
    );
  });
}
