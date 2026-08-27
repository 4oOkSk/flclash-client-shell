import 'dart:io';
import 'dart:math';

import 'package:defer_pointer/defer_pointer.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/core.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';

import 'widgets/core_status_button.dart';
import 'widgets/start_button.dart';

typedef _IsEditWidgetBuilder = Widget Function(bool isEdit);

List<DashboardWidget> dashboardWidgetsFromGridItems(
  Iterable<GridItem> children,
) {
  final dashboardWidgets = <DashboardWidget>[];
  for (final child in children) {
    for (final dashboardWidget in DashboardWidget.values) {
      if (dashboardWidget.widget == child) {
        dashboardWidgets.add(dashboardWidget);
        break;
      }
    }
  }
  return dashboardWidgets;
}

const _maxCrossAxisCount = 16;
const _maxGridWidth = 280.0 * _maxCrossAxisCount / 4;

class DashboardView extends ConsumerStatefulWidget {
  const DashboardView({super.key});

  @override
  ConsumerState<DashboardView> createState() => _DashboardViewState();
}

class _DashboardViewState extends ConsumerState<DashboardView> {
  final key = GlobalKey<SuperGridState>();
  final _isEditNotifier = ValueNotifier<bool>(false);
  final _addedWidgetsNotifier = ValueNotifier<List<GridItem>>([]);

  @override
  void dispose() {
    _isEditNotifier.dispose();
    _addedWidgetsNotifier.dispose();
    super.dispose();
  }

  Widget _buildIsEdit(_IsEditWidgetBuilder builder) {
    return ValueListenableBuilder(
      valueListenable: _isEditNotifier,
      builder: (_, isEdit, _) {
        return builder(isEdit);
      },
    );
  }

  Future<void> _copyDiagnosticLogs() async {
    final patchConfig = ref.read(patchClashConfigProvider);
    final network = ref.read(networkSettingProvider);
    final vpn = ref.read(vpnSettingProvider);
    final platformVersion = Platform.operatingSystemVersion;
    List<String> platformLogs;
    try {
      platformLogs = await coreController.getPlatformDiagnosticLogs();
    } catch (error) {
      platformLogs = ['platform diagnostics unavailable: ${error.runtimeType}'];
    }
    Map<String, Object?> clientDiagnostics = const {};
    try {
      clientDiagnostics = parseClientRuntimeDiagnostics(
        await coreController.clientDiagnostics(),
      );
    } catch (_) {}
    List<TrackerInfo> trackers = const [];
    try {
      trackers = await coreController.getConnections();
    } catch (_) {}
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
        coreController
            .getDelay('https://www.baidu.com/favicon.ico', 'DIRECT')
            .catchError((_) => const Delay(name: '', url: '', value: -1)),
        coreController
            .getDelay('https://www.gstatic.com/generate_204', 'DIRECT')
            .catchError((_) => const Delay(name: '', url: '', value: -1)),
        coreController
            .getDelay('https://www.gstatic.com/generate_204', 'HARBORPROXY-SERVER')
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
        'platform.description': Platform.operatingSystemVersion,
        'platform.runtime': Platform.version,
        'core.status': ref.read(coreStatusProvider).name,
        'core.runtimeSeconds': ref.read(runTimeProvider),
        'core.binarySha256': globalState.coreSHA256.isEmpty
            ? 'unknown'
            : globalState.coreSHA256.safeSubstring(0, 12),
        'config.mode': patchConfig.mode.name,
        'config.routeMode': network.routeMode.name,
        'config.managedRouteMode': network.managedRouteMode.wireValue,
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
            ? vpn.enable
            : patchConfig.tun.enable,
        'config.tunActive': diagnosticTunActive(
          isAndroid: system.isAndroid,
          runtimeTunEnabled:
              patchConfig.tun.enable &&
              ref.read(authorizedTunEnableProvider) ==
                  TunAuthorizationState.authorized,
          platformTunEstablished: tunInterfaceEstablished,
        ),
        'config.ipv6Configured': system.isAndroid ? vpn.ipv6 : patchConfig.ipv6,
        'config.ipv6Effective': effectiveClientIpv6(
          configured: system.isAndroid ? vpn.ipv6 : patchConfig.ipv6,
          privateClientMode: true,
          isAndroid: system.isAndroid,
        ),
        'config.coreIpv6Effective': effectiveClientCoreIpv6(
          configured: patchConfig.ipv6,
          privateClientMode: true,
          isAndroid: system.isAndroid,
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
  }

  List<Widget> _buildActions(bool isEdit) {
    return [
      if (!isEdit && kPrivateClientMode)
        IconButton(
          tooltip: context.appLocalizations.exportLogs,
          onPressed: _copyDiagnosticLogs,
          icon: const Icon(Icons.bug_report_outlined),
        ),
      if (!isEdit && coreLib == null) const CoreStatusButton(),
      if (isEdit)
        ValueListenableBuilder(
          valueListenable: _addedWidgetsNotifier,
          builder: (_, addedChildren, child) {
            if (addedChildren.isEmpty) {
              return Container();
            }
            return child!;
          },
          child: IconButton(
            onPressed: () {
              _showAddWidgetsModal();
            },
            icon: const Icon(Icons.add_circle),
          ),
        ),
      FadeRotationScaleBox(
        child: isEdit
            ? IconButton(
                key: const ValueKey(true),
                icon: const Icon(Icons.save, key: ValueKey('save-icon')),
                onPressed: _handleSaveAndExit,
              )
            : IconButton(
                key: const ValueKey(false),
                icon: const Icon(Icons.edit, key: ValueKey('edit-icon')),
                onPressed: _handleEnterEdit,
              ),
      ),
    ];
  }

  void _showAddWidgetsModal() {
    showSheet(
      builder: (_) {
        return ValueListenableBuilder(
          valueListenable: _addedWidgetsNotifier,
          builder: (_, value, _) {
            return AdaptiveSheetScaffold(
              body: _AddDashboardWidgetModal(
                items: value,
                onAdd: (gridItem) {
                  key.currentState?.handleAdd(gridItem);
                },
              ),
              title: context.appLocalizations.add,
            );
          },
        );
      },
      context: context,
    );
  }

  void _handleEnterEdit() {
    if (_isEditNotifier.value) {
      return;
    }
    _isEditNotifier.value = true;
  }

  void _handleExitEdit() {
    if (!_isEditNotifier.value) {
      return;
    }
    final dashboardWidgets = _getDashboardWidgets(key.currentState);
    if (dashboardWidgets != null) {
      _saveDashboardWidgets(dashboardWidgets);
    }
    _isEditNotifier.value = false;
  }

  Future<void> _handleSaveAndExit() async {
    if (!_isEditNotifier.value) {
      return;
    }
    await _handleSave();
    if (mounted) {
      _isEditNotifier.value = false;
    }
  }

  Future<void> _handleSave() async {
    final currentState = key.currentState;
    if (currentState == null) {
      return;
    }
    if (!mounted || currentState.snapshotChildren.isEmpty) {
      return;
    }
    final transformCompleted = await currentState.isTransformCompleter;
    if (!transformCompleted ||
        !mounted ||
        !currentState.mounted ||
        !identical(key.currentState, currentState)) {
      return;
    }
    final dashboardWidgets = _getDashboardWidgets(currentState);
    if (dashboardWidgets == null) {
      return;
    }
    _saveDashboardWidgets(dashboardWidgets);
  }

  List<DashboardWidget>? _getDashboardWidgets(SuperGridState? currentState) {
    if (currentState == null) {
      return null;
    }
    final children = currentState.snapshotChildren;
    if (children.isEmpty) {
      return null;
    }
    return children.map(DashboardWidget.getDashboardWidget).toList();
  }

  void _saveDashboardWidgets(List<DashboardWidget> dashboardWidgets) {
    ref
        .read(appSettingProvider.notifier)
        .update((state) => state.copyWith(dashboardWidgets: dashboardWidgets));
  }

  @override
  Widget build(BuildContext context) {
    final dashboardState = ref.watch(dashboardStateProvider);
    final spacing = 14.mAp;
    final children = [
      ...dashboardState.dashboardWidgets
          .where(
            (item) => item.platforms.contains(SupportPlatform.currentPlatform),
          )
          .map((item) => item.widget),
    ];
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _addedWidgetsNotifier.value = DashboardWidget.values
          .where(
            (item) =>
                !children.contains(item.widget) &&
                (kPrivateClientMode
                    ? !privateClientHiddenDashboardWidgets.contains(item)
                    : !privateClientOnlyDashboardWidgets.contains(item)) &&
                item.platforms.contains(SupportPlatform.currentPlatform),
          )
          .map((item) => item.widget)
          .toList();
    });
    return _buildIsEdit(
      (isEdit) => CommonScaffold(
        title: context.appLocalizations.dashboard,
        actions: _buildActions(isEdit),
        floatingActionButton: const StartButton(),
        body: Align(
          alignment: Alignment.topCenter,
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16).copyWith(bottom: 88),
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: _maxGridWidth),
                child: LayoutBuilder(
                  builder: (_, constraints) {
                    final columns = min(
                      max(4 * ((constraints.maxWidth / 280).ceil()), 8),
                      _maxCrossAxisCount,
                    );
                    return isEdit
                        ? BackLayerScope(
                            onBack: _handleExitEdit,
                            child: SuperGrid(
                              key: key,
                              crossAxisCount: columns,
                              crossAxisSpacing: spacing,
                              mainAxisSpacing: spacing,
                              children: children,
                              onUpdate: () {
                                _handleSave();
                              },
                            ),
                          )
                        : Grid(
                            crossAxisCount: columns,
                            crossAxisSpacing: spacing,
                            mainAxisSpacing: spacing,
                            children: children,
                          );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AddDashboardWidgetModal extends StatelessWidget {
  final List<GridItem> items;
  final Function(GridItem item) onAdd;

  const _AddDashboardWidgetModal({required this.items, required this.onAdd});

  @override
  Widget build(BuildContext context) {
    return DeferredPointerHandler(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Grid(
          crossAxisCount: 8,
          crossAxisSpacing: 16,
          mainAxisSpacing: 16,
          children: items
              .map(
                (item) => item.wrap(
                  builder: (child) {
                    return _AddedContainer(
                      onAdd: () {
                        onAdd(item);
                      },
                      child: child,
                    );
                  },
                ),
              )
              .toList(),
        ),
      ),
    );
  }
}

class _AddedContainer extends StatefulWidget {
  final Widget child;
  final VoidCallback onAdd;

  const _AddedContainer({required this.child, required this.onAdd});

  @override
  State<_AddedContainer> createState() => _AddedContainerState();
}

class _AddedContainerState extends State<_AddedContainer> {
  @override
  void initState() {
    super.initState();
  }

  @override
  void didUpdateWidget(_AddedContainer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.child != widget.child) {}
  }

  Future<void> _handleAdd() async {
    widget.onAdd();
  }

  @override
  void dispose() {
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        ActivateBox(child: widget.child),
        Positioned(
          top: -8,
          right: -8,
          child: DeferPointer(
            child: SizedBox(
              width: 24,
              height: 24,
              child: IconButton.filled(
                iconSize: 20,
                padding: const EdgeInsets.all(2),
                onPressed: _handleAdd,
                icon: const Icon(Icons.add),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
