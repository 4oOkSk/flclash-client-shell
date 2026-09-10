import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/views/config/general.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/material.dart';

class ConfigView extends StatelessWidget {
  const ConfigView({super.key});

  @override
  Widget build(BuildContext context) {
    return BaseScaffold(
      title: context.appLocalizations.basicConfig,
      body: generateListView(
        kPrivateClientMode
            ? generateSection(items: generalItems)
            : generalItems,
      ),
    );
  }
}
