import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

const uiVisualDirectory = String.fromEnvironment('CLIENT_VISUAL_DIR');
const uiVisualFont = String.fromEnvironment('CLIENT_VISUAL_FONT');
const uiVisualKey = ValueKey('secondary-ui-capture');

Future<void> loadUiVisualFonts() async {
  if (uiVisualFont.isEmpty) return;
  await (FontLoader(
    'MaterialIcons',
  )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  await (FontLoader('ClientVisual')
        ..addFont(File(uiVisualFont).readAsBytes().then(ByteData.sublistView)))
      .load();
  await (FontLoader(
    'JetBrainsMono',
  )..addFont(rootBundle.load('assets/fonts/JetBrainsMono-Regular.ttf'))).load();
}

Future<void> captureUi(WidgetTester tester, String name) async {
  if (uiVisualDirectory.isEmpty) return;
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pump();
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(uiVisualKey),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('$uiVisualDirectory/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(png!.buffer.asUint8List());
    image.dispose();
  });
}
