import 'package:fl_clash/models/profile.dart';
import 'package:fl_clash/pages/editor.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:flutter/material.dart';

class PreviewProfileView extends StatefulWidget {
  final Profile profile;

  const PreviewProfileView({super.key, required this.profile});

  @override
  State<PreviewProfileView> createState() => _PreviewProfileViewState();
}

class _PreviewProfileViewState extends State<PreviewProfileView> {
  final contentNotifier = ValueNotifier<String?>(null);

  @override
  void initState() {
    super.initState();
    _loadContent();
  }

  Future<void> _loadContent() async {
    final content = await globalState.safeRun(() async {
      final container = globalState.container;
      final patchConfig = container.read(patchClashConfigProvider);
      final setupState = await container.read(
        setupStateProvider(widget.profile.id).future,
      );
      final result = await container
          .read(setupActionProvider.notifier)
          .getProfile(setupState: setupState, patchConfig: patchConfig);
      return result.a;
    });
    if (mounted) contentNotifier.value = content ?? '';
  }

  @override
  void dispose() {
    contentNotifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: contentNotifier,
      builder: (_, content, _) =>
          EditorPage(title: widget.profile.realLabel, content: content),
    );
  }
}
