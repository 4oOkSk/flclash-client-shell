import 'dart:math' as math;

import 'package:fl_clash/common/common.dart';
import 'package:flutter/material.dart';

import 'pop_scope.dart';

class ClientSelectionOption<T> {
  final T value;
  final String label;

  const ClientSelectionOption({required this.value, required this.label});
}

class ClientSelectionMenu<T> extends StatefulWidget {
  final String title;
  final String label;
  final T? value;
  final List<ClientSelectionOption<T>> options;
  final ValueChanged<T> onSelected;
  final bool enabled;
  final bool busy;
  final bool asField;
  final String? errorText;
  final IconData? leading;

  const ClientSelectionMenu({
    super.key,
    required this.title,
    required this.label,
    required this.value,
    required this.options,
    required this.onSelected,
    this.enabled = true,
    this.busy = false,
    this.asField = false,
    this.errorText,
    this.leading,
  });

  @override
  State<ClientSelectionMenu<T>> createState() => _ClientSelectionMenuState<T>();
}

class _ClientSelectionMenuState<T> extends State<ClientSelectionMenu<T>> {
  final _controller = MenuController();
  final _focus = FocusNode();
  double _height = 480;
  bool _open = false;

  Future<void> _showSelection() async {
    if (_open || !widget.enabled || widget.busy || widget.options.isEmpty) {
      return;
    }
    setState(() => _open = true);
    final selected = await showDialog<T>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(widget.title),
        scrollable: true,
        contentPadding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        content: SizedBox(
          key: const ValueKey('client-selection-panel'),
          width: 420,
          child: RadioGroup<T>(
            groupValue: widget.value,
            onChanged: (value) => Navigator.of(context).pop(value),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final option in widget.options)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Material(
                      color: option.value == widget.value
                          ? context.colorScheme.secondaryContainer
                          : context.colorScheme.surfaceContainerLow,
                      borderRadius: BorderRadius.circular(16),
                      clipBehavior: Clip.antiAlias,
                      child: RadioListTile<T>(
                        key: ValueKey(option.value),
                        value: option.value,
                        selected: option.value == widget.value,
                        controlAffinity: ListTileControlAffinity.trailing,
                        title: Text(
                          option.label,
                          style: TextStyle(
                            color: option.value == widget.value
                                ? context.colorScheme.onSecondaryContainer
                                : context.colorScheme.onSurface,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(context.appLocalizations.cancel),
          ),
        ],
      ),
    );
    if (!mounted) return;
    setState(() => _open = false);
    if (selected != null &&
        selected != widget.value &&
        widget.enabled &&
        !widget.busy &&
        widget.options.any((option) => option.value == selected)) {
      widget.onSelected(selected);
    }
  }

  void _toggle() {
    if (_controller.isOpen) {
      _controller.close();
      return;
    }
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final anchor = context.findRenderObject()! as RenderBox;
    final media = MediaQuery.of(context);
    final bounds = (media.padding + media.viewInsets).deflateRect(
      Offset.zero & overlay.size,
    );
    final rect =
        anchor.localToGlobal(Offset.zero, ancestor: overlay) & anchor.size;
    setState(() {
      _height =
          math
              .max(bounds.bottom - rect.bottom, rect.top - bounds.top)
              .clamp(48, 488) -
          8;
    });
    _controller.open();
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.asField) {
      return Tooltip(
        message: widget.title,
        child: InkWell(
          focusNode: _focus,
          onTap: widget.enabled && !widget.busy && widget.options.isNotEmpty
              ? _showSelection
              : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 17),
            child: Row(
              children: [
                if (widget.leading case final leading?) ...[
                  Icon(
                    leading,
                    size: 20,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 12),
                ],
                Expanded(
                  child: Text(
                    widget.label,
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                ),
                const SizedBox(width: 8),
                if (widget.busy)
                  const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  const Icon(Icons.chevron_right, size: 20),
              ],
            ),
          ),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.clamp(0.0, 520.0);
        final enabled =
            widget.enabled && !widget.busy && widget.options.isNotEmpty;
        final options = widget.options;
        final trailing = widget.busy
            ? const SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(_open ? Icons.expand_less : Icons.expand_more);
        return MenuAnchor(
          controller: _controller,
          consumeOutsideTap: true,
          animated: !MediaQuery.disableAnimationsOf(context),
          onOpen: () => setState(() => _open = true),
          onClose: () => setState(() => _open = false),
          alignmentOffset: const Offset(0, 8),
          style: MenuStyle(
            alignment: AlignmentDirectional.bottomStart,
            minimumSize: WidgetStatePropertyAll(Size(width, 0)),
            maximumSize: WidgetStatePropertyAll(Size(width, _height)),
            backgroundColor: WidgetStatePropertyAll(
              context.colorScheme.surfaceContainer,
            ),
            shape: const WidgetStatePropertyAll(
              RoundedRectangleBorder(
                borderRadius: BorderRadius.all(Radius.circular(14)),
              ),
            ),
          ),
          menuChildren: [
            // Material owns positioning, scrolling, focus and reversible animation.
            SizedBox(
              key: const ValueKey('client-selection-panel'),
              width: width,
            ),
            for (final option in options)
              MenuItemButton(
                key: ValueKey(option.value),
                autofocus: option.value == widget.value,
                leadingIcon: SizedBox(
                  width: 24,
                  child: option.value == widget.value
                      ? const Icon(Icons.check)
                      : null,
                ),
                style: MenuItemButton.styleFrom(
                  minimumSize: const Size(0, 52),
                  backgroundColor: option.value == widget.value
                      ? context.colorScheme.secondaryContainer
                      : null,
                  foregroundColor: option.value == widget.value
                      ? context.colorScheme.onSecondaryContainer
                      : null,
                ),
                onPressed: enabled
                    ? () {
                        if (widget.value != option.value) {
                          widget.onSelected(option.value);
                        }
                      }
                    : null,
                child: SizedBox(
                  width: math.max(0, width - 72),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [Text(option.label)],
                    ),
                  ),
                ),
              ),
          ],
          builder: (context, controller, child) => Stack(
            children: [
              Material(
                color: Colors.transparent,
                child: InkWell(
                  focusNode: _focus,
                  borderRadius: BorderRadius.circular(16),
                  onTap: enabled ? _toggle : null,
                  child: InputDecorator(
                    isFocused: _open,
                    decoration: InputDecoration(
                      labelText: widget.title,
                      errorText: widget.errorText,
                      enabled: enabled,
                      suffixIcon: trailing,
                    ),
                    child: Text(
                      widget.label,
                      style: context.textTheme.bodyLarge,
                    ),
                  ),
                ),
              ),
              if (_open)
                BackLayerScope(
                  onBack: controller.close,
                  child: const SizedBox.shrink(),
                ),
            ],
          ),
        );
      },
    );
  }
}
