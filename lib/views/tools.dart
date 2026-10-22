import 'dart:io';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' show dirname, join;

import 'about.dart';
import 'access.dart';
import 'application_setting.dart';
import 'backup_and_restore.dart';
import 'config/advanced.dart';
import 'developer.dart';
import 'hotkey.dart';
import 'theme.dart';

class ToolsView extends ConsumerWidget {
  const ToolsView({super.key});

  Future<void> _showDisclaimer(BuildContext context) async {
    await globalState.showCommonDialog<void>(
      context: context,
      child: Builder(
        builder: (dialogContext) => CommonDialog(
          title: context.appLocalizations.disclaimer,
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(context.appLocalizations.close),
            ),
          ],
          child: SelectableText(context.appLocalizations.disclaimerDesc),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = context.appLocalizations;
    Widget entry(
      IconData icon,
      String title,
      Widget page, [
      String? description,
    ]) => ListItem.open(
      leading: Icon(icon),
      title: Text(title),
      widget: page,
      subtitle: description != null ? Text(description) : null,
    );
    final settings = [
      const _LocaleItem(),
      entry(
        Icons.style_outlined,
        text.theme,
        const ThemeView(),
        text.themeDesc,
      ),
      entry(
        Icons.settings_outlined,
        text.application,
        const ApplicationSettingView(),
        text.applicationDesc,
      ),
      entry(
        Icons.cloud_sync_outlined,
        text.backupAndRestore,
        const BackupAndRestore(),
        text.backupAndRestoreDesc,
      ),
      if (system.isDesktop)
        entry(
          Icons.keyboard_outlined,
          text.hotkeyManagement,
          const HotKeyView(),
          text.hotkeyManagementDesc,
        ),
      if (system.isWindows)
        ListItem(
          leading: const Icon(Icons.lock_outline),
          title: Text(text.loopback),
          subtitle: Text(text.loopbackDesc),
          onTap: () => windows?.runas(
            '"${join(dirname(Platform.resolvedExecutable), "EnableLoopback.exe")}"',
            '',
          ),
        ),
      if (system.isAndroid)
        entry(
          Icons.view_list_outlined,
          text.accessControl,
          const AccessView(),
          text.accessControlDesc,
        ),
      entry(
        Icons.tune,
        text.advancedConfig,
        const AdvancedConfigView(),
        text.advancedConfigDesc,
      ),
    ];
    final diagnostics = _diagnosticItems(context, ref);
    final other = [
      ListItem(
        leading: const Icon(Icons.gavel),
        title: Text(text.disclaimer),
        onTap: () => _showDisclaimer(context),
      ),
      if (ref.watch(appSettingProvider.select((state) => state.developerMode)))
        entry(Icons.developer_board, text.developerMode, const DeveloperView()),
    ];
    final about = entry(Icons.info_outline, text.about, const AboutView());
    return CommonScaffold(
      title: text.tools,
      body: ListView(
        key: toolsStoreKey,
        padding: const EdgeInsets.only(bottom: 20),
        children: [
          if (diagnostics.isNotEmpty)
            ...generateSection(title: text.more, items: diagnostics),
          ...generateSection(title: text.settings, items: settings),
          ...generateSection(title: text.other, items: [...other, about]),
        ],
      ),
    );
  }
}

List<Widget> _diagnosticItems(BuildContext context, WidgetRef ref) => [
  for (final item in ref.watch(moreToolsSelectorStateProvider).navigationItems)
    ListItem.open(
      leading: item.icon,
      title: Text(navigationItemLabel(context, item)),
      subtitle: item.description == null
          ? null
          : Text(Intl.message(item.description!)),
      widget: item.builder(context),
      maxWidth: 400,
    ),
];

class _LocaleItem extends ConsumerWidget {
  const _LocaleItem();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final locale = ref.watch(
      appSettingProvider.select((state) => state.locale),
    );
    final selectedLocale = utils.getLocaleForString(locale);
    return ListItem<Locale?>.options(
      leading: const Icon(Icons.language_outlined),
      title: Text(context.appLocalizations.language),
      subtitle: Text(
        Intl.message(
          selectedLocale?.toString() ?? context.appLocalizations.defaultText,
        ),
      ),
      dialogTitle: context.appLocalizations.language,
      options: [null, ...AppLocalizations.delegate.supportedLocales],
      onChanged: (locale) => ref
          .read(appSettingProvider.notifier)
          .update((state) => state.copyWith(locale: locale?.toString())),
      textBuilder: (locale) => locale == null
          ? context.appLocalizations.defaultText
          : Intl.message(locale.toString()),
      value: selectedLocale,
    );
  }
}
