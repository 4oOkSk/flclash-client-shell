import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'client_layout.dart';
import 'list.dart';

/// The page owns its heading at every window size.
class ClientPageHeading extends ConsumerWidget {
  final String title;
  final bool visible;

  const ClientPageHeading(this.title, {super.key, this.visible = true});

  @override
  Widget build(BuildContext context, WidgetRef ref) => ExcludeFocus(
    excluding: !visible,
    child: Offstage(
      offstage: !visible,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 24),
        child: Row(
          children: [
            Expanded(
              child: Text(title, style: context.textTheme.headlineMedium),
            ),
            IconButton(
              tooltip: context.appLocalizations.theme,
              onPressed: () => ref
                  .read(themeSettingProvider.notifier)
                  .update(
                    (value) => value.copyWith(
                      themeMode: Theme.of(context).brightness == Brightness.dark
                          ? ThemeMode.light
                          : ThemeMode.dark,
                    ),
                  ),
              icon: Icon(
                Theme.of(context).brightness == Brightness.dark
                    ? Icons.light_mode_outlined
                    : Icons.dark_mode_outlined,
                size: 21,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Shared scrolling canvas for responsive client pages.
class ClientPageContent extends ConsumerWidget {
  final List<Widget> children;
  final double maxWidth;
  final bool centered;
  final bool compact;
  final PageStorageKey<String>? storageKey;
  final PageLabel? pageLabel;

  const ClientPageContent({
    super.key,
    required this.children,
    this.maxWidth = 1020,
    this.centered = false,
    this.compact = false,
    this.storageKey,
    this.pageLabel,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) => SafeArea(
    child: LayoutBuilder(
      builder: (context, constraints) {
        final targetWidth =
            ClientLayoutWidth.maybeOf(context) ?? constraints.maxWidth;
        final padding = 20 + ((targetWidth - 600) / 12).clamp(0.0, 20.0);
        final vertical = compact
            ? 6.0
            : constraints.maxHeight < 520
            ? 16.0
            : 24.0;
        return SingleChildScrollView(
          key: storageKey,
          controller: pageLabel == null
              ? null
              : ref.watch(clientPageScrollControllerProvider(pageLabel!)),
          child: AnimatedPadding(
            duration: clientMotionDuration(context, ref),
            curve: Curves.easeOutCubic,
            padding: EdgeInsets.symmetric(
              horizontal: padding,
              vertical: vertical,
            ),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: centered
                    ? (constraints.maxHeight - vertical * 2).clamp(
                        0,
                        double.infinity,
                      )
                    : 0,
              ),
              child: Align(
                alignment: centered ? Alignment.center : Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: maxWidth),
                  child: ClientLayoutWidth(
                    width: (targetWidth - padding * 2).clamp(0.0, maxWidth),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: children,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    ),
  );
}

/// One always-visible inset-divider list.
class ClientMenuGroup extends StatelessWidget {
  final List<Widget> children;
  final Widget? header;
  final bool separated;
  final PageStorageKey<String>? storageKey;

  const ClientMenuGroup({
    super.key,
    required this.children,
    this.header,
    this.separated = true,
    this.storageKey,
  });

  @override
  Widget build(BuildContext context) {
    final rows = separated
        ? children.separated(const ClientListDivider()).toList()
        : children;
    return Card(
      key: storageKey,
      child: Column(children: [?header, ...rows]),
    );
  }
}
