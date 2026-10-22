import 'dart:ffi';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:ffi/ffi.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/plugins/app.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/widgets/input.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class System {
  static System? _instance;
  bool _isTV = false;

  System._internal();

  factory System() {
    _instance ??= System._internal();
    return _instance!;
  }

  bool get isDesktop => isWindows || isMacOS || isLinux;

  bool get isWindows => Platform.isWindows;

  bool get isMacOS => Platform.isMacOS;

  bool get isAndroid => Platform.isAndroid;

  bool get isLinux => Platform.isLinux;

  bool get isTV => _isTV;

  Future<int> init() async {
    final deviceInfo = await DeviceInfoPlugin().deviceInfo;
    _isTV = switch (deviceInfo) {
      AndroidDeviceInfo(:final systemFeatures) => systemFeatures.any(
        const {
          'android.hardware.type.television',
          'android.software.leanback',
        }.contains,
      ),
      _ => false,
    };
    return switch (Platform.operatingSystem) {
      'macos' => (deviceInfo as MacOsDeviceInfo).majorVersion,
      'android' => (deviceInfo as AndroidDeviceInfo).version.sdkInt,
      'windows' => (deviceInfo as WindowsDeviceInfo).majorVersion,
      String() => 0,
    };
  }

  Future<bool> didCrashOnPreviousExecution() async {
    if (!isAndroid) return false;
    return await app?.didCrashOnPreviousExecution() ?? false;
  }

  Future<bool> checkIsAdmin() async {
    final corePath = appPath.corePath;
    if (system.isWindows) {
      return windows?.isUserAnAdmin() ?? false;
    } else if (system.isMacOS) {
      final result = await Process.run('stat', ['-f', '%Su:%Sg %Sp', corePath]);
      final output = result.stdout.trim();
      if (output.startsWith('root:admin') && output.contains('rws')) {
        return true;
      }
      return false;
    } else if (Platform.isLinux) {
      final result = await Process.run('stat', ['-c', '%U:%G %A', corePath]);
      final output = result.stdout.trim();
      if (output.startsWith('root:') && output.contains('rws')) {
        return true;
      }
      return false;
    }
    return true;
  }

  static String _shellEscape(String value) {
    return "'${value.replaceAll("'", "'\\''")}'";
  }

  static String _escapeAppleScriptString(String value) {
    return value.replaceAll('\\', '\\\\').replaceAll('"', '\\"');
  }

  Future<AuthorizeCode> authorizeCore() async {
    if (system.isAndroid) {
      return AuthorizeCode.error;
    }
    final isAdmin = await checkIsAdmin();
    if (isAdmin) {
      if (system.isWindows && !await coreBinaryMatchesExpectedHash()) {
        return AuthorizeCode.coreHashMismatch;
      }
      return AuthorizeCode.none;
    }

    if (system.isWindows) {
      return AuthorizeCode.error;
    }

    if (system.isMacOS) {
      final escapedPath = _shellEscape(appPath.corePath);
      final shell = 'chown root:admin $escapedPath && chmod +sx $escapedPath';
      final arguments = [
        '-e',
        'do shell script "${_escapeAppleScriptString(shell)}" with administrator privileges',
      ];
      try {
        final result = await Process.run('/usr/bin/osascript', arguments);
        if (result.exitCode != 0) {
          return AuthorizeCode.error;
        }
      } catch (_) {
        return AuthorizeCode.error;
      }
      return AuthorizeCode.success;
    } else if (Platform.isLinux) {
      final password = await globalState.showCommonDialog<String>(
        child: InputDialog(
          obscureText: true,
          title: currentAppLocalizations.pleaseInputAdminPassword,
          value: '',
          inputFormatters: TextInputLimits.limit(TextInputLimits.password),
        ),
      );
      if (password == null || password.isEmpty) {
        return AuthorizeCode.error;
      }
      try {
        final process = await Process.start('/usr/bin/sudo', [
          '-S',
          '-p',
          '',
          '--',
          '/bin/sh',
          '-c',
          r'chown root:root "$1" && chmod u+sx "$1"',
          'harborproxy-authorize',
          appPath.corePath,
        ]);
        final outputDrain = process.stdout.drain<void>();
        final errorDrain = process.stderr.drain<void>();
        process.stdin.writeln(password);
        await process.stdin.close();
        final exitCode = await process.exitCode;
        await Future.wait([outputDrain, errorDrain]);
        if (exitCode != 0) {
          return AuthorizeCode.error;
        }
      } catch (_) {
        return AuthorizeCode.error;
      }
      return AuthorizeCode.success;
    }
    return AuthorizeCode.error;
  }

  Future<bool> coreBinaryMatchesExpectedHash() async {
    if (kDebugMode) return true;
    final expected = globalState.coreSHA256.trim().toLowerCase();
    if (expected.isEmpty) return false;
    try {
      final digest = await sha256.bind(File(appPath.corePath).openRead()).first;
      return digest.toString().toLowerCase() == expected;
    } catch (_) {
      return false;
    }
  }

  Future<void> back() async {
    await app?.moveTaskToBack();
    await window?.hide();
  }

  Future<void> exit() async {
    if (system.isAndroid) {
      await SystemNavigator.pop();
    }
    window?.forceExit();
  }
}

final system = System();

class Windows {
  static Windows? _instance;
  late DynamicLibrary _shell32;

  Windows._internal() {
    _shell32 = DynamicLibrary.open('shell32.dll');
  }

  factory Windows() {
    _instance ??= Windows._internal();
    return _instance!;
  }

  bool isUserAnAdmin() {
    final check = _shell32.lookupFunction<Int32 Function(), int Function()>(
      'IsUserAnAdmin',
    );
    return check() != 0;
  }

  bool runas(String command, String arguments) {
    final commandPtr = command.toNativeUtf16();
    final argumentsPtr = arguments.toNativeUtf16();
    final operationPtr = 'runas'.toNativeUtf16();

    final shellExecute = _shell32
        .lookupFunction<
          Int32 Function(
            Pointer<Utf16> hwnd,
            Pointer<Utf16> lpOperation,
            Pointer<Utf16> lpFile,
            Pointer<Utf16> lpParameters,
            Pointer<Utf16> lpDirectory,
            Int32 nShowCmd,
          ),
          int Function(
            Pointer<Utf16> hwnd,
            Pointer<Utf16> lpOperation,
            Pointer<Utf16> lpFile,
            Pointer<Utf16> lpParameters,
            Pointer<Utf16> lpDirectory,
            int nShowCmd,
          )
        >('ShellExecuteW');

    final result = shellExecute(
      nullptr,
      operationPtr,
      commandPtr,
      argumentsPtr,
      nullptr,
      1,
    );

    calloc.free(commandPtr);
    calloc.free(argumentsPtr);
    calloc.free(operationPtr);

    commonPrint.log(
      'windows runas: $command $arguments resultCode:$result',
      logLevel: LogLevel.warning,
    );

    if (result <= 32) {
      return false;
    }
    return true;
  }
}

final windows = system.isWindows ? Windows() : null;

class MacOS {
  static MacOS? _instance;

  final Future<ProcessResult> Function(String, List<String>) _runProcess;
  final _dnsScheduler = SerialTaskScheduler();
  final _dnsOwners =
      <String, ({List<String> original, List<String> applied})>{};

  MacOS._internal() : _runProcess = Process.run;

  @visibleForTesting
  MacOS.forTesting(this._runProcess);

  factory MacOS() {
    _instance ??= MacOS._internal();
    return _instance!;
  }

  Future<String?> get defaultServiceName async {
    final result = await _runProcess('route', ['-n', 'get', 'default']);
    if (result.exitCode != 0) return null;
    final output = result.stdout.toString();
    final deviceLine = output
        .split('\n')
        .firstWhere((s) => s.contains('interface:'), orElse: () => '');
    final lineSplits = deviceLine.trim().split(RegExp(r'\s+'));
    if (lineSplits.length != 2) {
      return null;
    }
    final device = lineSplits[1];
    final serviceResult = await _runProcess('networksetup', [
      '-listnetworkserviceorder',
    ]);
    if (serviceResult.exitCode != 0) {
      throw ProcessException(
        'networksetup',
        ['-listnetworkserviceorder'],
        'Unable to read network services',
        serviceResult.exitCode,
      );
    }
    final serviceResultOutput = serviceResult.stdout.toString();
    final currentService = serviceResultOutput
        .split('\n\n')
        .firstWhere(
          (s) => RegExp('Device: ${RegExp.escape(device)}\\s*\\)').hasMatch(s),
          orElse: () => '',
        );
    if (currentService.isEmpty) {
      return null;
    }
    final currentServiceNameLine = currentService
        .split('\n')
        .firstWhere(
          (line) => RegExp(r'^\(\d+\).*').hasMatch(line),
          orElse: () => '',
        );
    final name = currentServiceNameLine
        .replaceFirst(RegExp(r'^\(\d+\)\s*'), '')
        .trim();
    return name.isEmpty ? null : name;
  }

  Future<List<String>?> get systemDns async {
    final deviceServiceName = await defaultServiceName;
    if (deviceServiceName == null) {
      return null;
    }
    return _readDns(deviceServiceName);
  }

  Future<List<String>> _readDns(String service) async {
    final result = await _runProcess('networksetup', [
      '-getdnsservers',
      service,
    ]);
    if (result.exitCode != 0) {
      throw ProcessException(
        'networksetup',
        ['-getdnsservers', service],
        'Unable to read network DNS',
        result.exitCode,
      );
    }
    final output = result.stdout.toString().trim();
    if (output.startsWith("There aren't any DNS Servers set on")) {
      return [];
    }
    return output
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
  }

  Future<void> updateDns(bool restore) => _dnsScheduler.run(() async {
    if (restore) {
      Object? firstError;
      for (final entry in _dnsOwners.entries.toList()) {
        try {
          final current = await _readDns(entry.key);
          if (listEquals(current, entry.value.applied)) {
            await _writeDns(entry.key, entry.value.original);
          }
          // External changes are not ours to undo.
          _dnsOwners.remove(entry.key);
        } catch (error) {
          firstError ??= error;
        }
      }
      if (firstError != null) throw firstError;
      return;
    }
    final service = await defaultServiceName;
    if (service == null) return;
    final current = await _readDns(service);
    final owner = _dnsOwners[service];
    if (owner != null) {
      if (listEquals(current, owner.applied)) return;
      _dnsOwners.remove(service);
    }
    if (current.contains('223.5.5.5')) return;
    final next = [...current, '223.5.5.5'];
    // Record before the write so a partial command failure is recoverable.
    _dnsOwners[service] = (original: current, applied: next);
    await _writeDns(service, next);
  });

  Future<void> _writeDns(String service, List<String> servers) async {
    final result = await _runProcess('networksetup', [
      '-setdnsservers',
      service,
      if (servers.isEmpty) 'Empty' else ...servers,
    ]);
    if (result.exitCode != 0 || !listEquals(await _readDns(service), servers)) {
      throw ProcessException(
        'networksetup',
        ['-setdnsservers', service],
        'Unable to apply network DNS',
        result.exitCode,
      );
    }
  }
}

final macOS = system.isMacOS ? MacOS() : null;
