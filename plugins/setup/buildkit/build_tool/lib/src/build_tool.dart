import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import 'environment.dart';
import 'error.dart';
import 'go_builder.dart';
import 'logging.dart';
import 'options.dart';
import 'rust_builder.dart';
import 'target.dart';
import 'util.dart';

final _log = Logger('build_tool');

String _rootDir = '.';

String _findProjectRoot() {
  var dir = Directory.current;
  while (true) {
    if (File(p.join(dir.path, 'pubspec.yaml')).existsSync() &&
        File(p.join(dir.path, 'core')).existsSync()) {
      return dir.path;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return Directory.current.path;
}

Future<String> _hostGoArch() async {
  if (Platform.isWindows) {
    final pa = Platform.environment['PROCESSOR_ARCHITECTURE'] ?? 'AMD64';
    return pa.toUpperCase() == 'ARM64' ? 'arm64' : 'amd64';
  }
  final result = await Process.run('uname', ['-m']);
  final machine = (result.stdout as String).trim();
  if (machine == 'aarch64') return 'arm64';
  if (machine == 'x86_64') return 'amd64';
  return machine;
}

abstract class BuildCommand extends Command {
  Future<void> runBuildCommand();

  @override
  Future<void> run() async {
    await runBuildCommand();
  }
}

class BuildAndroidCommand extends BuildCommand {
  BuildAndroidCommand() {
    argParser.addOption(
      'arch',
      valueHelp: 'arm,arm64,amd64',
      help: 'Target architecture (omit to build all)',
    );
    argParser.addOption(
      'target-platform',
      valueHelp: 'android-arm,android-arm64,android-x64',
      help: 'Flutter target platform list (omit to build all)',
    );
  }

  @override
  final name = 'android';

  @override
  final description = 'Build Android Go core (c-shared library)';

  @override
  Future<void> runBuildCommand() async {
    final archName = argResults?['arch'] as String?;
    final flutterTargetPlatforms = argResults?['target-platform'] as String?;
    final config = BuildConfig.load(rootDir: _rootDir);

    final targets = Target.resolveAndroidTargets(
      archName: archName,
      flutterTargetPlatforms: flutterTargetPlatforms,
    );

    final builder = GoBuilder(rootDir: _rootDir, config: config);
    final corePaths = await builder.buildAll(targets);

    _log.info('Build complete: $corePaths');
  }
}

class BuildLinuxCommand extends BuildCommand {
  BuildLinuxCommand() {
    argParser.addOption(
      'arch',
      valueHelp: 'arm64,amd64',
      help: 'Target architecture (default: auto-detect)',
    );
  }

  @override
  final name = 'linux';

  @override
  final description = 'Build Linux Go core (executable)';

  @override
  Future<void> runBuildCommand() async {
    final archName = argResults?['arch'] as String?;
    final config = BuildConfig.load(rootDir: _rootDir);

    final arch = archName ?? await _hostGoArch();
    final targets = Target.forPlatform(
      'linux',
    ).where((t) => t.goarch == arch).toList();

    if (targets.isEmpty) {
      throw BuildException('Invalid arch: $arch');
    }

    final builder = GoBuilder(rootDir: _rootDir, config: config);
    final corePaths = await builder.buildAll(targets);

    _log.info('Build complete: $corePaths');
  }
}

class BuildWindowsCommand extends BuildCommand {
  BuildWindowsCommand() {
    argParser.addOption(
      'arch',
      valueHelp: 'amd64,arm64',
      help: 'Target architecture (default: auto-detect)',
    );
  }

  @override
  final name = 'windows';

  @override
  final description = 'Build Windows Go core + Rust helper';

  @override
  Future<void> runBuildCommand() async {
    final archName = argResults?['arch'] as String?;
    final debug = Environment.isDebug;
    final config = BuildConfig.load(rootDir: _rootDir);

    final arch = archName ?? await _hostGoArch();
    final targets = Target.forPlatform(
      'windows',
    ).where((t) => t.goarch == arch).toList();

    if (targets.isEmpty) {
      throw BuildException('Invalid arch: $arch');
    }

    final goBuilder = GoBuilder(rootDir: _rootDir, config: config);
    final corePaths = await goBuilder.buildAll(targets);

    _log.info('Build mode: ${debug ? 'debug' : 'release'}');

    if (debug) {
      await Process.run('taskkill', [
        '/F',
        '/IM',
        '${config.helperName}${targets.first.executableExtension}',
      ]);
      final rustBuilder = RustBuilder(rootDir: _rootDir, config: config);
      await rustBuilder.build(targets.first, '', release: false);
    } else {
      final coreSha256 = await calcSha256(corePaths.first);
      final rustBuilder = RustBuilder(rootDir: _rootDir, config: config);
      await rustBuilder.build(targets.first, coreSha256);
      await File(
        p.join(_rootDir, 'core_sha256.json'),
      ).writeAsString(jsonEncode({'CORE_SHA256': coreSha256}));
    }

    _log.info('Build complete: $corePaths');
  }
}

class BuildMacosCommand extends BuildCommand {
  BuildMacosCommand() {
    argParser.addOption(
      'arch',
      valueHelp: 'universal,arm64,amd64',
      help: 'Target architecture (default: universal)',
    );
  }

  @override
  final name = 'macos';

  @override
  final description = 'Build macOS Go core (executable)';

  @override
  Future<void> runBuildCommand() async {
    final archName = argResults?['arch'] as String?;
    final config = BuildConfig.load(rootDir: _rootDir);
    final targets = Target.resolveMacosTargets(archName: archName);
    final builder = GoBuilder(rootDir: _rootDir, config: config);
    if (targets.length == 1) {
      final corePaths = await builder.buildAll(targets);
      _log.info('Build complete: $corePaths');
      return;
    }

    final slices = <File>[];
    String? universalPath;
    try {
      for (final target in targets) {
        final builtPath = await builder.build(target);
        universalPath ??= builtPath;
        final slice = File('$builtPath.${target.goarch}');
        if (slice.existsSync()) {
          slice.deleteSync();
        }
        slices.add(File(builtPath).renameSync(slice.path));
      }

      if (universalPath == null || slices.length != 2) {
        throw BuildException('macOS Universal 2 core slices are incomplete');
      }
      runCommand('lipo', [
        '-create',
        ...slices.map((slice) => slice.path),
        '-output',
        universalPath,
      ]);
      final archResult = runCommand('lipo', ['-archs', universalPath]);
      final archs = (archResult.stdout as String).trim().split(RegExp(r'\s+'));
      if (archs.toSet().length != 2 ||
          !archs.contains('arm64') ||
          !archs.contains('x86_64')) {
        File(universalPath).deleteSync();
        throw BuildException(
          'macOS core is not Universal 2: ${archs.join(' ')}',
        );
      }

      _log.info('Universal 2 build complete: $universalPath');
    } finally {
      for (final slice in slices) {
        if (slice.existsSync()) {
          slice.deleteSync();
        }
      }
    }
  }
}

Future<void> runMain(List<String> args) async {
  try {
    initLogging();

    final runner = CommandRunner('build_tool', 'FlClash build tool')
      ..argParser.addOption(
        'root-dir',
        valueHelp: '<path>',
        help: 'Project root directory (default: auto-detect)',
      )
      ..addCommand(BuildAndroidCommand())
      ..addCommand(BuildLinuxCommand())
      ..addCommand(BuildWindowsCommand())
      ..addCommand(BuildMacosCommand());

    final topResults = runner.parse(args);
    _rootDir = (topResults['root-dir'] as String?) ?? _findProjectRoot();
    await runner.run(args);
  } on BuildException catch (e) {
    _log.severe(e.toString());
    exit(1);
  } on CommandFailedException catch (e) {
    _log.severe(e.toString());
    exit(1);
  } on UsageException catch (e) {
    stderr.writeln(e.toString());
    exit(1);
  } catch (e, s) {
    _log.severe(kDoubleSeparator);
    _log.severe('Build failed with unexpected error:');
    _log.severe(kSeparator);
    _log.severe('$e');
    _log.severe(kSeparator);
    _log.severe('$s');
    _log.severe(kDoubleSeparator);
    exit(1);
  }
}
