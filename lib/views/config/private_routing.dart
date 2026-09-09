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
  const PrivateRoutingView({super.key});

  @override
  ConsumerState<PrivateRoutingView> createState() => _PrivateRoutingViewState();
}

class _PrivateRoutingViewState extends ConsumerState<PrivateRoutingView> {
  final _destination = TextEditingController();
  bool _busy = false;
  String? _preview;

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
    String destination;
    try {
      destination = normalizePrivateRouteDestination(_destination.text);
    } catch (_) {
      setState(
        () => _preview = context.appLocalizations.routeInvalidDestination,
      );
      return;
    }
    setState(() => _busy = true);
    try {
      final response =
          jsonDecode(await coreController.clientRoutePreview(destination))
              as Map;
      if (!mounted) return;
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
          'needs-ip' || 'needs-context' => text.routeNeedsContext,
          'invalid' => text.routeInvalidDestination,
          _ => text.routeUnavailable,
        };
      });
    } catch (_) {
      if (mounted)
        setState(() => _preview = context.appLocalizations.routeUnavailable);
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

  @override
  Widget build(BuildContext context) {
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
    final failed =
        status.phase == PrivateRouteApplyPhase.failed ||
        status.phase == PrivateRouteApplyPhase.restored;
    return CommonScaffold(
      title: text.routing,
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            children: [
              Card(
                margin: EdgeInsets.zero,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ListTile(
                      title: Text(
                        text.routeMode,
                        style: context.textTheme.titleMedium,
                      ),
                    ),
                    const PrivateRoutingModePicker(),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Card(
                margin: EdgeInsets.zero,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ListTile(
                      leading: Icon(
                        failed
                            ? Icons.warning_amber
                            : status.phase == PrivateRouteApplyPhase.applied
                            ? Icons.check_circle_outline
                            : Icons.sync,
                        color: failed
                            ? context.colorScheme.error
                            : context.colorScheme.primary,
                      ),
                      title: Text(statusText),
                      subtitle: Text(text.routeNewConnections),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          OutlinedButton(
                            onPressed: applying ? null : _apply,
                            child: Text(text.routeSaveApply),
                          ),
                          TextButton(
                            onPressed: applying ? null : _reconnect,
                            child: Text(text.routeReconnect),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
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
                    icon: const Icon(Icons.add),
                    label: Text(text.routeAddException),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                text.routeExceptionsHint,
                style: context.textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              Card(
                margin: EdgeInsets.zero,
                child: rules.when(
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
                                  onPressed: applying
                                      ? null
                                      : () => _delete(rule),
                                  icon: const Icon(Icons.delete_outline),
                                ),
                              ),
                            ],
                          ],
                        ),
                ),
              ),
              const SizedBox(height: 24),
              Text(text.routeCheck, style: context.textTheme.titleMedium),
              const SizedBox(height: 8),
              Text(text.routeCheckHint, style: context.textTheme.bodySmall),
              TextField(
                controller: _destination,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: text.routeDestination,
                  hintText: 'example.com',
                  suffixIcon: IconButton(
                    tooltip: text.routeCheck,
                    onPressed: applying ? null : _check,
                    icon: const Icon(Icons.search),
                  ),
                ),
                onSubmitted: (_) => _check(),
              ),
              if (_preview != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    _preview!,
                    key: const ValueKey('route-preview-result'),
                  ),
                ),
              const SizedBox(height: 24),
              Card(
                margin: EdgeInsets.zero,
                child: ExpansionTile(
                  title: Text(text.routeAdvanced),
                  subtitle: Text(text.routeAdvancedHint),
                  children: [
                    ListTile(
                      title: Text(text.localRules),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () =>
                          BaseNavigator.push(context, const AddedRulesView()),
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
          ),
        ),
      ),
    );
  }
}
