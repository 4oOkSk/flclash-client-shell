import 'dart:convert';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/common/private_route_input.dart';
import 'package:fl_clash/core/core.dart';
import 'package:fl_clash/database/database.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../proxies/private_client.dart';
import 'private_route_editor.dart';
import 'private_rule_providers.dart';
import 'rules.dart';
import 'scripts.dart';

class PrivateRoutingView extends ConsumerStatefulWidget {
  final Future<String> Function(String)? preview;

  const PrivateRoutingView({super.key, this.preview});

  @override
  ConsumerState<PrivateRoutingView> createState() => _PrivateRoutingViewState();
}

class _PrivateRoutingViewState extends ConsumerState<PrivateRoutingView> {
  final _destination = TextEditingController();
  bool _busy = false;
  String? _preview;
  int _previewRevision = 0;

  void _invalidatePreview() {
    _previewRevision++;
    if (mounted) setState(() => _preview = null);
  }

  @override
  void dispose() {
    _destination.dispose();
    super.dispose();
  }

  Future<void> _apply() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _preview = null;
    });
    try {
      final message = await ref
          .read(setupActionProvider.notifier)
          .setupPrivateClientProfile();
      if (message.isNotEmpty && mounted) {
        context.showSnackBar(context.appLocalizations.routeApplyFailed);
      }
    } catch (_) {
      if (mounted) {
        context.showSnackBar(context.appLocalizations.routeApplyFailed);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _edit([Rule? rule]) async {
    if (rule != null && !isSimplePrivateRoute(rule)) {
      await BaseNavigator.push(context, const AddedRulesView());
      return;
    }
    final result = await showDialog<Rule>(
      context: context,
      builder: (_) => PrivateRouteEditor(rule: rule),
    );
    if (result == null || !mounted) return;
    try {
      final current = await database.rulesDao.queryGlobalAddedRules().get();
      final ordered = result.autoOrder(
        result,
        null,
        current.firstOrNull?.order,
      );
      await database.rulesDao.putGlobalRule(ordered);
      ref.read(globalRulesProvider.notifier).value = await database.rulesDao
          .queryGlobalAddedRules()
          .get();
      await _apply();
    } catch (_) {
      if (mounted) {
        context.showSnackBar(context.appLocalizations.routeApplyFailed);
      }
    }
  }

  Future<void> _delete(Rule rule) async {
    final accepted = await globalState.showMessage(
      title: context.appLocalizations.routeDeleteException,
      message: TextSpan(text: rule.realContent),
    );
    if (accepted != true || !mounted) return;
    try {
      await database.rulesDao.delRules([rule.id]);
      ref.read(globalRulesProvider.notifier).value = await database.rulesDao
          .queryGlobalAddedRules()
          .get();
      await _apply();
    } catch (_) {
      if (mounted) {
        context.showSnackBar(context.appLocalizations.routeApplyFailed);
      }
    }
  }

  Future<void> _check() async {
    if (_busy) return;
    final revision = ++_previewRevision;
    String destination;
    try {
      destination = normalizePrivateRouteDestination(_destination.text);
    } catch (_) {
      setState(
        () => _preview = context.appLocalizations.routeInvalidDestination,
      );
      return;
    }
    setState(() {
      _busy = true;
      _preview = null;
    });
    try {
      final response =
          jsonDecode(
                await (widget.preview ?? coreController.clientRoutePreview)(
                  destination,
                ),
              )
              as Map;
      if (!mounted || revision != _previewRevision) return;
      final text = context.appLocalizations;
      final action = switch (response['action']) {
        'direct' => text.routeDirect,
        'reject' => text.routeReject,
        _ => text.routeViaLine,
      };
      setState(() {
        _preview = switch (response['status']) {
          'matched' => text.routeCheckResult(
            action,
            response['rule-index'] as int,
          ),
          'needs-ip' => text.routeNeedsIp,
          'needs-context' => text.routeNeedsContext,
          'invalid' => text.routeInvalidDestination,
          _ => text.routeUnavailable,
        };
      });
    } catch (_) {
      if (mounted && revision == _previewRevision) {
        setState(() => _preview = context.appLocalizations.routeUnavailable);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reconnect() async {
    final accepted = await globalState.showMessage(
      title: context.appLocalizations.routeReconnect,
      message: TextSpan(text: context.appLocalizations.routeReconnectConfirm),
    );
    if (accepted != true || !mounted) return;
    try {
      await coreController.closeConnections();
    } catch (_) {
      if (mounted) {
        context.showSnackBar(context.appLocalizations.routeUnavailable);
      }
    }
  }

  String _targetLabel(Rule rule) => switch (rule.ruleTarget) {
    'DIRECT' => context.appLocalizations.routeDirect,
    'REJECT' => context.appLocalizations.routeReject,
    privateRouteCurrentLine => context.appLocalizations.routeViaLine,
    _ => context.appLocalizations.routeAdvancedRule,
  };

  Widget _buildExceptions(AsyncValue<List<Rule>> rules, bool applying) {
    final text = context.appLocalizations;
    return Card(
      key: const ValueKey('route-exceptions-panel'),
      margin: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        text.routeExceptions,
                        style: context.textTheme.titleMedium,
                      ),
                    ),
                    FilledButton.icon(
                      onPressed: applying ? null : () => _edit(),
                      icon: const Icon(Icons.add, size: 20),
                      label: Text(text.routeAddException),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  text.routeExceptionsHint,
                  style: context.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          rules.when(
            loading: () => const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (_, _) => Padding(
              padding: const EdgeInsets.all(16),
              child: Text(text.routeApplyFailed),
            ),
            data: (items) => items.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text(text.routeNoExceptions),
                  )
                : Column(
                    children: [
                      for (final (index, rule) in items.indexed) ...[
                        if (index != 0) const Divider(height: 1),
                        ListTile(
                          leading: Text('${index + 1}'),
                          title: Text(
                            rule.realContent ?? text.routeAdvancedRule,
                          ),
                          subtitle: Text(
                            '${_targetLabel(rule)} · ${isSimplePrivateRoute(rule) ? (rule.ruleAction.name == 'DOMAIN_SUFFIX' ? text.routeIncludeSubdomains : text.routeDestination) : text.routeAdvancedRule}',
                          ),
                          onTap: applying ? null : () => _edit(rule),
                          trailing: IconButton(
                            tooltip: text.delete,
                            onPressed: applying ? null : () => _delete(rule),
                            icon: const Icon(Icons.delete_outline),
                          ),
                        ),
                      ],
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildChecker(bool applying) {
    final text = context.appLocalizations;
    return Card(
      key: const ValueKey('route-check-panel'),
      margin: EdgeInsets.zero,
      child: Padding(
        key: const PageStorageKey('private-routing-checker'),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(text.routeCheck, style: context.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(text.routeCheckHint, style: context.textTheme.bodySmall),
            const SizedBox(height: 16),
            TextField(
              key: const ValueKey('route-preview-destination'),
              controller: _destination,
              onChanged: (_) => _invalidatePreview(),
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: text.routeDestination,
                hintText: 'example.com',
              ),
              onSubmitted: (_) => _check(),
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: applying ? null : _check,
              icon: const Icon(Icons.travel_explore, size: 20),
              label: Text(text.routeCheck),
            ),
            if (_preview != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    _preview!,
                    key: const ValueKey('route-preview-result'),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildApplyStatus(
    PrivateRouteApplyState status,
    String statusText,
    bool applying,
  ) {
    final text = context.appLocalizations;
    final warning =
        status.phase == PrivateRouteApplyPhase.failed ||
        status.phase == PrivateRouteApplyPhase.restored ||
        (status.phase == PrivateRouteApplyPhase.applied &&
            !status.recoverySaved);
    final message = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          warning
              ? Icons.warning_amber
              : status.phase == PrivateRouteApplyPhase.applied
              ? Icons.check_circle_outline
              : Icons.sync,
          color: warning
              ? context.colorScheme.error
              : context.colorScheme.primary,
          size: 22,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(statusText, style: context.textTheme.titleSmall),
              const SizedBox(height: 4),
              Text(
                text.routeNewConnections,
                style: context.textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ],
    );
    final actions = Wrap(
      alignment: WrapAlignment.end,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 4,
      children: [
        if (status.phase != PrivateRouteApplyPhase.applied || warning)
          TextButton.icon(
            onPressed: applying ? null : _apply,
            icon: const Icon(Icons.refresh, size: 20),
            label: Text(text.retry),
          ),
        PopupMenuButton<String>(
          enabled: !applying,
          tooltip: text.more,
          icon: const Icon(Icons.more_horiz),
          onSelected: (value) => value == 'apply' ? _apply() : _reconnect(),
          itemBuilder: (_) => [
            PopupMenuItem(value: 'apply', child: Text(text.routeSaveApply)),
            PopupMenuItem(value: 'reconnect', child: Text(text.routeReconnect)),
          ],
        ),
      ],
    );
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: warning
            ? context.colorScheme.errorContainer.withValues(alpha: 0.35)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(4),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) =>
            constraints.maxWidth / MediaQuery.textScalerOf(context).scale(1) >=
                660
            ? Row(
                children: [
                  Expanded(child: message),
                  const SizedBox(width: 16),
                  actions,
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  message,
                  const SizedBox(height: 8),
                  Align(alignment: Alignment.centerRight, child: actions),
                ],
              ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(privateRouteStatusProvider, (_, _) => _invalidatePreview());
    ref.listen(globalRulesProvider, (_, _) => _invalidatePreview());
    ref.listen(networkSettingProvider, (_, _) => _invalidatePreview());
    final text = context.appLocalizations;
    final rules = ref.watch(globalRulesProvider);
    final status = ref.watch(privateRouteStatusProvider);
    final applying = _busy || status.phase == PrivateRouteApplyPhase.applying;
    final statusText = switch (status.phase) {
      PrivateRouteApplyPhase.applied =>
        status.recoverySaved ? text.routeApplied : text.routeRecoveryNotSaved,
      PrivateRouteApplyPhase.applying => text.routeApplying,
      PrivateRouteApplyPhase.restored => text.routeRestored,
      PrivateRouteApplyPhase.failed => text.routeApplyFailed,
      PrivateRouteApplyPhase.idle => text.routeNotApplied,
    };
    return CommonScaffold(
      managedRoot: true,
      title: text.routing,
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1040),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final sideBySide =
                  (constraints.maxWidth - 32) /
                      MediaQuery.textScalerOf(context).scale(1) >=
                  860;
              return ListView(
                key: const PageStorageKey('private-routing'),
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                children: [
                  Text(
                    text.clientTrafficMode,
                    style: context.textTheme.titleMedium,
                  ),
                  const SizedBox(height: 12),
                  const PrivateRoutingModePicker(),
                  const SizedBox(height: 8),
                  _buildApplyStatus(status, statusText, applying),
                  const SizedBox(height: 12),
                  if (sideBySide)
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: _buildExceptions(rules, applying)),
                        const SizedBox(width: 16),
                        SizedBox(width: 304, child: _buildChecker(applying)),
                      ],
                    )
                  else ...[
                    _buildExceptions(rules, applying),
                    const SizedBox(height: 16),
                    _buildChecker(applying),
                  ],
                  const SizedBox(height: 20),
                  Card(
                    margin: EdgeInsets.zero,
                    child: ExpansionTile(
                      key: const PageStorageKey('private-routing-advanced'),
                      title: Text(text.routeAdvanced),
                      subtitle: Text(text.routeAdvancedHint),
                      children: [
                        ListTile(
                          title: Text(text.localRules),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => BaseNavigator.push(
                            context,
                            const AddedRulesView(),
                          ),
                        ),
                        ListTile(
                          title: Text(text.privateRuleProviders),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => BaseNavigator.push(
                            context,
                            const PrivateRuleProvidersView(),
                          ),
                        ),
                        ListTile(
                          title: Text(text.routeScript),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () =>
                              BaseNavigator.push(context, const ScriptsView()),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
