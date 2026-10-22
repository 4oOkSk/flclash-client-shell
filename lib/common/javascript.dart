import 'dart:convert';

import 'package:fl_clash/core/controller.dart';

typedef ScriptEvaluator =
    Future<Map<String, dynamic>> Function(
      String script,
      Map<String, dynamic> config,
    );

Future<Map<String, dynamic>> handleEvaluate(
  String scriptContent,
  Map<String, dynamic> config, {
  ScriptEvaluator? evaluator,
}) async {
  // The Core owns a disposable, interruptible script VM. A Dart Future timeout
  // over synchronous native JS cannot stop a loop or release its engine.
  final snapshot = Map<String, dynamic>.from(
    jsonDecode(
          jsonEncode({
            ...config,
            'proxy-providers': config['proxy-providers'] ?? <String, Object?>{},
          }),
        )
        as Map,
  );
  if (scriptContent.length > 1024 * 1024 ||
      jsonEncode(snapshot).length > 16 * 1024 * 1024) {
    throw StateError('Script input exceeds its limit');
  }
  return (evaluator ?? coreController.evaluateScript)(scriptContent, snapshot);
}
