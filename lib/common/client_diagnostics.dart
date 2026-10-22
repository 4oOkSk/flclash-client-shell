import 'dart:convert';
import 'dart:io';

Map<String, Object?> parseClientRuntimeDiagnostics(String raw) {
  if (raw.isEmpty) return const {};
  final decoded = json.decode(raw);
  if (decoded is! Map) return const {};
  final data = Map<String, dynamic>.from(decoded);
  final dns = data['dns'] is Map ? data['dns'] as Map : const {};
  final geoIP = data['geoip'] is Map
      ? Map<String, dynamic>.from(data['geoip'] as Map)
      : const <String, dynamic>{};
  final geoSite = data['geosite'] is Map
      ? Map<String, dynamic>.from(data['geosite'] as Map)
      : const <String, dynamic>{};
  return {
    'dns.scope': 'VPN/listener requests; core-process lifetime',
    'dns.completed': dns['completed'] ?? 'unavailable',
    'dns.failed': dns['failed'] ?? 'unavailable',
    'dns.timeouts': dns['timeouts'] ?? 'unavailable',
    'dns.lastFailureAt': dns['last_failure_at'] ?? 'unavailable',
    'vpn.protectFailures': data['protect_failures'] ?? 'unavailable',
    'core.version': data['core_version'] ?? 'unknown',
    'geo.geoipPresent': geoIP['present'] ?? false,
    'geo.geoipAgeSeconds': geoIP['age_seconds'] ?? -1,
    'geo.geoipSizeBytes': geoIP['size_bytes'] ?? 0,
    'geo.geositePresent': geoSite['present'] ?? false,
    'geo.geositeAgeSeconds': geoSite['age_seconds'] ?? -1,
    'geo.geositeSizeBytes': geoSite['size_bytes'] ?? 0,
    'geo.lastUpdateAt': data['last_geo_update_at'] ?? 0,
    'geo.lastUpdateType': data['last_geo_update_type'] ?? 'unknown',
    'geo.lastUpdateResult': data['last_geo_update_result'] ?? 'unknown',
  };
}

Future<List<String>> collectDesktopPlatformDiagnostics({
  required bool coreProcessRunning,
  required bool transportConnected,
  required bool isAdmin,
}) async {
  final lines = <String>[
    'desktop.coreProcess=${coreProcessRunning ? 'running' : 'not-running'}',
    'desktop.transport=${transportConnected ? 'connected' : 'disconnected'}',
    'desktop.admin=${isAdmin ? 'yes' : 'no'}',
  ];
  if (!Platform.isWindows && !Platform.isLinux && !Platform.isMacOS) {
    return lines;
  }
  try {
    if (Platform.isWindows) {
      lines.addAll(await _windowsNetworkDiagnostics());
    } else {
      lines.addAll(await _unixNetworkDiagnostics());
    }
  } catch (error) {
    lines.add('desktop.networkDiagnostics=unavailable-${error.runtimeType}');
  }
  return lines;
}

Future<List<String>> _windowsNetworkDiagnostics() async {
  const script = r'''
$ErrorActionPreference = 'Stop'
$adapters = @(Get-NetAdapter -IncludeHidden | Where-Object {
  $_.Name -match 'HarborProxy|Mihomo|Wintun|WireGuard' -or
  $_.InterfaceDescription -match 'HarborProxy|Mihomo|Wintun|WireGuard'
})
$up = @($adapters | Where-Object Status -eq 'Up')
$indices = @($adapters | ForEach-Object InterfaceIndex)
$ipif = @(Get-NetIPInterface -ErrorAction SilentlyContinue | Where-Object {
  $indices -contains $_.InterfaceIndex
})
$routes = @(Get-NetRoute -ErrorAction SilentlyContinue | Where-Object {
  $indices -contains $_.InterfaceIndex
})
$dns = @(Get-DnsClientServerAddress -ErrorAction SilentlyContinue | Where-Object {
  $indices -contains $_.InterfaceIndex
} | ForEach-Object ServerAddresses)
$mtus = @($ipif | ForEach-Object NlMtuBytes | Sort-Object -Unique)
Write-Output ("desktop.tunCandidates={0}" -f $adapters.Count)
Write-Output ("desktop.tunUp={0}" -f $up.Count)
Write-Output ("desktop.tunMtu={0}" -f ($(if ($mtus.Count) { $mtus -join ',' } else { 'unknown' })))
Write-Output ("desktop.tunRoutes={0}" -f $routes.Count)
Write-Output ("desktop.tunDnsServers={0}" -f $dns.Count)
''';
  final result = await Process.run('powershell.exe', [
    '-NoProfile',
    '-NonInteractive',
    '-Command',
    script,
  ]).timeout(const Duration(seconds: 5));
  if (result.exitCode != 0) return const ['desktop.networkDiagnostics=failed'];
  return (result.stdout as String)
      .split(RegExp(r'\r?\n'))
      .map((line) => line.trim())
      .where((line) => line.startsWith('desktop.'))
      .toList(growable: false);
}

Future<List<String>> _unixNetworkDiagnostics() async {
  final interfaces = await NetworkInterface.list(
    includeLoopback: false,
    type: InternetAddressType.any,
  );
  final tunNames = interfaces
      .map((item) => item.name)
      .where(
        (name) => Platform.isMacOS
            ? name.startsWith('utun')
            : RegExp(
                r'^(tun|tap|mihomo|harborproxy)',
                caseSensitive: false,
              ).hasMatch(name),
      )
      .toSet();
  final mtus = <int>{};
  if (Platform.isLinux) {
    for (final name in tunNames) {
      final value = int.tryParse(
        await File('/sys/class/net/$name/mtu').readAsString(),
      );
      if (value != null) mtus.add(value);
    }
  } else {
    for (final name in tunNames) {
      final result = await Process.run('/sbin/ifconfig', [name]);
      final match = RegExp(r'\bmtu\s+(\d+)').firstMatch('${result.stdout}');
      final value = int.tryParse(match?.group(1) ?? '');
      if (value != null) mtus.add(value);
    }
  }
  final routeCount = Platform.isLinux
      ? await _linuxRouteCount(tunNames)
      : await _macRouteCount(tunNames);
  final dnsCount = Platform.isLinux
      ? await _linuxDnsCount()
      : await _macDnsCount();
  return [
    'desktop.tunCandidates=${tunNames.length}',
    'desktop.tunUp=${tunNames.length}',
    'desktop.tunMtu=${mtus.isEmpty ? 'unknown' : mtus.join(',')}',
    'desktop.tunRoutes=$routeCount',
    'desktop.tunDnsServers=$dnsCount',
  ];
}

Future<int> _linuxRouteCount(Set<String> tunNames) async {
  var count = 0;
  for (final path in ['/proc/net/route', '/proc/net/ipv6_route']) {
    final file = File(path);
    if (!await file.exists()) continue;
    for (final line in await file.readAsLines()) {
      final fields = line.trim().split(RegExp(r'\s+'));
      if (fields.isNotEmpty &&
          (tunNames.contains(fields.first) || tunNames.contains(fields.last))) {
        count++;
      }
    }
  }
  return count;
}

Future<int> _linuxDnsCount() async {
  final file = File('/etc/resolv.conf');
  if (!await file.exists()) return 0;
  return (await file.readAsLines())
      .where((line) => line.trimLeft().startsWith('nameserver '))
      .length;
}

Future<int> _macRouteCount(Set<String> tunNames) async {
  final result = await Process.run('/usr/sbin/netstat', ['-rn']);
  return '${result.stdout}'
      .split('\n')
      .where((line) => tunNames.any((name) => line.contains(name)))
      .length;
}

Future<int> _macDnsCount() async {
  final result = await Process.run('/usr/sbin/scutil', ['--dns']);
  return RegExp(r'nameserver\[\d+\]').allMatches('${result.stdout}').length;
}
