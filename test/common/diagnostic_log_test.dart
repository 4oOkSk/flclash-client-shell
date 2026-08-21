import 'package:fl_clash/common/diagnostic_log.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/common.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('diagnostic log sanitizer removes private client data', () {
    const secret =
        'server=192.0.2.10 host=api.private.example.com '
        'uuid=11111111-1111-4111-8111-111111111111 '
        'email=user@example.com token=abcdefghijklmnopqrstuvwxyz123456 '
        'endpoint=https://api.private.example.com/secret-route '
        r'path=C:\Users\Alice\secret.yaml using Tokyo-Private-01';

    final sanitized = sanitizeDiagnosticLog(secret);

    expect(sanitized, contains('server=[redacted]'));
    expect(sanitized, contains('endpoint=[redacted]'));
    expect(sanitized, isNot(contains('192.0.2.10')));
    expect(sanitized, isNot(contains('api.private.example.com')));
    expect(sanitized, isNot(contains('11111111-1111-4111-8111-111111111111')));
    expect(sanitized, isNot(contains('user@example.com')));
    expect(sanitized, isNot(contains('abcdefghijklmnopqrstuvwxyz123456')));
    expect(sanitized, isNot(contains('Tokyo-Private-01')));
  });

  test('diagnostic report keeps recent useful errors only', () {
    final logs = List.generate(
      4,
      (index) => Log(
        logLevel: index == 3 ? LogLevel.error : LogLevel.info,
        payload: index == 3
            ? 'dial tcp 203.0.113.8:443 timeout'
            : 'event-$index',
        dateTime: '2026-08-04T00:00:0$index',
      ),
    );

    final report = buildDiagnosticReport(
      applicationName: 'Example Client',
      status: const {'core.status': 'connected'},
      logs: logs,
      platformLogs: const ['VpnService start failed host=private.example.com'],
      logLineLimit: 2,
    );

    expect(report, contains('core.status=connected'));
    expect(report, contains('logs.total=4'));
    expect(report, contains('logs.included=2'));
    expect(report, contains('platformLogs.included=1'));
    expect(report, isNot(contains('event-0')));
    expect(report, contains('event-2'));
    expect(report, contains('timeout'));
    expect(report, isNot(contains('203.0.113.8')));
    expect(report, contains('VpnService start failed'));
    expect(report, isNot(contains('private.example.com')));
  });

  test('traffic flow logs expose only the visited destination', () {
    expect(
      sanitizePrivateClientLog(
        '[TCP] 198.18.0.1:1234 --> example.com:443 using Private-Node',
      ),
      '[TCP] example.com:443',
    );
  });

  test(
    'known app URL logs keep the origin but remove route and query data',
    () {
      expect(
        sanitizePrivateClientLog(
          '[APP] find https://example.com/private/path?token=secret '
          'proxy=Private-Node',
        ),
        '[APP] destination=https://example.com',
      );
      expect(
        sanitizePrivateClientLog('connected using Private-Node'),
        isNot(contains('Private-Node')),
      );
    },
  );

  test(
    'diagnostic destination section never accepts arbitrary server labels',
    () {
      final report = buildDiagnosticReport(
        applicationName: 'Example Client',
        status: const {},
        logs: const [],
        visitedDestinations: const [
          'example.com:443',
          'https://www.google.com/search?q=secret',
          'Private Node Tokyo',
        ],
      );

      expect(report, contains('destinations.included=2'));
      expect(report, contains('example.com:443'));
      expect(report, contains('https://www.google.com'));
      expect(report, isNot(contains('search?q=secret')));
      expect(report, isNot(contains('Private Node Tokyo')));
    },
  );

  test('destination validation rejects address-like server labels', () {
    expect(sanitizeVisitedDestination('deadbeef'), isNull);
    expect(sanitizeVisitedDestination('dead:beef'), isNull);
    expect(sanitizeVisitedDestination('::::'), isNull);
    expect(sanitizeVisitedDestination('abc'), isNull);
    expect(sanitizeVisitedDestination('999.999.999.999:443'), isNull);
    expect(sanitizeVisitedDestination('example.com:65536'), isNull);
    expect(sanitizeVisitedDestination('example.com:443'), 'example.com:443');
    expect(
      sanitizeVisitedDestination('[2001:db8::1]:443'),
      '[2001:db8::1]:443',
    );
  });

  test('tracker destinations use metadata and never proxy chains', () {
    final trackers = [
      TrackerInfo(
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
      ),
    ];

    expect(collectVisitedDestinations(trackers), ['play.googleapis.com:443']);
  });

  test('inner proxy-hop trackers never expose server destinations', () {
    final internal = TrackerInfo(
      id: 'inner',
      start: DateTime.fromMillisecondsSinceEpoch(1),
      metadata: const Metadata(
        type: 'Inner',
        network: 'tcp',
        host: 'private-node.example.com',
        destinationIP: '192.0.2.10',
        destinationPort: '443',
      ),
      chains: const ['private-node'],
      rule: 'MATCH',
      rulePayload: '',
      diagnosticRoute: 'proxy',
      diagnosticRule: 'match',
      diagnosticPolicy: 'fallback',
    );

    expect(trackerVisitedDestination(internal), isNull);
    expect(collectVisitedDestinations([internal]), isEmpty);
    expect(collectDiagnosticRouteSamples([internal]), isEmpty);
  });

  test('route samples expose only fixed diagnostic categories', () {
    final trackers = [
      TrackerInfo(
        id: 'one',
        upload: 123,
        download: 456,
        start: DateTime.fromMillisecondsSinceEpoch(0),
        metadata: const Metadata(
          network: 'tcp',
          host: 'mmhead.c2c.wechat.com',
          destinationPort: '443',
        ),
        chains: const ['Private-Node-Name'],
        rule: 'MATCH',
        rulePayload: 'Private-Rule-Value',
        lifecycle: 'closed',
        durationMs: 6500,
        endReason: 'closed',
        diagnosticRoute: 'proxy',
        diagnosticRule: 'match',
        diagnosticPolicy: 'fallback',
      ),
      TrackerInfo(
        id: 'two',
        start: DateTime.fromMillisecondsSinceEpoch(0),
        metadata: const Metadata(
          network: 'udp',
          destinationIP: '240e:978:d04:3003::27',
          destinationPort: '443',
        ),
        chains: const ['DIRECT'],
        rule: 'GEOIP',
        rulePayload: 'CN',
        lifecycle: 'closed',
        durationMs: 500,
        endReason: 'eof',
        diagnosticRoute: 'direct',
        diagnosticRule: 'ip',
        diagnosticPolicy: 'mainland-ip',
      ),
      TrackerInfo(
        id: 'three',
        start: DateTime.fromMillisecondsSinceEpoch(0),
        metadata: const Metadata(
          network: 'tcp',
          destinationIP: '240e:e1:aa00:101a::48',
          destinationPort: '443',
        ),
        chains: const ['REJECT'],
        rule: 'IP-CIDR6',
        rulePayload: '::/0',
        lifecycle: 'closed',
        durationMs: 60000,
        endReason: 'idle-timeout',
        diagnosticRoute: 'reject',
        diagnosticRule: 'ip',
        diagnosticPolicy: 'ipv6-block',
      ),
    ];

    final report = buildDiagnosticReport(
      applicationName: 'Example Client',
      status: const {},
      logs: const [],
      routeSamples: collectDiagnosticRouteSamples(trackers),
    );

    expect(report, contains('routes.included=3'));
    expect(
      report,
      contains(
        'destination=mmhead.c2c.wechat.com:443 network=tcp '
        'route=proxy rule=match policy=fallback phase=closed '
        'duration=5-30s end=closed upload=123 download=456',
      ),
    );
    expect(
      report,
      contains(
        'destination=[240e:e1:aa00:101a::48]:443 network=tcp '
        'route=reject rule=ip policy=ipv6-block phase=closed '
        'duration=30-120s end=idle-timeout upload=0 download=0',
      ),
    );
    expect(
      report,
      contains(
        'destination=[240e:978:d04:3003::27]:443 network=udp '
        'route=direct rule=ip policy=mainland-ip phase=closed '
        'duration=lt1s end=eof upload=0 download=0',
      ),
    );
    expect(report, isNot(contains('Private-Node-Name')));
    expect(report, isNot(contains('Private-Rule-Value')));
  });

  test('route sample validation rejects arbitrary labels and fields', () {
    expect(
      sanitizeDiagnosticRouteSample(
        'destination=example.com:443 network=tcp route=direct '
        'rule=domain policy=mainland-domain phase=closed '
        'duration=1-5s end=idle-timeout upload=1 download=2',
      ),
      'destination=example.com:443 network=tcp route=direct '
      'rule=domain policy=mainland-domain phase=closed '
      'duration=1-5s end=idle-timeout upload=1 download=2',
    );
    expect(
      sanitizeDiagnosticRouteSample(
        'destination=Private-Node network=tcp route=direct '
        'rule=domain policy=mainland-domain phase=closed '
        'duration=1-5s end=eof upload=1 download=2',
      ),
      isNull,
    );
    expect(
      sanitizeDiagnosticRouteSample(
        'destination=example.com:443 network=tcp route=Tokyo '
        'rule=domain policy=mainland-domain phase=closed '
        'duration=1-5s end=eof upload=1 download=2',
      ),
      isNull,
    );
    expect(
      sanitizeDiagnosticRouteSample(
        'destination=example.com:443 network=tcp route=proxy '
        'rule=domain policy=Private-Node phase=closed '
        'duration=1-5s end=eof upload=1 download=2',
      ),
      isNull,
    );
  });

  test('route samples reserve 15 active and 15 closed slots', () {
    final trackers = [
      for (var index = 0; index < 20; index++)
        _diagnosticTracker(
          id: 'active-$index',
          host: 'active-$index.example.com',
          startMs: index * 1000,
        ),
      for (var index = 0; index < 20; index++)
        _diagnosticTracker(
          id: 'closed-$index',
          host: 'closed-$index.example.com',
          startMs: 100000 + index * 1000,
          closed: true,
          durationMs: 500,
        ),
    ];

    final samples = collectDiagnosticRouteSamples(trackers);
    final active = samples.where((item) => item.contains('phase=active'));
    final closed = samples.where((item) => item.contains('phase=closed'));

    expect(samples, hasLength(30));
    expect(active, hasLength(15));
    expect(closed, hasLength(15));
    expect(active.first, contains('active-19.example.com'));
    expect(active.last, contains('active-5.example.com'));
    expect(closed.first, contains('closed-19.example.com'));
    expect(closed.last, contains('closed-5.example.com'));
  });

  test('route sample quota backfills the phase with available events', () {
    final trackers = [
      for (var index = 0; index < 3; index++)
        _diagnosticTracker(
          id: 'active-$index',
          host: 'active-$index.example.com',
          startMs: index,
        ),
      for (var index = 0; index < 35; index++)
        _diagnosticTracker(
          id: 'closed-$index',
          host: 'closed-$index.example.com',
          startMs: index,
          closed: true,
        ),
    ];

    final samples = collectDiagnosticRouteSamples(trackers);

    expect(samples, hasLength(30));
    expect(
      samples.where((item) => item.contains('phase=active')),
      hasLength(3),
    );
    expect(
      samples.where((item) => item.contains('phase=closed')),
      hasLength(27),
    );
  });

  test('same tracker id keeps the closed lifecycle snapshot', () {
    final trackers = [
      _diagnosticTracker(
        id: 'shared',
        host: 'closed.example.com',
        startMs: 1,
        closed: true,
        durationMs: 1000,
      ),
      _diagnosticTracker(
        id: 'shared',
        host: 'active.example.com',
        startMs: 999999,
      ),
    ];

    final samples = collectDiagnosticRouteSamples(trackers);

    expect(samples, hasLength(1));
    expect(samples.single, contains('closed.example.com'));
    expect(samples.single, contains('phase=closed'));
  });

  test('active sorts by start and closed sorts by end time', () {
    final trackers = [
      _diagnosticTracker(
        id: 'active-old',
        host: 'active-old.example.com',
        startMs: 1,
      ),
      _diagnosticTracker(
        id: 'active-new',
        host: 'active-new.example.com',
        startMs: 2,
      ),
      _diagnosticTracker(
        id: 'closed-late-end',
        host: 'closed-late-end.example.com',
        startMs: 0,
        closed: true,
        durationMs: 100,
      ),
      _diagnosticTracker(
        id: 'closed-early-end',
        host: 'closed-early-end.example.com',
        startMs: 50,
        closed: true,
        durationMs: 1,
      ),
    ];

    final samples = collectDiagnosticRouteSamples(trackers, limit: 4);
    final active = samples
        .where((item) => item.contains('phase=active'))
        .toList();
    final closed = samples
        .where((item) => item.contains('phase=closed'))
        .toList();

    expect(active.first, contains('active-new.example.com'));
    expect(active.last, contains('active-old.example.com'));
    expect(closed.first, contains('closed-late-end.example.com'));
    expect(closed.last, contains('closed-early-end.example.com'));
  });
}

TrackerInfo _diagnosticTracker({
  required String id,
  required String host,
  required int startMs,
  bool closed = false,
  int durationMs = 0,
}) {
  return TrackerInfo(
    id: id,
    start: DateTime.fromMillisecondsSinceEpoch(startMs),
    metadata: Metadata(network: 'tcp', host: host, destinationPort: '443'),
    chains: const ['DIRECT'],
    rule: 'MATCH',
    rulePayload: '',
    lifecycle: closed ? 'closed' : 'active',
    durationMs: durationMs,
    endReason: closed ? 'closed' : '',
    diagnosticRoute: 'direct',
    diagnosticRule: 'match',
    diagnosticPolicy: 'fallback',
  );
}
