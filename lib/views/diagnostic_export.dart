import 'dart:io';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/core.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/providers/client_health.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class DiagnosticExportItem extends ConsumerStatefulWidget {
  final CoreController? controller;

  const DiagnosticExportItem({super.key, this.controller});

  @override
  ConsumerState<DiagnosticExportItem> createState() =>
      _DiagnosticExportItemState();
}

class _DiagnosticExportItemState extends ConsumerState<DiagnosticExportItem> {
  bool _busy = false;

  Future<void> _copyDiagnosticLogs() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final controller = widget.controller ?? coreController;
      final patchConfig = ref.read(patchClashConfigProvider);
      final network = ref.read(networkSettingProvider);
      final vpn = ref.read(vpnSettingProvider);
      final platformVersion = Platform.operatingSystemVersion;
      final collection = <String, Object?>{};
      List<String> platformLogs;
      try {
        platformLogs = await controller.getPlatformDiagnosticLogs();
        collection['collection.platform'] = platformLogs.isEmpty
            ? 'empty'
            : 'ok';
      } catch (error) {
        collection['collection.platform'] = 'unavailable:${error.runtimeType}';
        platformLogs = [
          'platform diagnostics unavailable: ${error.runtimeType}',
        ];
      }
      Map<String, Object?> clientDiagnostics = const {};
      try {
        clientDiagnostics = parseClientRuntimeDiagnostics(
          await controller.clientDiagnostics(),
        );
        collection['collection.runtime'] = clientDiagnostics.isEmpty
            ? 'empty'
            : 'ok';
      } catch (error) {
        collection['collection.runtime'] = 'unavailable:${error.runtimeType}';
      }
      List<TrackerInfo> trackers = const [];
      try {
        trackers = await controller.getConnections();
        collection['collection.connections'] = 'ok';
      } catch (error) {
        collection['collection.connections'] =
            'unavailable:${error.runtimeType}';
      }
      if (!mounted) return;
      final groups = ref.read(groupsProvider);
      final tunInterfaceEstablished =
          platformLogs.any(
            (line) => RegExp(r'^desktop\.tunUp=[1-9][0-9]*$').hasMatch(line),
          ) ||
          platformLogs.any((line) => line.contains('interface established'));
      final selectedMap = ref.read(selectedMapProvider);
      final managedGroup = groups.getGroup('HARBORPROXY-SERVER');
      final selectedServer =
          selectedMap['HARBORPROXY-SERVER'] ?? managedGroup?.now ?? '';
      final selectedGroup = groups.getGroup(selectedServer);
      final selectionMode = selectedServer.isEmpty
          ? 'unset'
          : switch (selectedGroup?.type) {
              GroupType.URLTest ||
              GroupType.Fallback ||
              GroupType.LoadBalance => 'automatic',
              _ => 'manual',
            };
      final probes = <String, Object?>{};
      if (ref.read(coreStatusProvider) == CoreStatus.connected) {
        final results = await Future.wait<Delay?>([
          controller
              .getDelay('https://www.baidu.com/favicon.ico', 'DIRECT')
              .catchError((_) => const Delay(name: '', url: '', value: -1)),
          controller
              .getDelay('https://www.gstatic.com/generate_204', 'DIRECT')
              .catchError((_) => const Delay(name: '', url: '', value: -1)),
          controller
              .getDelay(
                'https://www.gstatic.com/generate_204',
                'HARBORPROXY-SERVER',
              )
              .catchError((_) => const Delay(name: '', url: '', value: -1)),
        ]);
        probes
          ..addAll(diagnosticProbeResult('mainlandDirect', results[0]))
          ..addAll(diagnosticProbeResult('overseasDirect', results[1]))
          ..addAll(diagnosticProbeResult('selectedProxy', results[2]));
      } else {
        probes
          ..addAll(diagnosticProbeResult('mainlandDirect', null))
          ..addAll(diagnosticProbeResult('overseasDirect', null))
          ..addAll(diagnosticProbeResult('selectedProxy', null));
      }
      if (!mounted) return;
      final currentLogs = ref.read(logsProvider).list;
      final recentRequests = ref.read(requestsProvider).list;
      final packageInfo = globalState.packageInfo;
      final report = buildDiagnosticReport(
        applicationName: appName,
        status: {
          'generatedAt': DateTime.now().toIso8601String(),
          'app.version': packageInfo.version,
          'app.build': packageInfo.buildNumber,
          'platform.os': SupportPlatform.currentPlatform.name,
          'platform.version': platformVersion,
          'platform.runtime': Platform.version,
          'core.status': ref.read(coreStatusProvider).name,
          'health.phase': ref.read(clientHealthProvider).phase.name,
          'health.scope': diagnosticHealthScope,
          'health.checkedAt':
              ref.read(clientHealthProvider).checkedAt?.toIso8601String() ??
              'none',
          'health.latencyMs': ref.read(clientHealthProvider).latencyMs,
          'selection.lastOutcome': ref
              .read(proxiesActionProvider.notifier)
              .lastSelectionOutcome,
          'selection.lastAt':
              ref
                  .read(proxiesActionProvider.notifier)
                  .lastSelectionAt
                  ?.toIso8601String() ??
              'none',
          'routing.applyPhase': ref.read(privateRouteStatusProvider).phase.name,
          'routing.appliedMode':
              ref
                  .read(privateRouteStatusProvider)
                  .applied
                  ?.managedRouting
                  ?.mode
                  .wireValue ??
              'unknown',
          'routing.recoverySaved': ref
              .read(privateRouteStatusProvider)
              .recoverySaved,
          'core.runtimeSeconds': ref.read(runTimeProvider),
          'core.binarySha256': globalState.coreSHA256.isEmpty
              ? 'unknown'
              : globalState.coreSHA256.safeSubstring(0, 12),
          'config.mode': patchConfig.mode.name,
          'config.routeMode': network.routeMode.name,
          'config.managedRouteMode': network.managedRouteMode.wireValue,
          'config.stack': effectiveClientVpnStackName(
            configured: patchConfig.tun.stack,
            privateClientMode: kPrivateClientMode,
            isWindows: system.isWindows,
            isAndroid: system.isAndroid,
            isMacOS: system.isMacOS,
          ),
          if (system.isAndroid) ...{
            'config.dnsHijacking': vpn.dnsHijacking,
            'config.allowBypass': vpn.allowBypass,
            'config.accessControlEnabled': vpn.accessControlProps.enable,
            'config.accessControlMode': vpn.accessControlProps.mode.name,
            'config.accessControlCount':
                vpn.accessControlProps.currentList.length,
          },
          'config.systemProxyConfigured': system.isAndroid
              ? vpn.systemProxy
              : network.systemProxy,
          'config.systemProxyEffective': system.isAndroid
              ? effectiveClientVpnSystemProxy(
                  configured: vpn.systemProxy,
                  privateClientMode: true,
                  isAndroid: true,
                )
              : false,
          'config.tunRequested': system.isAndroid
              ? kPrivateClientMode || vpn.enable
              : patchConfig.tun.enable,
          'config.tunActive': diagnosticTunActive(
            isAndroid: system.isAndroid,
            runtimeTunEnabled:
                patchConfig.tun.enable &&
                ref.read(authorizedTunEnableProvider) ==
                    TunAuthorizationState.authorized,
            platformTunEstablished: tunInterfaceEstablished,
          ),
          'config.ipv6Configured': system.isAndroid
              ? vpn.ipv6
              : patchConfig.ipv6,
          'config.ipv6Effective': effectiveClientIpv6(
            configured: system.isAndroid ? vpn.ipv6 : patchConfig.ipv6,
            privateClientMode: true,
            isAndroid: system.isAndroid,
          ),
          'config.coreIpv6Effective': effectiveClientCoreIpv6(
            configured: patchConfig.ipv6,
            privateClientMode: true,
            isAndroid: system.isAndroid,
            managedRouteMode: network.managedRouteMode,
          ),
          'config.groups': groups.length,
          'selection.mode': selectionMode,
          'platform.tunInterfaceEstablished': tunInterfaceEstablished,
          'platform.tunCoreStarted':
              tunInterfaceEstablished ||
              platformLogs.any((line) => line.contains('TUN core started')),
          ...clientDiagnostics,
          ...buildConnectionSummary(trackers),
          ...buildDiagnosticLogSummary(currentLogs),
          ...collection,
          'probe.scope': 'core-outbound only (not browser or VPN path)',
          ...probes,
        },
        logs: currentLogs,
        platformLogs: platformLogs,
        visitedDestinations: collectVisitedDestinations([
          ...recentRequests,
          ...trackers,
        ]),
        routeSamples: collectDiagnosticRouteSamples([
          ...recentRequests,
          ...trackers,
        ]),
      );
      await Clipboard.setData(ClipboardData(text: report));
      if (mounted) {
        context.showSnackBar(context.appLocalizations.copySuccess);
      }
    } catch (_) {
      if (mounted) {
        context.showSnackBar(
          context.appLocalizations.clientCopyDiagnosticsFailed,
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = context.appLocalizations;
    return ListItem(
      leading: const Icon(Icons.copy_outlined),
      title: Text(text.clientCopyDiagnostics),
      subtitle: Text(text.clientCopyDiagnosticsHint),
      trailing: _busy
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : null,
      onTap: _busy ? null : _copyDiagnosticLogs,
    );
  }
}
