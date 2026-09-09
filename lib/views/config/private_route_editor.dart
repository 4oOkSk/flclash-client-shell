import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/common/private_route_input.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter/material.dart';

class PrivateRouteEditor extends StatefulWidget {
  final Rule? rule;

  const PrivateRouteEditor({super.key, this.rule});

  @override
  State<PrivateRouteEditor> createState() => _PrivateRouteEditorState();
}

class _PrivateRouteEditorState extends State<PrivateRouteEditor> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _destination;
  late String _target;
  late bool _subdomains;

  @override
  void initState() {
    super.initState();
    final rule = widget.rule;
    _destination = TextEditingController(
      text: rule?.content?.replaceFirst(RegExp(r'/(32|128)$'), '') ?? '',
    );
    _target = rule?.ruleTarget ?? privateRouteCurrentLine;
    _subdomains = rule == null || rule.ruleAction == RuleAction.DOMAIN_SUFFIX;
  }

  @override
  void dispose() {
    _destination.dispose();
    super.dispose();
  }

  void _save() {
    if (_form.currentState?.validate() != true) return;
    Navigator.of(context).pop(
      buildSimplePrivateRoute(
        input: _destination.text,
        target: _target,
        includeSubdomains: _subdomains,
        id: widget.rule?.id ?? snowflake.id,
        order: widget.rule?.order,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final text = context.appLocalizations;
    return AlertDialog(
      title: Text(
        widget.rule == null ? text.routeAddException : text.routeEditException,
      ),
      content: SizedBox(
        width: 440,
        child: Form(
          key: _form,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextFormField(
                  key: const ValueKey('route-destination'),
                  controller: _destination,
                  autofocus: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText: text.routeDestination,
                    hintText: 'example.com',
                  ),
                  validator: (value) {
                    try {
                      normalizePrivateRouteDestination(value ?? '');
                      return null;
                    } catch (_) {
                      return text.routeInvalidDestination;
                    }
                  },
                ),
                const SizedBox(height: 12),
                Text(
                  text.routeDomainHint,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(text.routeIncludeSubdomains),
                  value: _subdomains,
                  onChanged: (value) =>
                      setState(() => _subdomains = value == true),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  key: const ValueKey('route-action'),
                  initialValue: _target,
                  isExpanded: true,
                  items: [
                    DropdownMenuItem(
                      value: privateRouteCurrentLine,
                      child: Text(text.routeViaLine),
                    ),
                    DropdownMenuItem(
                      value: 'DIRECT',
                      child: Text(text.routeDirect),
                    ),
                    DropdownMenuItem(
                      value: 'REJECT',
                      child: Text(text.routeReject),
                    ),
                  ],
                  onChanged: (value) {
                    if (value != null) setState(() => _target = value);
                  },
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(text.cancel),
        ),
        FilledButton(onPressed: _save, child: Text(text.routeSaveApply)),
      ],
    );
  }
}
