import 'package:fl_clash/common/task.dart';
import 'package:fl_clash/models/profile.dart';
import 'package:fl_clash/pages/editor.dart';
import 'package:fl_clash/providers/action.dart';
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
    // 入册模式: 不加载/展示原始配置(含服务器地址)。预览页已被禁用。
  }

  @override
  void dispose() {
    contentNotifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 入册模式: 预览页禁用，不显示任何原始配置内容。
    return const Scaffold(body: SizedBox.shrink());
  }
}
