import 'dart:async';
import 'dart:io';

import 'package:fl_clash/pages/error.dart';
import 'package:fl_clash/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rust_api/rust_api.dart';

import 'application.dart';
import 'common/common.dart';
import 'common/diagnostic_journal.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (kPrivateClientMode) {
    diagnosticJournal.record('startup', {'source': 'app', 'result': 'begin'});
    try {
      await diagnosticJournal.open(
        Directory('${await appPath.homeDirPath}/diagnostics'),
      );
    } catch (_) {
      diagnosticJournal.storageFailed = true;
    }
  }
  try {
    if (system.isDesktop) {
      await RustLib.init();
    }
    final version = await system.init();
    final container = await globalState.init(version);
    if (kPrivateClientMode) {
      diagnosticJournal.record('ready', {
        'result': 'success',
        'platform': Platform.operatingSystem,
        'build': int.tryParse(globalState.packageInfo.buildNumber),
      });
    }
    HttpOverrides.global = FlClashHttpOverrides();
    runApp(
      UncontrolledProviderScope(
        container: container,
        child: const Application(),
      ),
    );
  } catch (e, s) {
    if (kPrivateClientMode) {
      diagnosticJournal.record('startup', {'result': 'failed'});
      await diagnosticJournal.flush();
    }
    runApp(
      MaterialApp(
        home: InitErrorScreen(error: e, stack: s),
      ),
    );
  }
}
