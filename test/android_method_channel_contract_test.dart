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

  test('cold quick start restores configuration without showing the app', () {
    final quickAction = File(
      'android/app/src/main/kotlin/com/follow/clash/QuickActionActivity.kt',
    ).readAsStringSync();
    final serviceState = File(
      'android/app/src/main/kotlin/com/follow/clash/ServiceState.kt',
    ).readAsStringSync();
    final mainActivity = File(
      'android/app/src/main/kotlin/com/follow/clash/MainActivity.kt',
    ).readAsStringSync();
    final application = File('lib/application.dart').readAsStringSync();

    expect(quickAction, contains('prepareFlutterBootstrapStart()'));
    expect(quickAction, contains('Components.mainActivity.intent'));
    expect(serviceState, contains('consumePendingFlutterStart()'));
    expect(mainActivity, contains('updateWindowVisibility(false)'));
    expect(mainActivity, contains('moveTaskToBack(true)'));
    expect(mainActivity, contains('if (!moved)'));
    expect(mainActivity, contains('cancelPendingFlutterStart()'));
    expect(application, contains('consumePendingQuickStart()'));
    expect(application, contains('setRunning(true)'));
  });
}
