import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'private_rule_providers.dart';
import 'rules.dart';
import 'scripts.dart';

class PrivateRoutingView extends ConsumerStatefulWidget {
  const PrivateRoutingView({super.key});

  @override
  ConsumerState<PrivateRoutingView> createState() => _PrivateRoutingViewState();
}

class _PrivateRoutingViewState extends ConsumerState<PrivateRoutingView> {
  int? _ruleProviderCount;
  int? _activeScriptId;

  @override
  void initState() {
    super.initState();
    _refreshLocalState();
  }

  Future<void> _refreshLocalState() async {
    final providersFuture = preferences.getPrivateRuleProviders();
    final scriptIdFuture = preferences.getPrivateRouteScriptId();
    final providers = await providersFuture;
    final scriptId = await scriptIdFuture;
    if (!mounted) return;
    setState(() {
      _ruleProviderCount = providers.length;
      _activeScriptId = scriptId;
    });
  }

  Future<void> _open(Widget child) async {
    await BaseNavigator.push(context, child);
    await _refreshLocalState();
  }

  @override
  Widget build(BuildContext context) {
    final appLocalizations = context.appLocalizations;
    final ruleCount = ref.watch(globalRulesProvider).value?.length;
    final scripts = ref.watch(scriptsProvider).value ?? const [];
    String? activeScriptLabel;
    for (final script in scripts) {
      if (script.id == _activeScriptId) {
        activeScriptLabel = script.label;
        break;
      }
    }
    final cards = [
      _RoutingCard(
        key: const ValueKey('private-routing-local-rules'),
        icon: Icons.rule_outlined,
        title: appLocalizations.localRules,
        description: appLocalizations.localRulesDesc,
        status: ruleCount == null
            ? appLocalizations.loading
            : appLocalizations.entriesCount(ruleCount),
        onPressed: () => _open(const AddedRulesView()),
      ),
      _RoutingCard(
        key: const ValueKey('private-routing-rule-providers'),
        icon: Icons.rule_folder_outlined,
        title: appLocalizations.privateRuleProviders,
        description: appLocalizations.localRuleProvidersDesc,
        status: _ruleProviderCount == null
            ? appLocalizations.loading
            : appLocalizations.entriesCount(_ruleProviderCount!),
        onPressed: () => _open(const PrivateRuleProvidersView()),
      ),
      _RoutingCard(
        key: const ValueKey('private-routing-script'),
        icon: Icons.code_outlined,
        title: appLocalizations.routeScript,
        description: appLocalizations.routeScriptDesc,
        status:
            activeScriptLabel ?? appLocalizations.privateRouteScriptDisabled,
        onPressed: () => _open(const ScriptsView()),
      ),
    ];
    return CommonScaffold(
      title: appLocalizations.routing,
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: [
          _RoutingPrivacyNotice(message: appLocalizations.routingPrivacyDesc),
          const SizedBox(height: 16),
          LayoutBuilder(
            builder: (context, constraints) {
              final useColumns = constraints.maxWidth >= 760;
              if (!useColumns) {
                return Column(
                  children: cards
                      .map(
                        (card) => Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: card,
                        ),
                      )
                      .toList(),
                );
              }
              return IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: cards
                      .map(
                        (card) => Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                            child: card,
                          ),
                        ),
                      )
                      .toList(),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _RoutingPrivacyNotice extends StatelessWidget {
  const _RoutingPrivacyNotice({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: context.colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.lock_outline,
              color: context.colorScheme.onSecondaryContainer,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                message,
                style: context.textTheme.bodyMedium?.copyWith(
                  color: context.colorScheme.onSecondaryContainer,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RoutingCard extends StatelessWidget {
  const _RoutingCard({
    super.key,
    required this.icon,
    required this.title,
    required this.description,
    required this.status,
    required this.onPressed,
  });

  final IconData icon;
  final String title;
  final String description;
  final String status;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return CommonCard(
      type: CommonCardType.filled,
      onPressed: onPressed,
      child: SizedBox(
        height: 164,
        child: Padding(
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
                  const Icon(Icons.chevron_right),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                description,
                style: context.textTheme.bodyMedium?.copyWith(
                  color: context.colorScheme.onSurfaceVariant,
                ),
              ),
              const Spacer(),
              const SizedBox(height: 12),
              Text(
                status,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.textTheme.labelLarge?.copyWith(
                  color: context.colorScheme.primary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
