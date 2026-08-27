import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('Android startup has no Firebase or Play services runtime setup', () {
    final root = Directory.current;
    final googleServicesConfig = File(
      '${root.path}/android/app/google-services.json',
    );
    expect(googleServicesConfig.existsSync(), isFalse);

    const inspectedPaths = [
      'android/app/build.gradle.kts',
      'android/common/build.gradle.kts',
      'android/settings.gradle.kts',
      'android/gradle/libs.versions.toml',
      'android/common/src/main/java/com/follow/clash/common/GlobalState.kt',
      'android/app/src/main/kotlin/com/follow/clash/FlClashApplication.kt',
      'android/app/src/main/kotlin/com/follow/clash/ServiceState.kt',
      'android/app/src/main/kotlin/com/follow/clash/plugins/AppPlugin.kt',
      'android/app/src/main/kotlin/com/follow/clash/plugins/ServicePlugin.kt',
    ];
    const forbiddenMarkers = [
      'com.google.firebase',
      'com.google.gms.google-services',
      'firebase-analytics',
      'firebase-crashlytics',
      'FirebaseApp',
      'FirebaseCrashlytics',
      'setCrashlytics',
    ];

    for (final path in inspectedPaths) {
      final contents = File('${root.path}/$path').readAsStringSync();
      for (final marker in forbiddenMarkers) {
        expect(contents, isNot(contains(marker)), reason: '$marker in $path');
      }
    }

    final gradleProperties = File(
      '${root.path}/android/gradle.properties',
    ).readAsStringSync();
    expect(
      gradleProperties,
      contains('dev.steenbakker.mobile_scanner.useUnbundled=false'),
    );
  });
}
