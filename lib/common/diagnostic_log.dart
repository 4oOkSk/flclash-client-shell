import 'package:fl_clash/models/common.dart';

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

/// Client log rendering keeps only an explicitly recognized visited
/// destination. Proxy chains, server names and arbitrary log payloads still go
/// through the strict diagnostic sanitizer.
String sanitizeClientLog(String value) {
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
