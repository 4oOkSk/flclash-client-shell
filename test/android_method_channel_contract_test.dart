import 'dart:io';

import 'package:fl_clash/common/constant.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Dart and Android use the same MethodChannel namespace', () {
    final components = File(
      'android/common/src/main/java/com/follow/clash/common/Components.kt',
    ).readAsStringSync();
    final nativeNamespace = RegExp(
      r'const val PACKAGE_NAME = "([^"]+)"',
    ).firstMatch(components)?.group(1);

    expect(nativeNamespace, isNotNull);
    expect(packageName, nativeNamespace);
  });

  test('Android plugins derive channels from Components.PACKAGE_NAME', () {
    const plugins = <String, String>{
      'android/app/src/main/kotlin/com/follow/clash/plugins/AppPlugin.kt':
          r'${Components.PACKAGE_NAME}/app',
      'android/app/src/main/kotlin/com/follow/clash/plugins/ServicePlugin.kt':
          r'${Components.PACKAGE_NAME}/service',
      'android/app/src/main/kotlin/com/follow/clash/plugins/TilePlugin.kt':
          r'${Components.PACKAGE_NAME}/tile',
    };

    for (final entry in plugins.entries) {
      expect(
        File(entry.key).readAsStringSync(),
        contains(entry.value),
        reason: entry.key,
      );
    }
  });
}
