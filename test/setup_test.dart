import 'package:test/test.dart';

import '../setup.dart' as setup;
import '../lib/common/private_build_input.dart';

void main() {
  group('setup.dart', () {
    test('parses -v as verbose mode', () {
      final results = setup.createSetupArgParser().parse(['android', '-v']);

      expect(results['verbose'], isTrue);
      expect(results.rest, ['android']);
    });

    test('omits verbose from flutter build args by default', () {
      final args = setup.createFlutterBuildArgs(
        platform: 'android',
        verbose: false,
      );

      expect(args, ['dart-define-from-file=env.json', 'split-per-abi']);
    });

    test('adds verbose to flutter build args with -v', () {
      final args = setup.createFlutterBuildArgs(
        platform: 'android',
        verbose: true,
      );

      expect(args, [
        'verbose',
        'dart-define-from-file=env.json',
        'split-per-abi',
      ]);
    });

    test('can build one universal Android APK', () {
      final args = setup.createFlutterBuildArgs(
        platform: 'android',
        verbose: false,
        splitAndroid: false,
      );

      expect(args, ['dart-define-from-file=env.json']);
    });

    test('can use a temporary Dart define file', () {
      final args = setup.createFlutterBuildArgs(
        platform: 'linux',
        verbose: false,
        defineFile: '/tmp/private-client/defines.json',
      );

      expect(args, ['dart-define-from-file=/tmp/private-client/defines.json']);
    });

    test('defaults macOS release builds to Universal 2', () {
      final arch = setup.resolveBuildArch(platform: 'macos', hostArch: 'arm64');

      expect(arch, 'universal');
    });

    test('allows an explicit Intel-only macOS build', () {
      final arch = setup.resolveBuildArch(
        platform: 'macos',
        hostArch: 'arm64',
        requestedArch: 'amd64',
      );

      expect(arch, 'amd64');
    });

    test('rejects universal as an Android architecture name', () {
      expect(
        () => setup.resolveBuildArch(
          platform: 'android',
          hostArch: 'arm64',
          requestedArch: 'universal',
        ),
        throwsArgumentError,
      );
    });

    test('generates private Go build configuration without logging values', () {
      final source = setup.createPrivateClientGoBuildConfig({
        'PRIVATE_CLIENT_API_USER_AGENT': 'ExampleClient/1',
        'PRIVATE_CLIENT_LOGIN_PATH': '/private/login',
      });

      expect(source, contains('clientAPIUserAgent = "ExampleClient/1"'));
      expect(source, contains('clientLoginEndpointPath = "/private/login"'));
      expect(source, isNot(contains('clientConfigEndpointPath')));
    });

    test('obfuscates the private API base without changing its value', () {
      const raw = 'https://example.fcapp.run/client';
      final encoded = encodePrivateClientApiBase(raw);

      expect(encoded, isNot(contains('fcapp.run')));
      expect(decodePrivateClientApiBase(encoded), raw);
      expect(decodePrivateClientApiBase('not-valid'), isEmpty);
    });
  });
}
