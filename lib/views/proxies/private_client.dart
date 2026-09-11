import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/core.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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

String privateClientServerAlias(Iterable<Proxy> proxies, String name) {
  final label = name.trim();
  final duplicates =
      proxies
          .map((proxy) => proxy.name)
          .where((other) => other.trim() == label)
          .toSet()
          .toList()
        ..sort();
  return duplicates.length > 1
      ? '$label · ${duplicates.indexOf(name) + 1}'
      : label;
}

String privateClientSelectionLabel(
  BuildContext context,
  List<Group> groups,
  Group? primary,
  String? selected,
) {
  final name = selected ?? primary?.now;
  if (name == null || name.isEmpty) return context.appLocalizations.noInfo;
  final automatic = groups.getGroup(name);
  if (automatic == null) {
    return privateClientServerAlias(primary?.all ?? [], name);
  }
  var leaf = automatic.now ?? '';
  final seen = <String>{name};
  while (leaf.isNotEmpty && seen.add(leaf) && seen.length <= 16) {
    final nested = groups.getGroup(leaf);
    if (nested == null) break;
    leaf = nested.now ?? '';
  }
  final label = context.appLocalizations.clientAutomatic;
  return leaf.isEmpty || groups.getGroup(leaf) != null
      ? label
      : '$label · ${privateClientServerAlias(primary?.all ?? [], leaf)}';
}

class PrivateClientProxiesView extends ConsumerStatefulWidget {
  const PrivateClientProxiesView({super.key});

  @override
  ConsumerState<PrivateClientProxiesView> createState() =>
      _PrivateClientProxiesViewState();
}

class _PrivateClientProxiesViewState
    extends ConsumerState<PrivateClientProxiesView> {
  final _testing = <String>{};
  final _delays = <String, int>{};
  final _testedAt = <String, DateTime>{};
  bool _selecting = false;
  bool _bulk = false;
  bool _availableFirst = false;
  String _query = '';

  Future<void> _test(Proxy proxy) async {
    if (_testing.contains(proxy.name)) return;
    setState(() => _testing.add(proxy.name));
    var delay = -1;
    try {
      delay =
          (await coreController.getDelay(
            ref.read(appSettingProvider).testUrl,
            proxy.name,
          )).value ??
          -1;
    } catch (_) {
    } finally {
      if (mounted) {
        setState(() {
          _testing.remove(proxy.name);
          _delays[proxy.name] = delay;
          _testedAt[proxy.name] = DateTime.now();
        });
      }
    }
  }

  Future<void> _testAll(List<Proxy> proxies) async {
    if (_bulk) return;
    setState(() => _bulk = true);
    try {
      for (final batch in proxies.batch(4)) {
        if (!mounted) break;
        await Future.wait(batch.map(_test));
      }
    } finally {
      if (mounted) setState(() => _bulk = false);
    }
  }

  Future<void> _select(Group group, Proxy proxy) async {
    if (_selecting) return;
    setState(() => _selecting = true);
    try {
      await ref
          .read(proxiesActionProvider.notifier)
          .changeProxy(groupName: group.name, proxyName: proxy.name);
      await ref.read(proxiesActionProvider.notifier).updateGroups();
    } catch (_) {
      if (mounted) {
        context.showSnackBar(context.appLocalizations.clientSelectionFailed);
      }
    } finally {
      if (mounted) setState(() => _selecting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = context.appLocalizations;
    final groups = ref.watch(groupsProvider);
    final group = findPrivateClientPrimaryGroup(groups);
    final selected = group == null
        ? null
        : ref.watch(selectedProxyNameProvider(group.name));
    final proxies =
        group?.all
            .where(
              (proxy) => privateClientSelectionLabel(
                context,
                groups,
                group,
                proxy.name,
              ).toLowerCase().contains(_query),
            )
            .toList() ??
        <Proxy>[];
    if (_availableFirst) {
      proxies.sort((first, second) {
        int score(Proxy proxy) =>
            (_delays[proxy.name] ?? -1) < 0 ? 1 << 30 : _delays[proxy.name]!;
        final comparison = score(first).compareTo(score(second));
        return comparison == 0 ? first.name.compareTo(second.name) : comparison;
      });
    }
    return CommonScaffold(
      managedRoot: true,
      title: text.clientLines,
      body: group == null
          ? Center(child: Text(text.routeUnavailable))
          : Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1040),
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    TextField(
                      decoration: InputDecoration(
                        labelText: text.search,
                        prefixIcon: const Icon(Icons.search),
                      ),
                      onChanged: (value) =>
                          setState(() => _query = value.trim().toLowerCase()),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 12,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        OutlinedButton.icon(
                          onPressed: _bulk || _testing.isNotEmpty
                              ? null
                              : () => _testAll(group.all),
                          icon: const Icon(Icons.speed),
                          label: Text(
                            _bulk ? text.clientTesting : text.clientTestServers,
                          ),
                        ),
                        FilterChip(
                          label: Text(text.clientAvailableFirst),
                          selected: _availableFirst,
                          onSelected: (value) =>
                              setState(() => _availableFirst = value),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(
                      text.clientTestHint,
                      style: context.textTheme.bodySmall,
                    ),
                    const SizedBox(height: 12),
                    Card(
                      margin: EdgeInsets.zero,
                      clipBehavior: Clip.antiAlias,
                      child: Column(
                        children: [
                          for (final (index, proxy) in proxies.indexed) ...[
                            if (index != 0) const Divider(height: 1),
                            ListTile(
                              selected: selected == proxy.name,
                              leading: Icon(
                                selected == proxy.name
                                    ? Icons.radio_button_checked
                                    : Icons.radio_button_off,
                              ),
                              title: Text(
                                privateClientSelectionLabel(
                                  context,
                                  groups,
                                  group,
                                  proxy.name,
                                ),
                              ),
                              onTap: _selecting || selected == proxy.name
                                  ? null
                                  : () => _select(group, proxy),
                              subtitle: Wrap(
                                spacing: 12,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  TextButton.icon(
                                    style: TextButton.styleFrom(
                                      minimumSize: const Size(48, 48),
                                    ),
                                    onPressed:
                                        _bulk || _testing.contains(proxy.name)
                                        ? null
                                        : () => _test(proxy),
                                    icon: const Icon(Icons.speed, size: 18),
                                    label: Text(
                                      _testing.contains(proxy.name)
                                          ? text.clientTesting
                                          : !_delays.containsKey(proxy.name)
                                          ? text.clientNotTested
                                          : _delays[proxy.name]! < 0
                                          ? text.clientTestUnavailable
                                          : '${_delays[proxy.name]} ms',
                                    ),
                                  ),
                                  if (_testedAt[proxy.name]
                                      case final DateTime checked)
                                    Text(
                                      '${text.clientTestedAt} ${TimeOfDay.fromDateTime(checked).format(context)}',
                                      style: context.textTheme.bodySmall,
                                    ),
                                ],
                              ),
                            ),
                          ],
                          if (proxies.isEmpty)
                            Padding(
                              padding: const EdgeInsets.all(24),
                              child: Text(text.noInfo),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
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
