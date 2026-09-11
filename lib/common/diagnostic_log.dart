import 'dart:convert';

import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/common.dart';

const diagnosticLogLineLimit = 40;
const diagnosticReportByteLimit = 8192;
const diagnosticHealthScope = 'core outbound HTTPS; not browser or VPN';

final _diagnosticFailurePattern = RegExp(
  r'\b(error|failed|failure|timeout|refused|unreachable|rejected)\b|'
  r'timed out|no such host|reset by peer|unknown authority',
  caseSensitive: false,
);
final _diagnosticSignalPattern = RegExp(
  r'\b(dns|tls|ssl|x509|certificate|handshake|timeout|refused|unreachable|rejected)\b|'
  r'timed out|no such host|reset by peer|unknown authority',
  caseSensitive: false,
);

bool isDiagnosticFailure(Log log) =>
    log.logLevel == LogLevel.error ||
    _diagnosticFailurePattern.hasMatch(log.payload);

final _trafficLogPattern = RegExp(r'\[(?:TCP|UDP)\]', caseSensitive: false);
final _sensitiveValuePattern = RegExp(
  r'\b(password|passwd|token|session|cookie|authorization|uuid|server|address|host|port|sni|path|endpoint|email|user|username|proxy|node|chain|outbound)\b\s*[:=]\s*("[^"]*"|\x27[^\x27]*\x27|[^\s,;}]+)',
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
  r'\[[0-9A-Fa-f:.]+\](?::\d{1,5})?|(?<![A-Za-z0-9])(?:(?:[0-9A-Fa-f]{1,4}:){3,7}[0-9A-Fa-f]{0,4}|[0-9A-Fa-f]{0,4}::[0-9A-Fa-f:]{0,})(?![A-Za-z0-9])',
);
final _domainPattern = RegExp(
  r'\b(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}\b(?::\d{1,5})?',
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
  r'upload=(\d+) download=(\d+)(?: inbound=(tun|socks|http|mixed|other))?$',
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
  final endpointMatch = RegExp(
    r'^\[server-endpoint\](?::(\d{1,5}))?$',
  ).firstMatch(candidate);
  if (endpointMatch != null && _isSafePortText(endpointMatch.group(1))) {
    return '[server-endpoint]';
  }
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
  return sanitizeDiagnosticLog(normalized);
}

String? trackerVisitedDestination(TrackerInfo trackerInfo) {
  final metadata = trackerInfo.metadata;
  // Inner trackers describe the proxy/dialer hop itself, not a website the
  // user visited. Never let private server addresses cross the report boundary.
  if (metadata.type.toLowerCase() == 'inner') return null;
  if (trackerInfo.diagnosticDestination == 'server-endpoint') {
    return '[server-endpoint]';
  }
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
      'upload=$upload download=$download'
      '${match.group(11) == null ? '' : ' inbound=${match.group(11)}'}';
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
  final inbound = switch (trackerInfo.metadata.type.toLowerCase()) {
    'tun' => 'tun',
    'socks4' || 'socks5' => 'socks',
    'http' || 'https' => 'http',
    'mixed' => 'mixed',
    _ => 'other',
  };
  return sanitizeDiagnosticRouteSample(
    'destination=$destination network=$network route=$route rule=$rule '
    'policy=$policy phase=$phase duration=$duration end=$end '
    'upload=${trackerInfo.upload < 0 ? 0 : trackerInfo.upload} '
    'download=${trackerInfo.download < 0 ? 0 : trackerInfo.download} inbound=$inbound',
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
  final safeLimit = logLineLimit.clamp(0, diagnosticLogLineLimit);
  final allLogs = logs.toList(growable: false);
  final noise = <String, int>{};
  final groups = <String, _DiagnosticLogGroup>{};
  for (var index = 0; index < allLogs.length; index++) {
    final log = allLogs[index];
    final failure = isDiagnosticFailure(log);
    final important = failure || log.logLevel == LogLevel.warning;
    final category = important ? null : _diagnosticNoiseCategory(log.payload);
    if (category != null) {
      noise.update(category, (count) => count + 1, ifAbsent: () => 1);
      continue;
    }
    var payload = failure
        ? sanitizeDiagnosticLog(log.payload)
        : sanitizePrivateClientLog(log.payload);
    if (failure) {
      final signals = _diagnosticSignalPattern
          .allMatches(log.payload)
          .map((match) => match.group(0)!.toLowerCase().replaceAll(' ', '-'))
          .toSet()
          .join(',');
      if (signals.isNotEmpty) payload = '$payload signals=$signals';
    }
    final key = '${log.logLevel.name}:$payload';
    final group = groups.putIfAbsent(
      key,
      () => _DiagnosticLogGroup(log, payload, important),
    );
    group.count++;
    group.last = log.dateTime;
    group.ordinal = index;
  }
  final ordered = groups.values.toList()
    ..sort((left, right) {
      final priority = (left.important ? 0 : 1).compareTo(
        right.important ? 0 : 1,
      );
      return priority != 0 ? priority : right.ordinal.compareTo(left.ordinal);
    });
  final selected = ordered.take(safeLimit).toList();
  final errors = selected.where((group) => group.important).toList();
  final context = selected.where((group) => !group.important).toList();
  final safePlatformLogs = platformLogs
      .map(sanitizeDiagnosticLog)
      .where((line) => line.isNotEmpty)
      .toSet()
      .toList()
      .reversed
      .toList();
  final safeRouteSamples = routeSamples
      .map(sanitizeDiagnosticRouteSample)
      .whereType<String>()
      .toSet()
      .toList();
  final routeMatches = safeRouteSamples
      .map((sample) => _routeSamplePattern.firstMatch(sample)!)
      .toList();
  final failedRoutes = routeMatches.where(_isFailedDiagnosticRoute).toList();
  final otherRoutes = routeMatches.where(
    (match) => !_isFailedDiagnosticRoute(match),
  );
  final routeDestinations = routeMatches.map((match) => match.group(1)).toSet();
  final safeDestinations = visitedDestinations
      .map(sanitizeVisitedDestination)
      .whereType<String>()
      .where((destination) => !routeDestinations.contains(destination))
      .toSet()
      .toList();
  final primaryStatus = <String>[];
  final extraStatus = <String>[];
  for (final entry in status.entries) {
    final line =
        '${entry.key}=${_clipDiagnosticText(sanitizeDiagnosticLog('${entry.value ?? 'unknown'}'), 180)}';
    (_isPrimaryDiagnosticStatus(entry.key) ? primaryStatus : extraStatus).add(
      line,
    );
  }
  final writer = _DiagnosticReportWriter(
    '${_clipDiagnosticText(sanitizeDiagnosticLog(applicationName), 80)} diagnostic report\n'
    'format=2 maxBytes=$diagnosticReportByteLimit\n',
  );
  var statusIncluded = writer.addSection(
    'status',
    primaryStatus,
    byteLimit: 2800,
  );
  final errorsIncluded = writer.addSection(
    'errors/warnings (redacted duplicates grouped)',
    errors.map((group) => group.line),
    byteLimit: 1800,
  );
  final routesIncluded = writer.addSection(
    'routes: destination | net | route | rule/policy | phase/end | duration | up/down(B)',
    [...failedRoutes, ...otherRoutes].map(_compactDiagnosticRoute),
    byteLimit: 2200,
  );
  final platformIncluded = writer.addSection(
    'platform',
    [
      ...safePlatformLogs.where(_diagnosticFailurePattern.hasMatch),
      ...safePlatformLogs.where(
        (line) => !_diagnosticFailurePattern.hasMatch(line),
      ),
    ].map((line) => _clipDiagnosticText(line, 300)),
    byteLimit: 650,
  );
  statusIncluded += writer.addSection('details', extraStatus, byteLimit: 900);
  final destinationsIncluded = writer.addSection(
    'other destinations',
    safeDestinations,
    byteLimit: 450,
  );
  final contextIncluded = writer.addSection(
    'recent context (redacted duplicates grouped)',
    context.map((group) => group.line),
  );
  final logsIncluded = errorsIncluded + contextIncluded;
  final noiseSummary = noise.entries
      .map((entry) => '${entry.key}:${entry.value}')
      .join(' ');
  return writer.finish(
    '--- coverage ---\n'
    'logs.total=${allLogs.length} logs.included=$logsIncluded logs.omittedGroups=${groups.length - logsIncluded}\n'
    'routes.included=$routesIncluded routes.omitted=${safeRouteSamples.length - routesIncluded}\n'
    'platformLogs.included=$platformIncluded platformLogs.omitted=${safePlatformLogs.length - platformIncluded}\n'
    'destinations.included=$destinationsIncluded destinations.omitted=${safeDestinations.length - destinationsIncluded}\n'
    'status.omitted=${status.length - statusIncluded}\n'
    'noise=${noiseSummary.isEmpty ? 'none' : noiseSummary}\n',
  );
}

String? _diagnosticNoiseCategory(String payload) {
  final value = payload.replaceFirst(RegExp(r'^\[APP\]\s*'), '').trim();
  if (value == 'updateGroups') return 'group-refresh';
  if (value == 'checkIp start') return 'ip-check-start';
  if (value.startsWith('find ')) return 'http-lookup';
  if (RegExp(r'^(?:destination=)?AppLifecycleState\.').hasMatch(value)) {
    return 'app-lifecycle';
  }
  if (value.startsWith('Load GeoSite rule:')) return 'geosite-load';
  return null;
}

bool _isPrimaryDiagnosticStatus(String key) =>
    key == 'generatedAt' ||
    key == 'core.status' ||
    key == 'core.version' ||
    key == 'platform.os' ||
    key == 'platform.version' ||
    [
      'app.',
      'config.',
      'probe.',
      'collection.',
      'selection.',
      'health.',
      'routing.',
      'recent.',
      'routes.',
      'dns.',
      'vpn.',
    ].any(key.startsWith);

bool _isFailedDiagnosticRoute(RegExpMatch match) =>
    match.group(3) == 'reject' ||
    {
      'timeout',
      'idle-timeout',
      'reset',
      'refused',
      'unreachable',
      'no-response',
      'io-error',
    }.contains(match.group(8));

String _compactDiagnosticRoute(RegExpMatch match) =>
    '${match.group(1)} | ${match.group(2)} | ${match.group(3)} | '
    '${match.group(4)}/${match.group(5)} | ${match.group(6)}/${match.group(8)} | '
    '${match.group(7)} | ${match.group(9)}/${match.group(10)}'
    '${match.group(11) == null ? '' : ' | in=${match.group(11)}'}';

class _DiagnosticLogGroup {
  _DiagnosticLogGroup(Log log, this.payload, this.important)
    : level = log.logLevel.name,
      first = log.dateTime,
      last = log.dateTime;

  final String level;
  final String payload;
  final bool important;
  final String first;
  String last;
  int count = 0;
  int ordinal = 0;

  String get line =>
      '${_clipDiagnosticText(sanitizeDiagnosticLog(last), 32)} [$level] '
      '${count > 1 ? 'x$count first=${_clipDiagnosticText(sanitizeDiagnosticLog(first), 32)} ' : ''}'
      '${_clipDiagnosticText(payload, 360)}';
}

String _clipDiagnosticText(String value, int byteLimit) {
  final encoded = utf8.encode(value);
  final normalized = utf8.decode(encoded);
  if (encoded.length <= byteLimit) return normalized;
  final runes = normalized.runes.toList();
  final prefix = <int>[];
  final suffix = <int>[];
  final sideLimit = (byteLimit - 3) ~/ 2;
  var bytes = 0;
  for (final rune in runes) {
    bytes += utf8.encode(String.fromCharCode(rune)).length;
    if (bytes > sideLimit) break;
    prefix.add(rune);
  }
  bytes = 0;
  for (final rune in runes.reversed) {
    bytes += utf8.encode(String.fromCharCode(rune)).length;
    if (bytes > sideLimit) break;
    suffix.add(rune);
  }
  return String.fromCharCodes([...prefix, 0x2026, ...suffix.reversed]);
}

class _DiagnosticReportWriter {
  _DiagnosticReportWriter(String header)
    : _buffer = StringBuffer(header),
      _bytes = utf8.encode(header).length;

  final StringBuffer _buffer;
  int _bytes;

  int addSection(String title, Iterable<String> lines, {int? byteLimit}) {
    final heading = '--- $title ---\n';
    final headingBytes = utf8.encode(heading).length;
    final remaining = diagnosticReportByteLimit - 512 - _bytes;
    final limit = byteLimit == null || byteLimit > remaining
        ? remaining
        : byteLimit;
    final section = StringBuffer();
    var sectionBytes = headingBytes;
    var included = 0;
    for (final line in lines) {
      final lineBytes = utf8.encode('$line\n').length;
      if (sectionBytes + lineBytes > limit) continue;
      section.writeln(line);
      sectionBytes += lineBytes;
      included++;
    }
    if (included > 0) {
      _buffer.write(heading);
      _buffer.write(section);
      _bytes += sectionBytes;
    }
    return included;
  }

  String finish(String coverage) =>
      '$_buffer${_clipDiagnosticText(coverage, 512)}';
}
