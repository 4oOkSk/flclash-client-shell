import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;

import 'lib/common/private_build_input.dart';

const _allTargets = <String, String>{
  'android': 'apk',
  'linux': 'deb', // appimage + rpm added for amd64 only
  'macos': 'dmg',
  'windows': 'exe,zip',
};

const _androidFlutterTarget = {
  'arm': 'android-arm',
  'arm64': 'android-arm64',
  'amd64': 'android-x64',
};

const _hostPlatform = {
  'linux': 'linux',
  'macos': 'macos',
  'windows': 'windows',
};

Future<void> main(List<String> args) async {
  final parser = createSetupArgParser();

  if (args.contains('--help') || args.contains('-h')) {
    _showHelp(parser);
    exit(0);
  }

  final results = parser.parse(args);
  final rest = results.rest;

  final hostOs = Platform.operatingSystem;
  final host = _hostPlatform[hostOs];
  if (host == null) {
    stderr.writeln('Unsupported host platform: $hostOs');
    exit(1);
  }

  final platform = rest.isNotEmpty ? rest.first : host;

  if (platform != host && platform != 'android') {
    stderr.writeln(
      'Cannot build "$platform" on $hostOs. Allowed: $host, android',
    );
    _showHelp(parser);
    exit(1);
  }

  final env = results['env'] as String;
  final rootDir = Directory.current.path;
  final requestedArch = results['arch'] as String?;
  final arch = resolveBuildArch(
    platform: platform,
    hostArch: _detectArch(),
    requestedArch: requestedArch,
  );
  final targets = _getTargets(platform, arch, results['targets']);
  final androidArch = platform == 'android' ? requestedArch : null;
  final verbose = results['verbose'] as bool;
  final splitAndroid = results['split-per-abi'] as bool;

  final exitCode = await _package(
    platform,
    env,
    targets,
    rootDir,
    arch,
    androidArch: androidArch,
    splitAndroid: splitAndroid,
    verbose: verbose,
  );
  exit(exitCode);
}

ArgParser createSetupArgParser() {
  return ArgParser()
    ..addOption(
      'env',
      defaultsTo: 'pre',
      allowed: ['pre', 'stable'],
      help: 'Application environment',
    )
    ..addOption(
      'targets',
      valueHelp: 'exe,zip,dmg,apk,...',
      help: 'Package targets (default: all for platform)',
    )
    ..addOption(
      'arch',
      valueHelp: 'arm,arm64,amd64,universal',
      allowed: ['arm', 'arm64', 'amd64', 'universal'],
      help: 'Target architecture (macOS defaults to Universal 2)',
    )
    ..addFlag(
      'verbose',
      abbr: 'v',
      negatable: false,
      help: 'Enable verbose Flutter build output',
    )
    ..addFlag(
      'split-per-abi',
      defaultsTo: true,
      help:
          'Build separate Android APKs per ABI (disable for one universal APK)',
    );
}

String resolveBuildArch({
  required String platform,
  required String hostArch,
  String? requestedArch,
}) {
  if (platform == 'macos') {
    final arch = requestedArch ?? 'universal';
    if (!const {'universal', 'arm64', 'amd64'}.contains(arch)) {
      throw ArgumentError.value(arch, 'requestedArch', 'Invalid macOS arch');
    }
    return arch;
  }
  if (platform == 'android' && requestedArch == 'universal') {
    throw ArgumentError.value(
      requestedArch,
      'requestedArch',
      'Android universal APKs omit --arch instead of using universal',
    );
  }
  return hostArch;
}

List<String> createFlutterBuildArgs({
  required String platform,
  required bool verbose,
  bool splitAndroid = true,
  String defineFile = 'env.json',
}) {
  final flutterBuildArgs = <String>[
    if (verbose) 'verbose',
    'dart-define-from-file=$defineFile',
  ];
  if (platform == 'android' && splitAndroid) {
    flutterBuildArgs.add('split-per-abi');
  }
  return flutterBuildArgs;
}

String _getTargets(String platform, String arch, String? customTargets) {
  if (customTargets != null) return customTargets;
  if (platform == 'linux' && arch == 'amd64') return 'deb,appimage,rpm';
  return _allTargets[platform]!;
}

void _showHelp(ArgParser parser) {
  stderr.writeln('Usage: dart setup.dart [platform] [options]');
  stderr.writeln('Platform: current host platform (default) or android');
  stderr.writeln();
  stderr.writeln('Default package targets:');
  _allTargets.forEach((p, t) => stderr.writeln('  $p: $t'));
  stderr.writeln();
  stderr.writeln(parser.usage);
}

Future<int> _package(
  String platform,
  String env,
  String targets,
  String rootDir,
  String arch, {
  String? androidArch,
  required bool splitAndroid,
  required bool verbose,
}) async {
  final tempDir = await Directory.systemTemp.createTemp(
    'private-client-build-',
  );
  final defineFile = File(p.join(tempDir.path, 'defines.json'));
  final generatedGoFile = File(
    p.join(rootDir, 'core', 'client_build_config_generated.go'),
  );

  try {
    final goBuildConfig = createPrivateClientGoBuildConfig(
      Platform.environment,
    );
    if (goBuildConfig.isNotEmpty) {
      await generatedGoFile.writeAsString(goBuildConfig, flush: true);
    }

    final coreSha256 = platform == 'windows'
        ? await _buildGoCore(rootDir)
        : null;

    final buildDefines = <String, Object?>{
      'APP_ENV': env,
      'CORE_SHA256': ?coreSha256,
    };
    final privateApiBase = Platform.environment['PRIVATE_CLIENT_API_BASE']
        ?.trim();
    if (privateApiBase != null && privateApiBase.isNotEmpty) {
      buildDefines['PRIVATE_CLIENT_API_BASE_OBF'] = encodePrivateClientApiBase(
        privateApiBase,
      );
    }
    for (final key in [
      'PRIVATE_CLIENT_ENROLL_BLOB',
      'PRIVATE_CLIENT_WEBSITE_URL',
    ]) {
      final value = Platform.environment[key]?.trim();
      if (value != null && value.isNotEmpty) {
        buildDefines[key] = value;
      }
    }
    await defineFile.writeAsString(jsonEncode(buildDefines), flush: true);
    if (!Platform.isWindows) {
      final chmod = await Process.run('chmod', ['600', defineFile.path]);
      if (chmod.exitCode != 0) {
        stderr.write(chmod.stderr);
        return chmod.exitCode;
      }
    }

    final flutterBuildArgs = createFlutterBuildArgs(
      platform: platform,
      verbose: verbose,
      splitAndroid: splitAndroid,
      defineFile: defineFile.path,
    );
    final descriptionArgs = <String>[];
    if (platform != 'android') {
      descriptionArgs.addAll(['--description', arch]);
    }

    final depExit = await _ensureDependencies(platform, arch);
    if (depExit != 0) return depExit;

    final activateResult = await Process.run('dart', [
      'pub',
      'global',
      'activate',
      '-s',
      'git',
      'https://github.com/chen08209/flutter_distributor.git',
      '--git-ref',
      // Pin the packaging code used by CI/test builds. A mutable branch here
      // would execute whatever the upstream branch contains at build time.
      'cdeeef2d8f8325bb6ae0bc86b39f56e4325d1a58',
      '--git-path',
      'packages/flutter_distributor',
    ]);
    if (activateResult.exitCode != 0) {
      stderr.write(activateResult.stderr);
      return activateResult.exitCode;
    }

    final process = await Process.start(
      Platform.resolvedExecutable,
      [
        'pub',
        'global',
        'run',
        'flutter_distributor:main',
        'package',
        '--skip-clean',
        '--platform',
        platform,
        '--targets',
        targets,
        if (androidArch != null)
          '--build-target-platform=${_androidFlutterTarget[androidArch]!}',
        if (flutterBuildArgs.isNotEmpty)
          '--flutter-build-args=${flutterBuildArgs.join(',')}',
        ...descriptionArgs,
      ],
      includeParentEnvironment: true,
      environment: {'ANDROID_ARCH': ?androidArch},
      runInShell: false,
    );

    process.stdout.listen((data) {
      stdout.add(data);
    });
    process.stderr.listen((data) {
      stderr.add(data);
    });
    return await process.exitCode;
  } finally {
    if (generatedGoFile.existsSync()) {
      await generatedGoFile.delete();
    }
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  }
}

String createPrivateClientGoBuildConfig(Map<String, String> environment) {
  const variables = <String, String>{
    'PRIVATE_CLIENT_API_USER_AGENT': 'clientAPIUserAgent',
    'PRIVATE_CLIENT_LOGIN_PATH': 'clientLoginEndpointPath',
    'PRIVATE_CLIENT_CONFIG_PATH': 'clientConfigEndpointPath',
    'PRIVATE_CLIENT_LOGOUT_PATH': 'clientLogoutEndpointPath',
  };
  final assignments = <String>[];
  for (final entry in variables.entries) {
    final value = environment[entry.key]?.trim();
    if (value != null && value.isNotEmpty) {
      assignments.add('\t${entry.value} = ${jsonEncode(value)}');
    }
  }
  if (assignments.isEmpty) return '';
  return 'package main\n\nfunc init() {\n${assignments.join('\n')}\n}\n';
}

Future<String?> _buildGoCore(String rootDir) async {
  final buildToolDir = p.join(
    rootDir,
    'plugins',
    'setup',
    'buildkit',
    'build_tool',
  );
  final result = await Process.run('dart', [
    'run',
    'build_tool',
    'windows',
    '--root-dir',
    rootDir,
  ], workingDirectory: buildToolDir);
  if (result.exitCode != 0) {
    stderr.write(result.stderr);
    return null;
  }
  final shaFile = File(p.join(rootDir, 'core_sha256.json'));
  if (!shaFile.existsSync()) return null;
  final content =
      jsonDecode(shaFile.readAsStringSync()) as Map<String, dynamic>;
  return content['CORE_SHA256'] as String?;
}

String _detectArch() {
  if (Platform.isWindows) {
    final pa = Platform.environment['PROCESSOR_ARCHITECTURE'] ?? 'AMD64';
    return pa.toUpperCase() == 'ARM64' ? 'arm64' : 'amd64';
  }
  final result = Process.runSync('uname', ['-m']);
  final machine = (result.stdout as String).trim();
  if (machine == 'aarch64') return 'arm64';
  if (machine == 'x86_64') return 'amd64';
  return machine;
}

Future<bool> _hasCommand(String cmd) async {
  final which = Platform.isWindows ? 'where' : 'command';
  final args = Platform.isWindows ? [cmd] : ['-v', cmd];
  final result = await Process.run(which, args);
  return result.exitCode == 0;
}

Future<int> _ensureDependencies(String platform, String arch) async {
  switch (platform) {
    case 'macos':
      return _ensureMacosDependencies();
    case 'linux':
      return _ensureLinuxDependencies(arch);
    default:
      return 0;
  }
}

Future<int> _ensureMacosDependencies() async {
  if (await _hasCommand('appdmg')) {
    stdout.writeln('appdmg already installed, skipping.');
    return 0;
  }
  stdout.writeln('Installing appdmg (DMG creator)...');
  final result = await Process.run('npm', ['install', '-g', 'appdmg']);
  if (result.exitCode != 0) {
    stderr.write(result.stderr);
  }
  return result.exitCode;
}

Future<int> _ensureLinuxDependencies(String arch) async {
  final pkgGroups = <List<String>>[
    ['ninja-build', 'libgtk-3-dev'],
    ['libayatana-appindicator3-dev'],
    ['libkeybinder-3.0-dev'],
    ['locate'],
  ];
  if (arch == 'amd64') {
    pkgGroups.addAll([
      ['rpm', 'patchelf'],
      ['libfuse2'],
    ]);
  }

  final missingGroups = <List<String>>[];
  for (final group in pkgGroups) {
    final missingPkgs = <String>[];
    for (final pkg in group) {
      if (!await _isDebianPackageInstalled(pkg)) {
        missingPkgs.add(pkg);
      }
    }
    if (missingPkgs.isNotEmpty) {
      missingGroups.add(missingPkgs);
    }
  }

  if (missingGroups.isEmpty) {
    stdout.writeln('All Linux build dependencies already installed, skipping.');
  } else {
    stdout.writeln('Updating apt package lists...');
    final updateExit = await _runLinuxDependencyCommand([
      'apt-get',
      'update',
      '-y',
    ]);
    if (updateExit != 0) {
      stderr.writeln(
        'apt-get update exited with $updateExit; continuing and verifying '
        'dependency installation directly.',
      );
    }

    for (final missingPkgs in missingGroups) {
      stdout.writeln(
        'Installing Linux build dependencies: ${missingPkgs.join(', ')}...',
      );
      final installExit = await _installLinuxPackages(missingPkgs);
      if (installExit != 0) return installExit;
    }
  }

  if (arch == 'amd64') {
    const appimagetool = '/usr/local/bin/appimagetool';
    if (File(appimagetool).existsSync()) {
      stdout.writeln('appimagetool already installed, skipping.');
      return 0;
    }
    stdout.writeln('Downloading appimagetool...');
    final downloadName = arch == 'amd64' ? 'x86_64' : 'aarch64';
    final dlResult = await Process.run('wget', [
      '-O',
      appimagetool,
      'https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-$downloadName.AppImage',
    ]);
    if (dlResult.exitCode != 0) {
      stderr.write(dlResult.stderr);
      return dlResult.exitCode;
    }
    await Process.run('chmod', ['+x', appimagetool]);
  }

  return 0;
}

Future<bool> _isDebianPackageInstalled(String pkg) async {
  final result = await Process.run('dpkg', ['-s', pkg]);
  return result.exitCode == 0 &&
      (result.stdout as String).contains('Status: install ok installed');
}

Future<bool> _areDebianPackagesInstalled(List<String> pkgs) async {
  for (final pkg in pkgs) {
    if (!await _isDebianPackageInstalled(pkg)) {
      return false;
    }
  }
  return true;
}

Future<int> _installLinuxPackages(List<String> pkgs) async {
  final exitCode = await _runLinuxDependencyCommand([
    'apt-get',
    'install',
    '-y',
    ...pkgs,
  ]);
  if (exitCode == 0) return 0;

  if (await _areDebianPackagesInstalled(pkgs)) {
    stderr.writeln(
      'apt-get install exited with $exitCode, but all requested packages are '
      'installed; continuing.',
    );
    return 0;
  }

  return exitCode;
}

Future<int> _runLinuxDependencyCommand(List<String> command) async {
  final sudoCommand = [
    'env',
    'DEBIAN_FRONTEND=noninteractive',
    'NEEDRESTART_MODE=a',
    ...command,
  ];
  stdout.writeln('exec: sudo ${sudoCommand.join(' ')}');
  final result = await Process.start('sudo', sudoCommand);
  result.stdout.listen((data) {
    stdout.write(utf8.decode(data));
  });
  result.stderr.listen((data) {
    stderr.write(utf8.decode(data));
  });
  final exitCode = await result.exitCode;
  if (exitCode != 0) {
    stderr.writeln('Linux dependency command failed with exit code $exitCode.');
  }
  return exitCode;
}
