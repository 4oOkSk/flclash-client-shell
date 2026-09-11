import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/providers/client_health.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../proxies/private_client.dart';
import 'widgets/private_client_account.dart';

class PrivateHomeView extends ConsumerStatefulWidget {
  const PrivateHomeView({super.key});

  @override
  ConsumerState<PrivateHomeView> createState() => _PrivateHomeViewState();
}

class _PrivateHomeViewState extends ConsumerState<PrivateHomeView> {
  bool _busy = false;

  Future<void> _toggle() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(setupActionProvider.notifier)
          .setRunning(!ref.read(isStartProvider));
    } catch (_) {
      if (mounted) {
        context.showSnackBar(context.appLocalizations.routeUnavailable);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _navigate(PageLabel page) =>
      ref.read(currentPageLabelProvider.notifier).toPage(page);

  @override
  Widget build(BuildContext context) {
    final text = context.appLocalizations;
    final running = ref.watch(isStartProvider);
    final health = ref.watch(clientHealthProvider);
    final group = findPrivateClientPrimaryGroup(ref.watch(groupsProvider));
    final selected = group == null
        ? null
        : ref.watch(selectedProxyNameProvider(group.name));
    final routeState = ref.watch(privateRouteStatusProvider);
    final desiredMode = ref.watch(networkSettingProvider).managedRouteMode;
    final mode = routeState.phase == PrivateRouteApplyPhase.restored
        ? routeState.applied?.managedRouting?.mode ?? desiredMode
        : desiredMode;
    return CommonScaffold(
      managedRoot: true,
      title: text.clientHome,
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1040),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Card(
                margin: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            running
                                ? Icons.verified_user_outlined
                                : Icons.shield_outlined,
                            color: context.colorScheme.primary,
                            size: 32,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              _busy
                                  ? text.loading
                                  : running
                                  ? health.phase == ClientHealthPhase.offline
                                        ? text.clientNetworkOffline
                                        : text.clientTunnelActive
                                  : text.disconnected,
                              style: context.textTheme.headlineSmall,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      if (running) ...[
                        Semantics(
                          liveRegion: true,
                          child: Text(switch (health.phase) {
                            ClientHealthPhase.offline =>
                              text.clientNetworkOfflineHint,
                            ClientHealthPhase.reachable =>
                              text.clientServerReachable,
                            ClientHealthPhase.unavailable =>
                              text.clientServerUnreachable,
                            ClientHealthPhase.paused => text.clientHealthPaused,
                            _ => text.clientHealthChecking,
                          }),
                        ),
                        if (health.phase == ClientHealthPhase.unavailable)
                          TextButton.icon(
                            onPressed: ref
                                .read(clientHealthProvider.notifier)
                                .refresh,
                            icon: const Icon(Icons.refresh),
                            label: Text(text.retry),
                          ),
                        const SizedBox(height: 8),
                      ],
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(text.clientCurrentLine),
                        subtitle: Text(
                          privateClientSelectionLabel(
                            context,
                            ref.watch(groupsProvider),
                            group,
                            selected,
                          ),
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _navigate(PageLabel.proxies),
                      ),
                      const Divider(),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(mode.label(context)),
                        subtitle: Text(mode.description(context)),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _navigate(PageLabel.profiles),
                      ),
                      const SizedBox(height: 16),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          key: const ValueKey('client-connect'),
                          onPressed: _busy ? null : _toggle,
                          icon: _busy
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : Icon(
                                  running
                                      ? Icons.stop
                                      : Icons.power_settings_new,
                                ),
                          label: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            child: Text(
                              running
                                  ? text.clientDisconnect
                                  : text.clientConnect,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              const PrivateClientAccountCard(adaptive: true),
            ],
          ),
        ),
      ),
    );
  }
}
