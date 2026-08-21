import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';

bool diagnosticTunActive({
  required bool isAndroid,
  required bool runtimeTunEnabled,
  required bool platformTunEstablished,
}) => isAndroid
    ? platformTunEstablished
    : runtimeTunEnabled || platformTunEstablished;

Map<String, Object?> parseClientRuntimeDiagnostics(String raw) {
  if (raw.isEmpty) return const {};
  final decoded = json.decode(raw);
  if (decoded is! Map) return const {};
  final data = Map<String, dynamic>.from(decoded);
  final geoIP = data['geoip'] is Map
      ? Map<String, dynamic>.from(data['geoip'] as Map)
      : const <String, dynamic>{};
  final geoSite = data['geosite'] is Map
      ? Map<String, dynamic>.from(data['geosite'] as Map)
      : const <String, dynamic>{};
  return {
    'client.sessionPresent': data['session_present'] ?? false,
    'client.cachePresent': data['cache_present'] ?? false,
    'client.cacheAgeSeconds': data['cache_age_seconds'] ?? -1,
    'client.lastRefreshAt': data['last_refresh_at'] ?? 0,
    'client.lastRefreshResult': data['last_refresh_result'] ?? 'unknown',
    'client.lastRefreshStatus': data['last_refresh_status'] ?? 'unknown',
    'client.lastRefreshDurationMs': data['last_refresh_duration_ms'] ?? -1,
    'client.lastApplyAt': data['last_apply_at'] ?? 0,
    'client.lastApplyResult': data['last_apply_result'] ?? 'unknown',
    'client.secureStorage': data['secure_storage'] ?? 'unknown',
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

Map<String, Object?> buildDiagnosticLogSummary(Iterable<Log> logs) {
  var errors = 0;
  var warnings = 0;
  var trafficEvents = 0;
  var dnsErrors = 0;
  var tunErrors = 0;
  var apiErrors = 0;
  for (final log in logs) {
    final lower = log.payload.toLowerCase();
    final isError = log.logLevel == LogLevel.error || lower.contains('error');
    if (log.logLevel == LogLevel.error) errors++;
    if (log.logLevel == LogLevel.warning) warnings++;
    if (lower.contains('[tcp]') || lower.contains('[udp]')) trafficEvents++;
    if (isError && (lower.contains('dns') || lower.contains('resolver'))) {
      dnsErrors++;
    }
    if (isError && (lower.contains('tun') || lower.contains('vpnservice'))) {
      tunErrors++;
    }
    if (isError &&
        (lower.contains('client config') || lower.contains('client login'))) {
      apiErrors++;
    }
  }
  return {
    'recent.errorCount': errors,
    'recent.warningCount': warnings,
    'recent.trafficEventCount': trafficEvents,
    'recent.dnsErrorCount': dnsErrors,
    'recent.tunErrorCount': tunErrors,
    'recent.apiErrorCount': apiErrors,
  };
}

Map<String, Object?> buildConnectionSummary(Iterable<TrackerInfo> trackers) {
  var direct = 0;
  var proxy = 0;
  var tcp = 0;
  var udp = 0;
  for (final tracker in trackers) {
    final directChain = tracker.chains.any(
      (chain) => chain.toUpperCase() == 'DIRECT',
    );
    if (directChain) {
      direct++;
    } else {
      proxy++;
    }
    switch (tracker.metadata.network.toLowerCase()) {
      case 'tcp':
        tcp++;
      case 'udp':
        udp++;
    }
  }
  return {
    'routes.activeConnections': direct + proxy,
    'routes.activeDirect': direct,
    'routes.activeProxy': proxy,
    'routes.activeTcp': tcp,
    'routes.activeUdp': udp,
  };
}

Map<String, Object?> diagnosticProbeResult(String name, Delay? delay) {
  final value = delay?.value ?? -1;
  return {
    'probe.$name.success': value > 0,
    'probe.$name.latencyMs': value > 0 ? value : -1,
    'probe.$name.error': value > 0 ? 'none' : 'unavailable-or-timeout',
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
$helperServiceName = 'HarborProxyHelperService'
$helperExecutableName = 'HarborProxyHelperService.exe'
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

$helper = Get-CimInstance Win32_Service -Filter "Name='$helperServiceName'" -ErrorAction SilentlyContinue
if ($null -eq $helper) {
  Write-Output 'desktop.helperService=absent'
  Write-Output 'desktop.helperStartMode=unknown'
  Write-Output 'desktop.helperProcess=not-running'
  Write-Output 'desktop.helperExitCode=unknown'
} else {
  $helperState = switch ($helper.State) {
    'Running' { 'running' }
    'Stopped' { 'stopped' }
    'Start Pending' { 'start-pending' }
    'Stop Pending' { 'stop-pending' }
    'Continue Pending' { 'continue-pending' }
    'Pause Pending' { 'pause-pending' }
    'Paused' { 'paused' }
    default { 'other' }
  }
  $helperStartMode = switch ($helper.StartMode) {
    'Auto' { 'auto' }
    'Manual' { 'manual' }
    'Disabled' { 'disabled' }
    default { 'unknown' }
  }
  $helperProcess = if ([uint32]$helper.ProcessId -gt 0) { 'running' } else { 'not-running' }
  $helperExitCode = if ($null -ne $helper.ExitCode) { [uint32]$helper.ExitCode } else { 'unknown' }
  Write-Output ("desktop.helperService={0}" -f $helperState)
  Write-Output ("desktop.helperStartMode={0}" -f $helperStartMode)
  Write-Output ("desktop.helperProcess={0}" -f $helperProcess)
  Write-Output ("desktop.helperExitCode={0}" -f $helperExitCode)
}

try {
  $helperListeners = @(Get-NetTCPConnection -LocalPort 47890 -State Listen -ErrorAction SilentlyContinue)
  if ($helperListeners.Count -eq 0) {
    $helperPortOwner = 'unbound'
  } else {
    $ownerClasses = @($helperListeners | ForEach-Object {
      $owner = Get-CimInstance Win32_Process -Filter ("ProcessId={0}" -f $_.OwningProcess) -ErrorAction SilentlyContinue
      $ownerName = if ($null -ne $owner -and $null -ne $owner.Name) { [string]$owner.Name } else { '' }
      switch ($ownerName.ToLowerInvariant()) {
        'harborproxyhelperservice.exe' { 'harborproxy-helper' }
        'flclashhelperservice.exe' { 'flclash-helper' }
        'harborproxycore.exe' { 'harborproxy-core' }
        'flclashcore.exe' { 'flclash-core' }
        'harborproxy.exe' { 'harborproxy-app' }
        'flclash.exe' { 'flclash-app' }
        'system' { 'system' }
        default { 'other' }
      }
    } | Sort-Object -Unique)
    $helperPortOwner = if ($ownerClasses.Count -eq 1) { $ownerClasses[0] } else { 'multiple' }
  }
  Write-Output ("desktop.helperPortOwner={0}" -f $helperPortOwner)
} catch {
  Write-Output 'desktop.helperPortOwner=unknown'
}

try {
  $since = (Get-Date).AddHours(-24)
  $serviceEvent = Get-WinEvent -FilterHashtable @{
    LogName = 'System'
    ProviderName = 'Service Control Manager'
    StartTime = $since
    Id = 7000,7001,7009,7011,7023,7024,7031,7034
  } -MaxEvents 100 -ErrorAction SilentlyContinue | Where-Object {
    $_.Message -match [regex]::Escape($helperServiceName) -or
    $_.Message -match 'HarborProxy Helper Service'
  } | Select-Object -First 1
  $crashEvent = Get-WinEvent -FilterHashtable @{
    LogName = 'Application'
    StartTime = $since
    Id = 1000,1001
  } -MaxEvents 100 -ErrorAction SilentlyContinue | Where-Object {
    $_.Message -match [regex]::Escape($helperExecutableName)
  } | Select-Object -First 1
  $recentEvent = @($serviceEvent, $crashEvent) | Where-Object { $null -ne $_ } |
    Sort-Object TimeCreated -Descending | Select-Object -First 1
  if ($null -eq $recentEvent) {
    Write-Output 'desktop.helperRecentError=none'
  } elseif ($recentEvent.ProviderName -eq 'Service Control Manager') {
    Write-Output ("desktop.helperRecentError=scm-{0}" -f $recentEvent.Id)
  } elseif ($recentEvent.Id -eq 1000) {
    Write-Output 'desktop.helperRecentError=appcrash-1000'
  } else {
    Write-Output 'desktop.helperRecentError=wer-1001'
  }
} catch {
  Write-Output 'desktop.helperRecentError=unavailable'
}
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
