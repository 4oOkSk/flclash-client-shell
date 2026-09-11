import 'dart:convert';

import 'package:fl_clash/common/diagnostic_log.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/common.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('health scope remains readable without weakening secret redaction', () {
    final report = buildDiagnosticReport(
      applicationName: 'Example Client',
      status: const {
        'health.scope': diagnosticHealthScope,
        'health.phase': 'reachable',
        'client.token': 'abcdefghijklmnopqrstuvwxyz0123456789',
      },
      logs: const [],
    );

    expect(report, contains('health.scope=$diagnosticHealthScope'));
    expect(report, contains('health.phase=reachable'));
    expect(report, isNot(contains('abcdefghijklmnopqrstuvwxyz0123456789')));
  });

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
      sanitizePrivateClientLog(
        '[TCP] 198.18.0.1:1234 --> [server-endpoint] using Private-Node',
      ),
      '[TCP] [server-endpoint]',
    );
    for (final endpoint in [
      'node.example.com:8443',
      '192.0.2.10:8443',
      '[2001:db8::10]:8443',
    ]) {
      final value = sanitizePrivateClientLog('[APP] dial $endpoint timeout');
      expect(value, contains('timeout'));
      expect(value, isNot(contains('8443')));
      expect(value, isNot(contains(endpoint)));
    }
  });
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

  test('clipboard report keeps grouped failures ahead of a routine flood', () {
    final report = buildDiagnosticReport(
      applicationName: 'Example Client',
      status: const {'core.status': 'connected'},
      logs: [
        for (final second in ['00', '01'])
          Log(
            logLevel: LogLevel.warning,
            payload:
                '[TCP] dial --> example.com:443 using Private-Node TLS handshake timeout',
            dateTime: '2026-09-11T00:00:$second',
          ),
        for (var index = 0; index < 400; index++)
          Log(
            payload: index.isEven
                ? '[APP] updateGroups'
                : '[APP] destination=AppLifecycleState.paused',
            dateTime: '2026-09-11T00:01:00',
          ),
      ],
      logLineLimit: 1,
    );

    expect(report, contains('signals=tls,handshake,timeout'));
    expect(report, contains('x2 first=2026-09-11T00:00:00'));
    expect(report, contains('2026-09-11T00:00:01 [warning]'));
    expect(report, contains('logs.total=402 logs.included=1'));
    expect(report, contains('group-refresh:200 app-lifecycle:200'));
    expect(report, isNot(contains('Private-Node')));
    expect(report, isNot(contains('AppLifecycleState')));
    expect(utf8.encode(report).length, lessThan(1500));
  });

  test('clipboard byte budget preserves critical evidence and omission counts', () {
    final longText = List.filled(600, '网络😀').join();
    final report = buildDiagnosticReport(
      applicationName: 'Example Client',
      status: {
        for (var index = 0; index < 80; index++) 'detail.$index': longText,
        'app.build': '2026091007',
        'config.managedRouteMode': 'bypass-mainland',
        'probe.selectedProxy.success': false,
      },
      logs: [
        for (var index = 0; index < 100; index++)
          Log(
            logLevel: LogLevel.error,
            payload:
                'DNS timeout event $index $longText token=never-export-this',
            dateTime: '2026-09-11T00:00:00',
          ),
      ],
      platformLogs: [
        for (var index = 0; index < 50; index++)
          'VpnService event $index $longText host=private.example.com',
        'VpnService start failed',
      ],
      routeSamples: [
        for (var index = 0; index < 30; index++)
          'destination=web$index.example.com:443 network=tcp route=proxy '
              'rule=match policy=fallback phase=active duration=active end=pending upload=1 download=2',
        'destination=failed.example.com:443 network=udp route=reject '
            'rule=transport policy=other phase=closed duration=lt1s end=refused upload=0 download=0',
      ],
    );

    expect(
      utf8.encode(report).length,
      lessThanOrEqualTo(diagnosticReportByteLimit),
    );
    expect(utf8.decode(utf8.encode(report)), report);
    expect(report, contains('app.build=2026091007'));
    expect(report, contains('config.managedRouteMode=bypass-mainland'));
    expect(report, contains('probe.selectedProxy.success=false'));
    expect(report, contains('DNS timeout'));
    expect(report, contains('failed.example.com:443 | udp | reject'));
    expect(report, contains('VpnService start failed'));
    expect(report, contains('--- coverage ---'));
    expect(report, matches(r'routes.omitted=[1-9][0-9]*'));
    expect(report, matches(r'status.omitted=[1-9][0-9]*'));
    expect(report, matches(r'logs.omittedGroups=[1-9][0-9]*'));
    expect(report, contains('…'));
    expect(report, isNot(contains('never-export-this')));
    expect(report, isNot(contains('private.example.com')));
  });

  test('route destinations are not duplicated in the destination section', () {
    final report = buildDiagnosticReport(
      applicationName: 'Example Client',
      status: const {},
      logs: const [],
      visitedDestinations: const ['example.com:443', 'other.example.com:80'],
      routeSamples: const [
        'destination=example.com:443 network=tcp route=direct rule=match '
            'policy=fallback phase=active duration=active end=pending upload=1 download=2',
      ],
    );

    expect('example.com:443'.allMatches(report), hasLength(1));
    expect(report, contains('destinations.included=1'));
    expect(report, contains('other.example.com:80'));
  });

  test('zero log allowance retains status and reports excluded groups', () {
    final report = buildDiagnosticReport(
      applicationName: 'Example Client',
      status: const {'core.status': 'connected'},
      logs: const [Log(payload: 'hidden event', dateTime: 'now')],
      logLineLimit: -1,
    );

    expect(report, contains('core.status=connected'));
    expect(report, contains('logs.included=0 logs.omittedGroups=1'));
    expect(report, isNot(contains('hidden event')));
  });

  test('unclassified app URL logs do not expose endpoints or route data', () {
    expect(
      sanitizePrivateClientLog(
        '[APP] find https://example.com/private/path?token=secret '
        'proxy=Private-Node',
      ),
      '[APP] find [url] proxy=[redacted]',
    );
    expect(
      sanitizePrivateClientLog('connected using Private-Node'),
      isNot(contains('Private-Node')),
    );
  });

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

  test(
    'server endpoint matches retain reentry evidence without node addresses',
    () {
      final tracker = TrackerInfo(
        id: 'endpoint',
        start: DateTime.fromMillisecondsSinceEpoch(1),
        metadata: const Metadata(
          type: 'Tun',
          network: 'tcp',
          host: 'private-node.example.com',
          destinationIP: '192.0.2.10',
          destinationPort: '8443',
        ),
        chains: const ['private-node'],
        rule: 'MATCH',
        rulePayload: '',
        diagnosticDestination: 'server-endpoint',
        diagnosticRoute: 'proxy',
        diagnosticRule: 'match',
        diagnosticPolicy: 'fallback',
      );
      final report = buildDiagnosticReport(
        applicationName: 'Test',
        status: {},
        logs: [],
        visitedDestinations: collectVisitedDestinations([tracker]),
        routeSamples: collectDiagnosticRouteSamples([tracker]),
      );
      expect(report, contains('[server-endpoint]'));
      expect(report, isNot(contains('8443')));
      expect(report, contains('in=tun'));
      expect(report, isNot(contains('private-node')));
      expect(report, isNot(contains('192.0.2.10')));
      expect(report, contains('match/fallback'));
    },
  );

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
        'mmhead.c2c.wechat.com:443 | tcp | proxy | match/fallback | '
        'closed/closed | 5-30s | 123/456',
      ),
    );
    expect(
      report,
      contains(
        '[240e:e1:aa00:101a::48]:443 | tcp | reject | ip/ipv6-block | '
        'closed/idle-timeout | 30-120s | 0/0',
      ),
    );
    expect(
      report,
      contains(
        '[240e:978:d04:3003::27]:443 | udp | direct | ip/mainland-ip | '
        'closed/eof | lt1s | 0/0',
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
