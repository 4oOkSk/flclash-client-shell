import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/core.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'tab.dart';

const privateClientManagedServerGroup = 'HARBORPROXY-SERVER';

const privateClientVisibleRoutingModes = <ManagedRouteMode>[
  ManagedRouteMode.global,
  ManagedRouteMode.bypassMainland,
  ManagedRouteMode.bypassOverseas,
];

extension ManagedRouteModeLabel on ManagedRouteMode {
  String label(BuildContext context) => switch (this) {
    ManagedRouteMode.global ||
    ManagedRouteMode.directAllLegacy => context.appLocalizations.global,
    ManagedRouteMode.bypassMainland => context.appLocalizations.bypassMainland,
    ManagedRouteMode.bypassOverseas => context.appLocalizations.bypassOverseas,
  };
}

Group? findPrivateClientPrimaryGroup(Iterable<Group> groups) {
  for (final group in groups) {
    if (group.hidden != true &&
        group.type == GroupType.Selector &&
        group.name == privateClientManagedServerGroup) {
      return group;
    }
  }
  return null;
}

class PrivateClientProxiesView extends ConsumerWidget {
  const PrivateClientProxiesView({super.key});

  Future<void> _updateRouting(WidgetRef ref, ManagedRouteMode mode) async {
    final previous = ref.read(networkSettingProvider);
    final next = previous.copyWith(managedRouteMode: mode);
    if (next == previous) return;
    ref.read(networkSettingProvider.notifier).update((_) => next);
    final applied = await globalState.loadingRun<bool>(() async {
      final message = await ref
          .read(setupActionProvider.notifier)
          .setupPrivateClientProfile();
      if (message.isNotEmpty) {
        throw StateError(message);
      }
      // Existing browser keep-alive/QUIC flows otherwise continue through
      // the old policy and make the routing toggle appear ineffective.
      await coreController.closeConnections();
      return true;
    }, tag: LoadingTag.proxies);
    if (applied == true) return;

    ref.read(networkSettingProvider.notifier).update((_) => previous);
    await globalState.safeRun(() async {
      final message = await ref
          .read(setupActionProvider.notifier)
          .setupPrivateClientProfile();
      if (message.isNotEmpty) {
        throw StateError(message);
      }
      await coreController.closeConnections();
    });
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final localizations = context.appLocalizations;
    final groups = ref.watch(groupsProvider);
    final primaryGroup = findPrivateClientPrimaryGroup(groups);
    final networkProps = ref.watch(networkSettingProvider);
    final proxyCardType = ref.watch(
      proxiesStyleSettingProvider.select((state) => state.cardType),
    );
    final columns = ref.watch(proxiesColumnsProvider);
    final isLoading = ref.watch(loadingProvider(LoadingTag.proxies));
    final selected = primaryGroup == null
        ? null
        : ref.watch(selectedProxyNameProvider(primaryGroup.name));
    // Older versions allowed both bypass toggles to be enabled. Preserve that
    // effective all-direct route, while projecting it to the same selected
    // "global" radio that the previous UI showed. Clicking that already
    // selected item remains a no-op; choosing another item exits legacy mode.
    final routingMode = networkProps.managedRouteMode.visibleMode;

    final serverCard = CommonCard(
      key: const ValueKey('private-client-server-card'),
      type: CommonCardType.filled,
      onPressed: primaryGroup == null
          ? null
          : () {
              BaseNavigator.push(
                context,
                CommonScaffold(
                  title: localizations.serverSelection,
                  body: ProxyGroupView(
                    group: primaryGroup,
                    columns: columns,
                    cardType: proxyCardType,
                  ),
                ),
              );
            },
      child: _PrivateProxyCard(
        icon: primaryGroup == null
            ? Icons.cloud_off_outlined
            : Icons.dns_outlined,
        title: localizations.serverSelection,
        value: primaryGroup == null
            ? localizations.noInfo
            : selected ?? primaryGroup.realNow,
        trailing: primaryGroup == null ? null : const Icon(Icons.chevron_right),
      ),
    );

    final routingCard = CommonCard(
      key: const ValueKey('private-client-routing-card'),
      type: CommonCardType.filled,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: RadioGroup<ManagedRouteMode>(
          groupValue: routingMode,
          onChanged: (value) {
            if (value != null && value != routingMode) {
              _updateRouting(ref, value);
            }
          },
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _PrivateProxyCardHeader(
                icon: Icons.route_outlined,
                title: localizations.routeMode,
              ),
              for (final mode in privateClientVisibleRoutingModes)
                ListItem<ManagedRouteMode>.radio(
                  minTileHeight: 42,
                  minVerticalPadding: 0,
                  title: Text(mode.label(context)),
                  delegate: RadioDelegate(
                    value: mode,
                    onTab: () {
                      if (mode != routingMode) {
                        _updateRouting(ref, mode);
                      }
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
    );

    return CommonScaffold(
      title: localizations.proxies,
      isLoading: isLoading,
      body: LayoutBuilder(
        builder: (context, constraints) {
          final cards = [serverCard, routingCard];
          final wide = constraints.maxWidth >= 760;
          return SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: wide
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (var index = 0; index < cards.length; index++) ...[
                        Expanded(child: cards[index]),
                        if (index != cards.length - 1)
                          const SizedBox(width: 16),
                      ],
                    ],
                  )
                : Column(
                    children: [
                      for (var index = 0; index < cards.length; index++) ...[
                        cards[index],
                        if (index != cards.length - 1)
                          const SizedBox(height: 16),
                      ],
                    ],
                  ),
          );
        },
      ),
    );
  }
}

class _PrivateProxyCardHeader extends StatelessWidget {
  const _PrivateProxyCardHeader({required this.icon, required this.title});

  final IconData icon;
  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
      child: Row(
        children: [
          Icon(icon, color: context.colorScheme.primary),
          const SizedBox(width: 10),
          Expanded(child: Text(title, style: context.textTheme.titleMedium)),
        ],
      ),
    );
  }
}

class _PrivateProxyCard extends StatelessWidget {
  const _PrivateProxyCard({
    required this.icon,
    required this.title,
    required this.value,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final String value;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: context.colorScheme.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Text(title, style: context.textTheme.titleMedium),
              ),
              ?trailing,
            ],
          ),
          const SizedBox(height: 24),
          Text(
            value,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: context.textTheme.titleLarge?.copyWith(
              color: context.colorScheme.primary,
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}
