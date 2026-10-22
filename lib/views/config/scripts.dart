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
  bool _deleting = false;
  final _key = utils.id;

  Future<void> _handleDelScript(int id) async {
    if (_deleting) return;
    final script = ref.read(scriptsProvider).value?.get(id);
    if (script == null) return;
    setState(() => _deleting = true);
    final appLocalizations = context.appLocalizations;
    try {
      final res = await globalState.showMessage(
        message: TextSpan(
          text: appLocalizations.deleteTip(appLocalizations.script),
        ),
      );
      if (res != true || !mounted) return;
      await ref.read(scriptActionProvider.notifier).remove(script);
      if (!mounted) return;
      ref.read(itemProvider(_key).notifier).value = null;
    } catch (_) {
      if (mounted) {
        context.showSnackBar(appLocalizations.scriptDeleteFailed);
      }
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  void _handleSelected(int id) {
    if (_deleting) return;
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

  Future<bool> _handleEditorSave(
    BuildContext editorContext,
    String title,
    String content, {
    Script? script,
  }) async {
    final appLocalizations = context.appLocalizations;
    var label = title;
    if (label.trim().isEmpty) {
      final res = await globalState.showCommonDialog<String>(
        child: InputDialog(
          title: appLocalizations.save,
          value: '',
          hintText: appLocalizations.pleaseEnterScriptName,
          inputFormatters: TextInputLimits.limit(TextInputLimits.name),
          validator: (value) {
            if (value == null || value.trim().isEmpty) {
              return appLocalizations.emptyTip(appLocalizations.name);
            }
            if (value != script?.label) {
              final isExits =
                  ref
                      .read(scriptsProvider)
                      .value
                      ?.any(
                        (item) => item.id != script?.id && item.label == value,
                      ) ??
                  false;
              if (isExits) {
                return appLocalizations.existsTip(appLocalizations.name);
              }
            }
            return null;
          },
        ),
      );
      if (res == null || res.isEmpty) {
        return false;
      }
      label = res;
    }
    if (!mounted || !editorContext.mounted) return false;
    try {
      await ref
          .read(scriptActionProvider.notifier)
          .save(
            script?.copyWith(label: label) ?? Script.create(label: label),
            content,
          );
    } catch (error) {
      if (editorContext.mounted) {
        editorContext.showSnackBar(
          error is ScriptNameConflict
              ? appLocalizations.existsTip(appLocalizations.name)
              : appLocalizations.scriptSaveFailed,
        );
      }
      return false;
    }
    if (mounted && editorContext.mounted) {
      Navigator.of(editorContext).pop();
    }
    return true;
  }

  Future<bool> _handleEditorPop(
    BuildContext editorContext,
    String title,
    String content,
    String raw, {
    Script? script,
  }) async {
    final appLocalizations = context.appLocalizations;
    if (content == raw && title == (script?.label ?? '')) {
      return true;
    }
    final res = await globalState.showCommonDialog<bool>(
      context: editorContext,
      child: CommonDialog(
        title: appLocalizations.save,
        actions: [
          TextButton(
            onPressed: () => Navigator.of(editorContext).pop(),
            child: Text(appLocalizations.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(editorContext).pop(false),
            child: Text(appLocalizations.discardChanges),
          ),
          TextButton(
            onPressed: () => Navigator.of(editorContext).pop(true),
            child: Text(appLocalizations.save),
          ),
        ],
        child: Text(appLocalizations.saveChanges),
      ),
    );
    if (res == false) return true;
    if (res == true && mounted && editorContext.mounted) {
      await _handleEditorSave(editorContext, title, content, script: script);
    }
    return false;
  }

  void _handleToEditor([int? id]) async {
    final script = await ref.read(scriptProvider(id).future);
    final title = script?.label ?? '';
    final raw = (await script?.content) ?? scriptTemplate;
    if (!mounted) {
      return;
    }
    BaseNavigator.push(
      context,
      EditorPage(
        titleEditable: true,
        title: title,
        supportRemoteDownload: true,
        onSave: (context, title, content) async {
          await _handleEditorSave(context, title, content, script: script);
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
                onPressed: _deleting
                    ? null
                    : () {
                        _handleDelScript(selectedScriptId);
                      },
                tooltip: appLocalizations.delete,
                icon: _deleting
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.delete),
              ),
            ),
            const SizedBox(width: 2),
          ],
          CommonMinFilledButtonTheme(
            child: selectedScriptId != null
                ? FilledButton(
                    onPressed: _deleting
                        ? null
                        : () {
                            _handleToEditor(selectedScriptId);
                          },
                    child: Text(appLocalizations.edit),
                  )
                : FilledButton.tonal(
                    onPressed: _deleting
                        ? null
                        : () {
                            _handleToEditor();
                          },
                    child: Text(appLocalizations.add),
                  ),
          ),
          const SizedBox(width: 8),
        ],
        body: content,
        title: appLocalizations.script,
      ),
    );
  }
}
