import 'package:fl_clash/models/common.dart';

const diagnosticLogLineLimit = 200;

final _trafficLogPattern = RegExp(r'\[(?:TCP|UDP)\]', caseSensitive: false);
final _sensitiveValuePattern = RegExp(
  r'\b(password|passwd|token|session|cookie|authorization|uuid|server|address|host|sni|path|endpoint|email|user|username|proxy|node|chain|outbound)\b\s*[:=]\s*("[^"]*"|\x27[^\x27]*\x27|[^\s,;}]+)',
  caseSensitive: false,
);
final _uriPattern = RegExp(
  r'\b(?:https?|socks5?|vless|vmess|trojan|hysteria2?|hy2|ss)://[^\s<>()]+',
  caseSensitive: false,
);
final _emailPattern = RegExp(
  r'\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b',
  caseSensitive: false,
);
final _uuidPattern = RegExp(
  r'\b[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\b',
  caseSensitive: false,
);
final _ipv4Pattern = RegExp(r'\b(?:\d{1,3}\.){3}\d{1,3}(?::\d{1,5})?\b');
final _ipv6Pattern = RegExp(
  r'(?<![A-Za-z0-9])(?:(?:[0-9A-Fa-f]{1,4}:){3,7}[0-9A-Fa-f]{0,4}|[0-9A-Fa-f]{0,4}::[0-9A-Fa-f:]{0,})(?![A-Za-z0-9])',
);
final _domainPattern = RegExp(
  r'\b(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}\b',
  caseSensitive: false,
);
final _windowsPathPattern = RegExp(r'[A-Za-z]:\\[^\s<>"|]+');
final _pathPattern = RegExp(r'/[A-Za-z0-9._~!$&()*+,;=:@%/-]+');
final _longSecretPattern = RegExp(r'\b[A-Za-z0-9_+=/-]{32,}\b');
final _usingPattern = RegExp(r'\busing\s+.+$', caseSensitive: false);
final _trafficDestinationPattern = RegExp(
  r'^\[(TCP|UDP)\].*?-->\s*([^\s]+)(?:\s+using\s+.*)?$',
  caseSensitive: false,
);
final _appFindDestinationPattern = RegExp(
  r'^\[APP\]\s+find\s+(https?://[^\s]+)\s+proxy=',
  caseSensitive: false,
);
final _appDestinationPattern = RegExp(
  r'^\[APP\]\s+(https?://[^\s]+|[^\s]+)$',
  caseSensitive: false,
);
final _ipv4DestinationPattern = RegExp(
  r'^(\d{1,3}(?:\.\d{1,3}){3})(?::(\d{1,5}))?$',
);
final _ipv6DestinationPattern = RegExp(
  r'^(?:\[([0-9A-Fa-f:]+)\](?::(\d{1,5}))?|([0-9A-Fa-f:]+))$',
);
final _domainDestinationPattern = RegExp(
  r'^((?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63})(?::(\d{1,5}))?$',
);
final _routeSamplePattern = RegExp(
  r'^destination=(\S+) network=(tcp|udp|other) '
  r'route=(direct|proxy|reject|unknown) '
  r'rule=(domain|ip|rule-set|match|transport|process|none|other|unknown) '
  r'policy=(private|httpdns|ipv6-block|probe|overseas-service|overseas-domain|mainland-domain|mainland-ip|fallback|local|other|unknown) '
  r'phase=(active|closed) duration=(active|lt1s|1-5s|5-30s|30-120s|2mplus) '
  r'end=(pending|eof|timeout|idle-timeout|reset|refused|unreachable|closed|no-response|idle|io-error|unknown) '
  r'upload=(\d+) download=(\d+)$',
);

const _diagnosticRoutes = {'direct', 'proxy', 'reject'};
const _diagnosticRules = {
  'domain',
  'ip',
  'rule-set',
  'match',
  'transport',
  'process',
  'none',
  'other',
};
const _diagnosticPolicies = {
  'private',
  'httpdns',
  'ipv6-block',
  'probe',
  'overseas-service',
  'overseas-domain',
  'mainland-domain',
  'mainland-ip',
  'fallback',
  'local',
  'other',
};
const _diagnosticEndReasons = {
  'eof',
  'timeout',
  'idle-timeout',
  'reset',
  'refused',
  'unreachable',
  'closed',
  'no-response',
  'idle',
  'io-error',
};

/// Keeps troubleshooting signals while removing data that can disclose the
/// private API, account, subscription, proxy nodes, or network addresses.
String sanitizeDiagnosticLog(String value) {
  var result = value.replaceAll('\r', '').replaceAll('\n', r'\n');
  if (_trafficLogPattern.hasMatch(result)) {
    return '[traffic event redacted]';
  }
  result = result.replaceAllMapped(
    _sensitiveValuePattern,
    (match) => '${match.group(1)}=[redacted]',
  );
  result = result
      .replaceAll(_uriPattern, '[url]')
      .replaceAll(_emailPattern, '[email]')
      .replaceAll(_uuidPattern, '[uuid]')
      .replaceAll(_ipv4Pattern, '[ipv4]')
      .replaceAll(_ipv6Pattern, '[ipv6]')
      .replaceAll(_domainPattern, '[domain]')
      .replaceAll(_windowsPathPattern, '[path]')
      .replaceAll(_pathPattern, '[path]')
      .replaceAll(_longSecretPattern, '[secret]')
      .replaceAll(_usingPattern, 'using [redacted]');
  return result.length <= 2048 ? result : '${result.substring(0, 2048)}…';
}

String? sanitizeVisitedDestination(String value) {
  final candidate = value.trim();
  if (candidate.isEmpty || candidate.length > 512) return null;
  final uri = Uri.tryParse(candidate);
  if (uri != null &&
      (uri.scheme == 'http' || uri.scheme == 'https') &&
      uri.host.isNotEmpty) {
    if (!_isSafeDestinationHost(uri.host) || !_isSafePort(uri.port)) {
      return null;
    }
    final port = uri.hasPort ? ':${uri.port}' : '';
    return '${uri.scheme}://${uri.host}$port';
  }
  final ipv4Match = _ipv4DestinationPattern.firstMatch(candidate);
  if (ipv4Match != null &&
      _isValidIpv4(ipv4Match.group(1)!) &&
      _isSafePortText(ipv4Match.group(2))) {
    return candidate;
  }
  final ipv6Match = _ipv6DestinationPattern.firstMatch(candidate);
  final ipv6 = ipv6Match?.group(1) ?? ipv6Match?.group(3);
  if (ipv6 != null &&
      _isValidIpv6(ipv6) &&
      _isSafePortText(ipv6Match?.group(2))) {
    return candidate;
  }
  final domainMatch = _domainDestinationPattern.firstMatch(candidate);
  if (domainMatch != null && _isSafePortText(domainMatch.group(2))) {
    return candidate;
  }
  return null;
}

bool _isSafeDestinationHost(String host) {
  return _isValidIpv4(host) ||
      _isValidIpv6(host) ||
      _domainDestinationPattern.hasMatch(host);
}

bool _isValidIpv6(String value) {
  final candidate = value.trim();
  if (!candidate.contains(':') ||
      !RegExp(r'^[0-9A-Fa-f:]+$').hasMatch(candidate)) {
    return false;
  }
  final doubleColon = candidate.indexOf('::');
  if (doubleColon != candidate.lastIndexOf('::')) return false;
  final pieces = candidate.split(':');
  if (pieces.any((piece) => piece.length > 4)) return false;
  final nonEmpty = pieces.where((piece) => piece.isNotEmpty).length;
  return doubleColon >= 0 ? nonEmpty < 8 : nonEmpty == 8;
}

bool _isValidIpv4(String value) {
  final parts = value.split('.');
  if (parts.length != 4) return false;
  return parts.every((part) {
    final number = int.tryParse(part);
    return number != null && number >= 0 && number <= 255;
  });
}

bool _isSafePort(int port) => port >= 0 && port <= 65535;

bool _isSafePortText(String? value) {
  if (value == null) return true;
  final port = int.tryParse(value);
  return port != null && port > 0 && port <= 65535;
}

/// Private-client log rendering keeps only an explicitly recognized visited
/// destination. Proxy chains, server names and arbitrary log payloads still go
/// through the strict diagnostic sanitizer.
String sanitizePrivateClientLog(String value) {
  final normalized = value.replaceAll('\r', '').replaceAll('\n', r'\n');
  final trafficMatch = _trafficDestinationPattern.firstMatch(normalized);
  if (trafficMatch != null) {
    final destination = sanitizeVisitedDestination(trafficMatch.group(2) ?? '');
    if (destination != null) {
      return '[${trafficMatch.group(1)!.toUpperCase()}] $destination';
    }
  }
  final findMatch = _appFindDestinationPattern.firstMatch(normalized);
  if (findMatch != null) {
    final destination = sanitizeVisitedDestination(findMatch.group(1) ?? '');
    if (destination != null) return '[APP] destination=$destination';
  }
  final appMatch = _appDestinationPattern.firstMatch(normalized);
  if (appMatch != null) {
    final destination = sanitizeVisitedDestination(appMatch.group(1) ?? '');
    if (destination != null) return '[APP] destination=$destination';
  }
  return sanitizeDiagnosticLog(normalized);
}

String? trackerVisitedDestination(TrackerInfo trackerInfo) {
  final metadata = trackerInfo.metadata;
  // Inner trackers describe the proxy/dialer hop itself, not a website the
  // user visited. Never let private server addresses cross the report boundary.
  if (metadata.type.toLowerCase() == 'inner') return null;
  final host = metadata.host.trim();
  final address = host.isNotEmpty ? host : metadata.destinationIP.trim();
  if (address.isEmpty) return null;
  final port = metadata.destinationPort.trim();
  final bracketed = address.contains(':') && !address.startsWith('[')
      ? '[$address]'
      : address;
  return sanitizeVisitedDestination(
    port.isEmpty ? bracketed : '$bracketed:$port',
  );
}

List<String> collectVisitedDestinations(
  Iterable<TrackerInfo> trackerInfos, {
  int limit = 30,
}) {
  if (limit <= 0) return const [];
  final seen = <String>{};
  final result = <String>[];
  for (final trackerInfo in trackerInfos) {
    final destination = trackerVisitedDestination(trackerInfo);
    if (destination == null || !seen.add(destination)) continue;
    result.add(destination);
    if (result.length >= limit) break;
  }
  return result;
}

String? sanitizeDiagnosticRouteSample(String value) {
  final match = _routeSamplePattern.firstMatch(value.trim());
  if (match == null) return null;
  final destination = sanitizeVisitedDestination(match.group(1) ?? '');
  if (destination == null) return null;
  final upload = int.tryParse(match.group(9) ?? '');
  final download = int.tryParse(match.group(10) ?? '');
  if (upload == null || upload < 0 || download == null || download < 0) {
    return null;
  }
  return 'destination=$destination network=${match.group(2)} '
      'route=${match.group(3)} rule=${match.group(4)} '
      'policy=${match.group(5)} phase=${match.group(6)} '
      'duration=${match.group(7)} end=${match.group(8)} '
      'upload=$upload download=$download';
}

String? trackerDiagnosticRouteSample(TrackerInfo trackerInfo) {
  final destination = trackerVisitedDestination(trackerInfo);
  if (destination == null) return null;
  final network = switch (trackerInfo.metadata.network.toLowerCase()) {
    'tcp' => 'tcp',
    'udp' => 'udp',
    _ => 'other',
  };
  final route = _diagnosticRoutes.contains(trackerInfo.diagnosticRoute)
      ? trackerInfo.diagnosticRoute
      : _legacyDiagnosticRoute(trackerInfo.chains);
  final rule = _diagnosticRules.contains(trackerInfo.diagnosticRule)
      ? trackerInfo.diagnosticRule
      : 'unknown';
  final policy = _diagnosticPolicies.contains(trackerInfo.diagnosticPolicy)
      ? trackerInfo.diagnosticPolicy
      : 'unknown';
  final closed = trackerInfo.lifecycle == 'closed';
  final phase = closed ? 'closed' : 'active';
  final duration = closed
      ? _diagnosticDurationBucket(trackerInfo.durationMs)
      : 'active';
  final end = closed && _diagnosticEndReasons.contains(trackerInfo.endReason)
      ? trackerInfo.endReason
      : closed
      ? 'unknown'
      : 'pending';
  return sanitizeDiagnosticRouteSample(
    'destination=$destination network=$network route=$route rule=$rule '
    'policy=$policy phase=$phase duration=$duration end=$end '
    'upload=${trackerInfo.upload < 0 ? 0 : trackerInfo.upload} '
    'download=${trackerInfo.download < 0 ? 0 : trackerInfo.download}',
  );
}

String _legacyDiagnosticRoute(List<String> chains) {
  final normalized = chains.map((item) => item.toUpperCase()).toSet();
  if (normalized.contains('REJECT') || normalized.contains('REJECT-DROP')) {
    return 'reject';
  }
  if (normalized.contains('DIRECT')) return 'direct';
  return normalized.isEmpty ? 'unknown' : 'proxy';
}

String _diagnosticDurationBucket(int durationMs) {
  if (durationMs < 1000) return 'lt1s';
  if (durationMs < 5000) return '1-5s';
  if (durationMs < 30000) return '5-30s';
  if (durationMs < 120000) return '30-120s';
  return '2mplus';
}

List<String> collectDiagnosticRouteSamples(
  Iterable<TrackerInfo> trackerInfos, {
  int limit = 30,
}) {
  if (limit <= 0) return const [];
  final byId = <String, _DiagnosticTrackerSnapshot>{};
  final withoutId = <_DiagnosticTrackerSnapshot>[];
  var ordinal = 0;
  for (final trackerInfo in trackerInfos) {
    final snapshot = _DiagnosticTrackerSnapshot(trackerInfo, ordinal++);
    if (trackerInfo.id.isEmpty) {
      withoutId.add(snapshot);
      continue;
    }
    final previous = byId[trackerInfo.id];
    if (previous == null || snapshot.isPreferredTo(previous)) {
      byId[trackerInfo.id] = snapshot;
    }
  }

  final snapshots = [...byId.values, ...withoutId];
  final active = _buildDiagnosticSamples(
    snapshots.where((item) => !item.isClosed),
  );
  final closed = _buildDiagnosticSamples(
    snapshots.where((item) => item.isClosed),
  );
  final activeQuota = (limit + 1) ~/ 2;
  final closedQuota = limit ~/ 2;
  final activeCount = active.length < activeQuota ? active.length : activeQuota;
  final closedCount = closed.length < closedQuota ? closed.length : closedQuota;
  final selected = <_DiagnosticRouteSample>[
    ...active.take(activeCount),
    ...closed.take(closedCount),
  ];

  final remaining = <_DiagnosticRouteSample>[
    ...active.skip(activeCount),
    ...closed.skip(closedCount),
  ]..sort(_compareDiagnosticSamples);
  selected.addAll(remaining.take(limit - selected.length));
  selected.sort(_compareDiagnosticSamples);
  return selected.map((item) => item.value).toList(growable: false);
}

List<_DiagnosticRouteSample> _buildDiagnosticSamples(
  Iterable<_DiagnosticTrackerSnapshot> input,
) {
  final snapshots = input.toList()..sort(_compareDiagnosticSnapshots);
  final seen = <String>{};
  final result = <_DiagnosticRouteSample>[];
  for (final snapshot in snapshots) {
    final sample = trackerDiagnosticRouteSample(snapshot.trackerInfo);
    if (sample == null || !seen.add(sample)) continue;
    result.add(_DiagnosticRouteSample(sample, snapshot));
  }
  return result;
}

int _compareDiagnosticSnapshots(
  _DiagnosticTrackerSnapshot left,
  _DiagnosticTrackerSnapshot right,
) {
  final timeComparison = right.eventTime.compareTo(left.eventTime);
  if (timeComparison != 0) return timeComparison;
  return right.ordinal.compareTo(left.ordinal);
}

int _compareDiagnosticSamples(
  _DiagnosticRouteSample left,
  _DiagnosticRouteSample right,
) => _compareDiagnosticSnapshots(left.snapshot, right.snapshot);

class _DiagnosticTrackerSnapshot {
  const _DiagnosticTrackerSnapshot(this.trackerInfo, this.ordinal);

  final TrackerInfo trackerInfo;
  final int ordinal;

  bool get isClosed => trackerInfo.lifecycle == 'closed';

  int get eventTime =>
      trackerInfo.start.millisecondsSinceEpoch +
      (isClosed && trackerInfo.durationMs > 0 ? trackerInfo.durationMs : 0);

  bool isPreferredTo(_DiagnosticTrackerSnapshot previous) {
    if (isClosed != previous.isClosed) return isClosed;
    if (eventTime != previous.eventTime) return eventTime > previous.eventTime;
    final traffic = trackerInfo.upload + trackerInfo.download;
    final previousTraffic =
        previous.trackerInfo.upload + previous.trackerInfo.download;
    if (traffic != previousTraffic) return traffic > previousTraffic;
    return ordinal > previous.ordinal;
  }
}

class _DiagnosticRouteSample {
  const _DiagnosticRouteSample(this.value, this.snapshot);

  final String value;
  final _DiagnosticTrackerSnapshot snapshot;
}

String buildDiagnosticReport({
  required String applicationName,
  required Map<String, Object?> status,
  required Iterable<Log> logs,
  Iterable<String> platformLogs = const [],
  Iterable<String> visitedDestinations = const [],
  Iterable<String> routeSamples = const [],
  int logLineLimit = diagnosticLogLineLimit,
}) {
  final safeLimit = logLineLimit < 0 ? 0 : logLineLimit;
  final allLogs = logs.toList(growable: false);
  final start = (allLogs.length - safeLimit).clamp(0, allLogs.length).toInt();
  final recentLogs = allLogs.skip(start);
  final safePlatformLogs = platformLogs
      .map(sanitizeDiagnosticLog)
      .where((line) => line.isNotEmpty)
      .toList(growable: false);
  final safeDestinations = visitedDestinations
      .map(sanitizeVisitedDestination)
      .whereType<String>()
      .toSet()
      .take(30)
      .toList(growable: false);
  final safeRouteSamples = routeSamples
      .map(sanitizeDiagnosticRouteSample)
      .whereType<String>()
      .toSet()
      .take(30)
      .toList(growable: false);
  final buffer = StringBuffer(
    '${sanitizeDiagnosticLog(applicationName)} diagnostic report\n',
  );
  for (final entry in status.entries) {
    buffer
      ..write(entry.key)
      ..write('=')
      ..writeln(sanitizeDiagnosticLog('${entry.value ?? 'unknown'}'));
  }
  buffer
    ..writeln('logs.total=${allLogs.length}')
    ..writeln('logs.included=${recentLogs.length}')
    ..writeln('platformLogs.included=${safePlatformLogs.length}')
    ..writeln('destinations.included=${safeDestinations.length}')
    ..writeln('routes.included=${safeRouteSamples.length}');
  if (safeDestinations.isNotEmpty) {
    buffer.writeln('--- recent destinations ---');
    for (final destination in safeDestinations) {
      buffer.writeln(destination);
    }
  }
  if (safeRouteSamples.isNotEmpty) {
    buffer.writeln('--- recent routes ---');
    for (final sample in safeRouteSamples) {
      buffer.writeln(sample);
    }
  }
  buffer.writeln('--- recent logs ---');
  for (final log in recentLogs) {
    buffer
      ..write(sanitizeDiagnosticLog(log.dateTime))
      ..write(' [')
      ..write(log.logLevel.name)
      ..write('] ')
      ..writeln(sanitizePrivateClientLog(log.payload));
  }
  if (safePlatformLogs.isNotEmpty) {
    buffer.writeln('--- platform logs ---');
    for (final line in safePlatformLogs) {
      buffer.writeln(line);
    }
  }
  return buffer.toString();
}
