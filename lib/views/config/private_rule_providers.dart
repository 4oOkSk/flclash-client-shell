import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class PrivateRuleProvidersView extends ConsumerStatefulWidget {
  const PrivateRuleProvidersView({super.key});

  @override
  ConsumerState<PrivateRuleProvidersView> createState() =>
      _PrivateRuleProvidersViewState();
}

class _PrivateRuleProvidersViewState
    extends ConsumerState<PrivateRuleProvidersView> {
  List<PrivateRuleProviderConfig> _providers = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final providers = await preferences.getPrivateRuleProviders();
    if (!mounted) return;
    setState(() {
      _providers = providers;
      _loading = false;
    });
  }

  void _applyRouteOverlay() {
    ref
        .read(setupActionProvider.notifier)
        .applyProfileDebounce(force: true, silence: true);
  }

  Future<void> _saveProviders(List<PrivateRuleProviderConfig> providers) async {
    final saved = await preferences.savePrivateRuleProviders(providers);
    if (!saved) {
      throw StateError('failed to save local rule providers');
    }
    if (!mounted) return;
    setState(() {
      _providers = List.unmodifiable(providers);
    });
    _applyRouteOverlay();
  }

  Future<void> _handleAddOrEdit([PrivateRuleProviderConfig? provider]) async {
    final result = await globalState
        .showCommonDialog<PrivateRuleProviderConfig>(
          child: _PrivateRuleProviderDialog(
            provider: provider,
            existingNames: _providers
                .where((item) => item.name != provider?.name)
                .map((item) => item.name)
                .toSet(),
          ),
        );
    if (result == null) return;
    final next = List<PrivateRuleProviderConfig>.from(_providers);
    final index = provider == null
        ? -1
        : next.indexWhere((item) => item.name == provider.name);
    if (index == -1) {
      next.add(result);
    } else {
      next[index] = result;
    }
    if (provider != null && provider.name != result.name) {
      final rules = await ref.read(globalRulesProvider.future);
      if (!mounted) return;
      for (final rule in rules.where(
        (item) =>
            item.ruleAction == RuleAction.RULE_SET &&
            item.ruleProvider == provider.name,
      )) {
        ref
            .read(globalRulesProvider.notifier)
            .put(rule.copyWith(ruleProvider: result.name));
      }
    }
    await _saveProviders(next);
  }

  Future<void> _handleDelete(PrivateRuleProviderConfig provider) async {
    final appLocalizations = context.appLocalizations;
    final result = await globalState.showMessage(
      title: appLocalizations.delete,
      message: TextSpan(
        text:
            '${appLocalizations.deleteTip(appLocalizations.ruleSet)}\n'
            '${appLocalizations.privateRuleProviderDeleteDesc}',
      ),
    );
    if (result != true) return;
    final rules = await ref.read(globalRulesProvider.future);
    if (!mounted) return;
    final relatedRuleIds = rules
        .where(
          (item) =>
              item.ruleAction == RuleAction.RULE_SET &&
              item.ruleProvider == provider.name,
        )
        .map((item) => item.id)
        .toSet();
    if (relatedRuleIds.isNotEmpty) {
      ref.read(globalRulesProvider.notifier).delAll(relatedRuleIds);
    }
    await _saveProviders(
      _providers.where((item) => item.name != provider.name).toList(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final appLocalizations = context.appLocalizations;
    return BaseScaffold(
      title: appLocalizations.privateRuleProviders,
      actions: [
        IconButton(
          onPressed: _loading ? null : _handleAddOrEdit,
          tooltip: appLocalizations.add,
          icon: const Icon(Icons.add),
        ),
      ],
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _providers.isEmpty
          ? NullStatus(
              label: appLocalizations.nullTip(appLocalizations.ruleSet),
              illustration: const RuleEmptyIllustration(),
            )
          : ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 16),
              itemCount: _providers.length,
              itemBuilder: (context, index) {
                final provider = _providers[index];
                return Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 4,
                  ),
                  child: ItemPositionProvider(
                    position: ItemPosition.startAndEnd,
                    child: DecorationListItem(
                      title: Text(provider.name),
                      subtitle: Text(
                        '${provider.behavior} · ${provider.format} · '
                        '${provider.interval}s',
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            onPressed: () => _handleAddOrEdit(provider),
                            tooltip: appLocalizations.edit,
                            icon: const Icon(Icons.edit_outlined),
                          ),
                          IconButton(
                            onPressed: () => _handleDelete(provider),
                            tooltip: appLocalizations.delete,
                            icon: const Icon(Icons.delete_outline),
                          ),
                        ],
                      ),
                      onPressed: () => _handleAddOrEdit(provider),
                    ),
                  ),
                );
              },
            ),
    );
  }
}

class _PrivateRuleProviderDialog extends StatefulWidget {
  final PrivateRuleProviderConfig? provider;
  final Set<String> existingNames;

  const _PrivateRuleProviderDialog({
    required this.provider,
    required this.existingNames,
  });

  @override
  State<_PrivateRuleProviderDialog> createState() =>
      _PrivateRuleProviderDialogState();
}

class _PrivateRuleProviderDialogState
    extends State<_PrivateRuleProviderDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _urlController;
  late final TextEditingController _intervalController;
  late String _behavior;
  late String _format;

  @override
  void initState() {
    super.initState();
    final provider = widget.provider;
    _nameController = TextEditingController(text: provider?.name ?? '');
    _urlController = TextEditingController(text: provider?.url ?? '');
    _intervalController = TextEditingController(
      text: (provider?.interval ?? 86400).toString(),
    );
    _behavior = provider?.behavior ?? 'classical';
    _format = provider?.format ?? 'yaml';
  }

  @override
  void dispose() {
    _nameController.dispose();
    _urlController.dispose();
    _intervalController.dispose();
    super.dispose();
  }

  String? _validateName(String? value) {
    final name = value?.trim() ?? '';
    if (name.isEmpty) {
      return context.appLocalizations.emptyTip(context.appLocalizations.name);
    }
    if (widget.existingNames.contains(name)) {
      return context.appLocalizations.existsTip(context.appLocalizations.name);
    }
    try {
      PrivateRuleProviderConfig(
        name: name,
        url: 'https://example.com/rules.yaml',
      ).validate();
      return null;
    } catch (_) {
      return context.appLocalizations.invalidPolicy(name);
    }
  }

  String? _validateUrl(String? value) {
    try {
      PrivateRuleProviderConfig(
        name: 'validation',
        url: value?.trim() ?? '',
      ).validate();
      return null;
    } catch (_) {
      return context.appLocalizations.profileUrlInvalidValidationDesc;
    }
  }

  String? _validateInterval(String? value) {
    final interval = int.tryParse(value ?? '');
    if (interval == null || interval < 300 || interval > 604800) {
      return context
          .appLocalizations
          .profileAutoUpdateIntervalInvalidValidationDesc;
    }
    return null;
  }

  void _handleSubmit() {
    if (_formKey.currentState?.validate() != true) return;
    final provider = PrivateRuleProviderConfig(
      name: _nameController.text.trim(),
      url: _urlController.text.trim(),
      behavior: _behavior,
      format: _format,
      interval: int.parse(_intervalController.text),
    );
    provider.validate();
    Navigator.of(context).pop(provider);
  }

  @override
  Widget build(BuildContext context) {
    final appLocalizations = context.appLocalizations;
    return CommonDialog(
      title:
          '${widget.provider == null ? appLocalizations.add : appLocalizations.edit} '
          '${appLocalizations.ruleSet}',
      actions: [
        TextButton(
          onPressed: _handleSubmit,
          child: Text(appLocalizations.confirm),
        ),
      ],
      child: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _nameController,
                inputFormatters: TextInputLimits.limit(TextInputLimits.name),
                decoration: InputDecoration(labelText: appLocalizations.name),
                validator: _validateName,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _urlController,
                keyboardType: TextInputType.url,
                decoration: InputDecoration(labelText: appLocalizations.url),
                validator: _validateUrl,
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                initialValue: _behavior,
                decoration: InputDecoration(
                  labelText: appLocalizations.privateRuleProviderBehavior,
                ),
                items: privateRuleProviderBehaviors
                    .map(
                      (value) =>
                          DropdownMenuItem(value: value, child: Text(value)),
                    )
                    .toList(),
                onChanged: (value) {
                  if (value != null) _behavior = value;
                },
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                initialValue: _format,
                decoration: InputDecoration(
                  labelText: appLocalizations.privateRuleProviderFormat,
                ),
                items: privateRuleProviderFormats
                    .map(
                      (value) =>
                          DropdownMenuItem(value: value, child: Text(value)),
                    )
                    .toList(),
                onChanged: (value) {
                  if (value != null) _format = value;
                },
                validator: (value) {
                  if (value == 'mrs' && _behavior == 'classical') {
                    return appLocalizations.invalidPolicy('mrs/classical');
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _intervalController,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: appLocalizations.interval,
                  helperText: appLocalizations.privateRuleProviderIntervalDesc,
                ),
                validator: _validateInterval,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
