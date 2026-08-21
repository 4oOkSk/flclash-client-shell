import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/features/features.dart';
import 'package:fl_clash/models/clash_config.dart';
import 'package:fl_clash/models/private_route.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class AddedRulesView extends ConsumerStatefulWidget {
  const AddedRulesView({super.key});

  @override
  ConsumerState<AddedRulesView> createState() => _AddedRulesViewState();
}

class _AddedRulesViewState extends ConsumerState<AddedRulesView> {
  final _key = utils.id;
  List<PrivateRuleProviderConfig> _privateRuleProviders = const [];

  @override
  void initState() {
    super.initState();
    if (kClientApiBase.isNotEmpty) {
      preferences.getPrivateRuleProviders().then((providers) {
        if (!mounted) return;
        setState(() {
          _privateRuleProviders = providers;
        });
      });
    }
  }

  void _applyPrivateRouteOverlay() {
    if (kClientApiBase.isEmpty) return;
    ref
        .read(setupActionProvider.notifier)
        .applyProfileDebounce(force: true, silence: true);
  }

  Future<void> _handleAddOrUpdate([Rule? rule]) async {
    final routeTargets = kClientApiBase.isEmpty
        ? const <String>[]
        : ref
              .read(groupsProvider)
              .where((item) => item.hidden != true)
              .map((item) => item.name)
              .toList();
    final res = await globalState.showCommonDialog<Rule>(
      child: AddOrEditRuleDialog(
        rule: rule,
        allowRuleSet: kClientApiBase.isNotEmpty,
        ruleTargets: routeTargets,
        ruleProviderNames: _privateRuleProviders
            .map((item) => item.name)
            .toList(),
      ),
    );
    if (res == null) {
      return;
    }
    ref.read(globalRulesProvider.notifier).put(res);
    _applyPrivateRouteOverlay();
  }

  void _handleSelected(int ruleId) {
    ref.read(itemsProvider(_key).notifier).update((selectedRules) {
      final newSelectedRules = Set<int>.from(selectedRules)
        ..addOrRemove(ruleId);
      return newSelectedRules;
    });
  }

  void _handleSelectAll() {
    final ids =
        ref.read(globalRulesProvider).value?.map((item) => item.id).toSet() ??
        {};
    ref.read(itemsProvider(_key).notifier).update((selected) {
      return selected.containsAll(ids) ? {} : ids;
    });
  }

  Future<void> _handleDelete() async {
    final appLocalizations = context.appLocalizations;
    final res = await globalState.showMessage(
      title: appLocalizations.tip,
      message: TextSpan(
        text: appLocalizations.deleteMultipTip(appLocalizations.rule),
      ),
    );
    if (res != true) {
      return;
    }
    final selectedRules = ref.read(itemsProvider(_key));
    ref.read(globalRulesProvider.notifier).delAll(selectedRules.cast<int>());
    ref.read(itemsProvider(_key).notifier).value = {};
    _applyPrivateRouteOverlay();
  }

  @override
  Widget build(BuildContext context) {
    final appLocalizations = context.appLocalizations;
    final title = kClientApiBase.isNotEmpty
        ? appLocalizations.localRules
        : appLocalizations.addedRules;
    final rules = ref.watch(globalRulesProvider).value ?? [];
    final selectedRules = ref.watch(itemsProvider(_key));
    return CommonPopScope(
      onPop: (_) {
        if (selectedRules.isNotEmpty) {
          ref.read(itemsProvider(_key).notifier).value = {};
          return false;
        }
        Navigator.of(context).pop();
        return false;
      },

      child: BaseScaffold(
        title: title,
        actions: [
          if (selectedRules.isNotEmpty) ...[
            CommonMinIconButtonTheme(
              child: IconButton.filledTonal(
                onPressed: _handleDelete,
                icon: const Icon(Icons.delete),
              ),
            ),
            const SizedBox(width: 2),
          ],
          CommonMinFilledButtonTheme(
            child: selectedRules.isNotEmpty
                ? FilledButton(
                    onPressed: _handleSelectAll,
                    child: Text(appLocalizations.selectAll),
                  )
                : FilledButton.tonal(
                    onPressed: () {
                      _handleAddOrUpdate();
                    },
                    child: Text(appLocalizations.add),
                  ),
          ),
          const SizedBox(width: 8),
        ],
        body: rules.isEmpty
            ? NullStatus(
                label: appLocalizations.nullTip(appLocalizations.rule),
                illustration: const RuleEmptyIllustration(),
              )
            : ReorderableList(
                padding: const EdgeInsets.symmetric(
                  vertical: 16,
                  horizontal: 16,
                ),
                itemBuilder: (context, index) {
                  final rule = rules[index];
                  final position = ItemPosition.get(index, rules.length);
                  return ReorderableDelayedDragStartListener(
                    key: ObjectKey(rule),
                    index: index,
                    child: ItemPositionProvider(
                      position: position,
                      child: RuleItem(
                        hasMatch: true,
                        isEditing: selectedRules.isNotEmpty,
                        rule: rule,
                        isSelected: selectedRules.contains(rule.id),
                        onSelected: () {
                          _handleSelected(rule.id);
                        },
                        onEdit: (Rule rule) {
                          _handleAddOrUpdate(rule);
                        },
                        checkInvalidHandler: kClientApiBase.isEmpty
                            ? null
                            : (rule) {
                                final validTargets = <String>{
                                  ...RuleTarget.values.map((item) => item.name),
                                  ...ref
                                      .read(groupsProvider)
                                      .where((item) => item.hidden != true)
                                      .map((item) => item.name),
                                  'MATCH',
                                };
                                final targetIsInvalid = !validTargets.contains(
                                  rule.ruleTarget,
                                );
                                final providerIsInvalid =
                                    rule.ruleAction == RuleAction.RULE_SET &&
                                    !_privateRuleProviders.any(
                                      (item) => item.name == rule.ruleProvider,
                                    );
                                return targetIsInvalid || providerIsInvalid;
                              },
                      ),
                    ),
                  );
                },
                itemExtent: ruleItemHeight,
                itemCount: rules.length,
                onReorderItem: (oldIndex, newIndex) {
                  ref
                      .read(globalRulesProvider.notifier)
                      .order(oldIndex, newIndex);
                  _applyPrivateRouteOverlay();
                },
              ),
      ),
    );
  }
}
