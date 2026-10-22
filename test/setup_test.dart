import 'package:test/test.dart';

import '../setup.dart' as setup;

void main() {
  group('setup.dart', () {
    test('parses -v as verbose mode', () {
      final results = setup.createSetupArgParser().parse(['android', '-v']);

      expect(results['verbose'], isTrue);
      expect(results.rest, ['android']);
    });

    test('accepts dev application environment', () {
      final results = setup.createSetupArgParser().parse([
        'android',
        '--env',
        'dev',
      ]);

      expect(results['env'], 'dev');
    });

    test('process build environment contains only application mode', () {
      expect(setup.createBuildEnvironment('dev'), {'APP_ENV': 'dev'});
    });

    test('accepts only a lowercase SHA256 from the Core manifest', () {
      const hash =
          '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

      expect(setup.parseCoreManifestSha256('{"coreSha256":"$hash"}'), hash);
      expect(
        setup.parseCoreManifestSha256('{"coreSha256":"NOT-A-HASH"}'),
        isNull,
      );
      expect(setup.parseCoreManifestSha256('invalid-json'), isNull);
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
        defineFile: '/tmp/client/defines.json',
      );

      expect(args, ['dart-define-from-file=/tmp/client/defines.json']);
    });

    test('uses only supported flutter_distributor package arguments', () {
      final args = setup.createDistributorPackageArgs(
        platform: 'linux',
        targets: 'deb',
        flutterBuildArgs: ['dart-define-from-file=env.json'],
      );

      expect(args, containsAllInOrder(['--platform', 'linux']));
      expect(args, containsAllInOrder(['--targets', 'deb']));
      expect(args, isNot(contains('--description')));
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
  });
}
