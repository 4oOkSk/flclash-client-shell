import 'dart:io';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/pages/editor.dart';
import 'package:fl_clash/providers/action.dart';
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/providers/database.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class ScriptsView extends ConsumerStatefulWidget {
  const ScriptsView({super.key});

  @override
  ConsumerState<ScriptsView> createState() => _ScriptsViewState();
}

class _ScriptsViewState extends ConsumerState<ScriptsView> {
  final _key = utils.id;
  int? _activePrivateScriptId;
  bool _privateScriptLoaded = kClientApiBase.isEmpty;

  @override
  void initState() {
    super.initState();
    if (kClientApiBase.isNotEmpty) {
      preferences.getPrivateRouteScriptId().then((scriptId) {
        if (!mounted) return;
        setState(() {
          _activePrivateScriptId = scriptId;
          _privateScriptLoaded = true;
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

  Future<void> _setActivePrivateScript(int? scriptId) async {
    final saved = await preferences.savePrivateRouteScriptId(scriptId);
    if (!saved || !mounted) return;
    setState(() {
      _activePrivateScriptId = scriptId;
    });
    _applyPrivateRouteOverlay();
  }

  Future<void> _handleDelScript(int id) async {
    final appLocalizations = context.appLocalizations;
    final res = await globalState.showMessage(
      message: TextSpan(
        text: appLocalizations.deleteTip(appLocalizations.script),
      ),
    );
    if (res != true) {
      return;
    }
    ref.read(scriptsProvider.notifier).del(id);
    ref.read(itemProvider(_key).notifier).value = null;
    _clearEffect(id);
    if (_activePrivateScriptId == id) {
      await _setActivePrivateScript(null);
    }
  }

  Future<void> _clearEffect(int id) async {
    final path = await appPath.getScriptPath(id.toString());
    await File(path).safeDelete();
  }

  void _handleSelected(int id) {
    ref.read(itemProvider(_key).notifier).update((value) {
      if (value == id) {
        return null;
      }
      return id;
    });
  }

  Widget _buildContent(List<Script> scripts, int? selectedScriptId) {
    final appLocalizations = context.appLocalizations;
    if (scripts.isEmpty) {
      return NullStatus(
        illustration: const ScriptEmptyIllustration(),
        label: appLocalizations.nullTip(appLocalizations.script),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 16),
      itemCount: scripts.length,
      itemBuilder: (_, index) {
        final script = scripts[index];
        return CommonSelectedListItem(
          isSelected: selectedScriptId == script.id,
          title: Text(
            script.label,
            style: context.textTheme.bodyLarge,
            maxLines: 3,
          ),
          onSelected: () {
            _handleSelected(script.id);
          },
          onPressed: () {
            _handleSelected(script.id);
          },
        );
      },
    );
  }

  Future<void> _handleEditorSave(
    BuildContext _,
    String title,
    String content, {
    Script? script,
  }) async {
    final appLocalizations = context.appLocalizations;
    Script newScript =
        (script?.copyWith(label: title) ?? Script.create(label: title));
    newScript = await newScript.save(content);
    if (newScript.label.isEmpty) {
      final res = await globalState.showCommonDialog<String>(
        child: InputDialog(
          title: appLocalizations.save,
          value: '',
          hintText: appLocalizations.pleaseEnterScriptName,
          inputFormatters: TextInputLimits.limit(TextInputLimits.name),
          validator: (value) {
            if (value == null || value.isEmpty) {
              return appLocalizations.emptyTip(appLocalizations.name);
            }
            if (value != script?.label) {
              final isExits = ref.read(scriptsProvider.notifier).isExits(value);
              if (isExits) {
                return appLocalizations.existsTip(appLocalizations.name);
              }
            }
            return null;
          },
        ),
      );
      if (res == null || res.isEmpty) {
        return;
      }
      newScript = newScript.copyWith(label: res);
    }
    if (newScript.label != script?.label) {
      final isExits = ref
          .read(scriptsProvider.notifier)
          .isExits(newScript.label);
      if (isExits) {
        globalState.showMessage(
          message: TextSpan(
            text: appLocalizations.existsTip(appLocalizations.name),
          ),
        );
        return;
      }
    }
    ref.read(scriptsProvider.notifier).put(newScript);
    if (_activePrivateScriptId == newScript.id) {
      _applyPrivateRouteOverlay();
    }
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  Future<bool> _handleEditorPop(
    BuildContext _,
    String title,
    String content,
    String raw, {
    Script? script,
  }) async {
    final appLocalizations = context.appLocalizations;
    if (content == raw) {
      return true;
    }
    final res = await globalState.showMessage(
      message: TextSpan(text: appLocalizations.saveChanges),
    );
    if (res == true && mounted) {
      _handleEditorSave(context, title, content, script: script);
    } else {
      return true;
    }
    return false;
  }

  void _handleToEditor([int? id]) async {
    final script = await ref.read(scriptProvider(id).future);
    final title = script?.label ?? '';
    final raw =
        (await script?.content) ??
        (kClientApiBase.isNotEmpty
            ? privateRouteScriptTemplate
            : scriptTemplate);
    if (!mounted) {
      return;
    }
    BaseNavigator.push(
      context,
      EditorPage(
        titleEditable: true,
        title: title,
        supportRemoteDownload: true,
        onSave: (context, title, content) {
          _handleEditorSave(context, title, content, script: script);
        },
        onPop: (context, title, content) {
          return _handleEditorPop(context, title, content, raw, script: script);
        },
        languages: const [Language.javaScript],
        content: raw,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final appLocalizations = context.appLocalizations;
    final scripts = ref.watch(scriptsProvider).value ?? [];
    final selectedScriptId = ref.watch(itemProvider(_key));
    final activeScript = scripts.get(_activePrivateScriptId);
    final content = _buildContent(scripts, selectedScriptId);
    return CommonPopScope(
      onPop: (_) {
        if (selectedScriptId != null) {
          ref.read(itemProvider(_key).notifier).value = null;
          return false;
        }
        Navigator.of(context).pop();
        return false;
      },
      child: CommonScaffold(
        actions: [
          if (selectedScriptId != null) ...[
            CommonMinIconButtonTheme(
              child: IconButton.filledTonal(
                onPressed: () {
                  _handleDelScript(selectedScriptId);
                },
                icon: const Icon(Icons.delete),
              ),
            ),
            const SizedBox(width: 2),
          ],
          CommonMinFilledButtonTheme(
            child: selectedScriptId != null
                ? FilledButton(
                    onPressed: () {
                      _handleToEditor(selectedScriptId);
                    },
                    child: Text(appLocalizations.edit),
                  )
                : FilledButton.tonal(
                    onPressed: () {
                      _handleToEditor();
                    },
                    child: Text(appLocalizations.add),
                  ),
          ),
          const SizedBox(width: 8),
        ],
        body: kClientApiBase.isNotEmpty
            ? Column(
                children: [
                  if (_privateScriptLoaded)
                    ListItem<int>.options(
                      leading: const Icon(Icons.route_outlined),
                      title: Text(appLocalizations.privateRouteScript),
                      subtitle: Text(
                        '${appLocalizations.privateRouteScriptDesc}\n'
                        '${activeScript?.label ?? appLocalizations.privateRouteScriptDisabled}',
                      ),
                      dialogTitle: appLocalizations.privateRouteScript,
                      options: [-1, ...scripts.map((item) => item.id)],
                      textBuilder: (value) => value == -1
                          ? appLocalizations.privateRouteScriptDisabled
                          : scripts.get(value)?.label ??
                                appLocalizations.privateRouteScriptDisabled,
                      value: activeScript?.id ?? -1,
                      onChanged: (value) {
                        if (value == null) return;
                        _setActivePrivateScript(value == -1 ? null : value);
                      },
                    )
                  else
                    const LinearProgressIndicator(),
                  const Divider(height: 0),
                  Expanded(child: content),
                ],
              )
            : content,
        title: kClientApiBase.isNotEmpty
            ? appLocalizations.routeScript
            : appLocalizations.script,
      ),
    );
  }
}
