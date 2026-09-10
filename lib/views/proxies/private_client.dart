import 'dart:math';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
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
    ManagedRouteMode.directAllLegacy => context.appLocalizations.direct,
    ManagedRouteMode.bypassMainland =>
      context.appLocalizations.clientSmartOutbound,
    ManagedRouteMode.bypassOverseas =>
      context.appLocalizations.clientSmartReturn,
    _ => context.appLocalizations.clientAllProxy,
  };

  String description(BuildContext context) => switch (this) {
    ManagedRouteMode.directAllLegacy => context.appLocalizations.routeDirect,
    ManagedRouteMode.bypassMainland =>
      context.appLocalizations.clientOutboundHint,
    ManagedRouteMode.bypassOverseas =>
      context.appLocalizations.clientReturnHint,
    _ => context.appLocalizations.clientAllProxyHint,
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

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final group = findPrivateClientPrimaryGroup(ref.watch(groupsProvider));
    final style = ref.watch(proxiesStyleSettingProvider);
    return CommonScaffold(
      managedRoot: true,
      title: context.appLocalizations.clientLines,
      body: group == null
          ? Center(child: Text(context.appLocalizations.routeUnavailable))
          : LayoutBuilder(
              builder: (_, constraints) => ProxyGroupView(
                group: group,
                columns: utils.getProxiesColumns(
                  max(constraints.maxWidth - 32, 0),
                  style.layout,
                ),
                cardType: style.cardType,
              ),
            ),
    );
  }
}

class PrivateRoutingModePicker extends ConsumerStatefulWidget {
  const PrivateRoutingModePicker({super.key});

  @override
  ConsumerState<PrivateRoutingModePicker> createState() =>
      _PrivateRoutingModePickerState();
}

class _PrivateRoutingModePickerState
    extends ConsumerState<PrivateRoutingModePicker> {
  bool _busy = false;

  Future<void> _select(ManagedRouteMode mode) async {
    final previous = ref.read(networkSettingProvider);
    if (_busy || previous.managedRouteMode == mode) return;
    setState(() => _busy = true);
    ref
        .read(networkSettingProvider.notifier)
        .update((state) => state.copyWith(managedRouteMode: mode));
    try {
      final message = await ref
          .read(setupActionProvider.notifier)
          .setupPrivateClientProfile();
      if (message.isNotEmpty ||
          ref.read(privateRouteStatusProvider).phase !=
              PrivateRouteApplyPhase.applied) {
        throw StateError('route not applied');
      }
    } catch (_) {
      ref
          .read(networkSettingProvider.notifier)
          .update(
            (state) =>
                state.copyWith(managedRouteMode: previous.managedRouteMode),
          );
      if (mounted) {
        context.showSnackBar(context.appLocalizations.routeApplyFailed);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final mode = ref.watch(networkSettingProvider).managedRouteMode;
    final applying =
        ref.watch(privateRouteStatusProvider).phase ==
        PrivateRouteApplyPhase.applying;
    return RadioGroup<ManagedRouteMode>(
      groupValue: mode == ManagedRouteMode.directAllLegacy ? null : mode,
      onChanged: (value) {
        if (value != null && !_busy && !applying) _select(value);
      },
      child: LayoutBuilder(
        builder: (context, constraints) {
          final horizontal =
              constraints.maxWidth /
                  MediaQuery.textScalerOf(context).scale(1) >=
              740;
          final options = [
            for (final option in const [
              ManagedRouteMode.bypassMainland,
              ManagedRouteMode.bypassOverseas,
              ManagedRouteMode.global,
            ])
              Material(
                color: option == mode
                    ? context.colorScheme.secondaryContainer
                    : context.colorScheme.surface,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(4),
                  side: BorderSide(
                    color: option == mode
                        ? context.colorScheme.primary
                        : context.colorScheme.outlineVariant,
                  ),
                ),
                clipBehavior: Clip.antiAlias,
                child: RadioListTile<ManagedRouteMode>(
                  value: option,
                  enabled: !_busy && !applying,
                  selected: option == mode,
                  dense: true,
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: horizontal ? 12 : 4,
                  ),
                  title: Text(
                    option.label(context),
                    style: context.textTheme.titleSmall,
                  ),
                  subtitle: Text(
                    option.description(context),
                    style: context.textTheme.bodySmall?.copyWith(
                      color: context.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
          ];
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (mode == ManagedRouteMode.directAllLegacy)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    '${context.appLocalizations.clientTrafficMode} · ${context.appLocalizations.routeDirect}',
                  ),
                ),
              if (horizontal)
                IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final (index, option) in options.indexed) ...[
                        if (index != 0) const SizedBox(width: 12),
                        Expanded(child: option),
                      ],
                    ],
                  ),
                )
              else
                for (final (index, option) in options.indexed) ...[
                  if (index != 0) const SizedBox(height: 8),
                  option,
                ],
            ],
          );
        },
      ),
    );
  }
}
