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
import 'package:path/path.dart';

class System {
  static System? _instance;

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

  Future<int> get version async {
    final deviceInfo = await DeviceInfoPlugin().deviceInfo;
    return switch (Platform.operatingSystem) {
      'macos' => (deviceInfo as MacOsDeviceInfo).majorVersion,
      'android' => (deviceInfo as AndroidDeviceInfo).version.sdkInt,
      'windows' => (deviceInfo as WindowsDeviceInfo).majorVersion,
      String() => 0,
    };
  }

  Future<bool> checkIsAdmin() async {
    final corePath = appPath.corePath;
    if (system.isWindows) {
      final result = await windows?.checkService();
      return result == WindowsHelperServiceStatus.running;
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
      return AuthorizeCode.none;
    }

    if (system.isWindows) {
      final result = await windows?.registerService();
      return result ?? AuthorizeCode.error;
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

  Future<void> back() async {
    await app?.moveTaskToBack();
    await window?.hide();
  }

  Future<void> exit() async {
    if (system.isAndroid) {
      await SystemNavigator.pop();
    }
    await window?.close();
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

  // Future<void> _killProcess(int port) async {
  //   final result = await Process.run('netstat', ['-ano']);
  //   final lines = result.stdout.toString().trim().split('\n');
  //   for (final line in lines) {
  //     if (!line.contains(':$port') || !line.contains('LISTENING')) {
  //       continue;
  //     }
  //     final parts = line.trim().split(RegExp(r'\s+'));
  //     final pid = int.tryParse(parts.last);
  //     if (pid != null) {
  //      await Process.run('taskkill', ['/PID', pid.toString(), '/F']);
  //     }
  //   }
  // }

  Future<WindowsHelperServiceStatus> checkService() async {
    if (!await _coreHashMatches()) {
      return WindowsHelperServiceStatus.coreHashMismatch;
    }
    final result = await Process.run('sc.exe', ['query', appHelperService]);
    if (result.exitCode != 0) {
      return WindowsHelperServiceStatus.none;
    }
    final registeredHelperPath = await _registeredHelperPath();
    if (registeredHelperPath == null ||
        !_windowsPathsEqual(registeredHelperPath, appPath.helperPath)) {
      return WindowsHelperServiceStatus.imagePathMismatch;
    }
    final output = result.stdout.toString();
    if (!output.contains('RUNNING')) {
      return WindowsHelperServiceStatus.presence;
    }
    final pingStatus = await request.checkHelperPing();
    return switch (pingStatus) {
      WindowsHelperPingStatus.success => WindowsHelperServiceStatus.running,
      WindowsHelperPingStatus.unreachable =>
        WindowsHelperServiceStatus.helperUnreachable,
      WindowsHelperPingStatus.tokenMismatch =>
        WindowsHelperServiceStatus.helperTokenMismatch,
    };
  }

  Future<bool> _coreHashMatches() async {
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

  Future<String?> _registeredHelperPath() async {
    try {
      final result = await Process.run('reg.exe', [
        'query',
        r'HKLM\SYSTEM\CurrentControlSet\Services\HarborProxyHelperService',
        '/v',
        'ImagePath',
      ]);
      if (result.exitCode != 0) return null;
      final match = RegExp(
        r'REG_(?:EXPAND_)?SZ\s+(.+)$',
        multiLine: true,
      ).firstMatch(result.stdout.toString());
      final value = match?.group(1)?.trim();
      if (value == null || value.isEmpty) return null;
      final expanded = _expandWindowsEnvironment(value);
      if (expanded.startsWith('"')) {
        final closing = expanded.indexOf('"', 1);
        if (closing <= 1) return null;
        return expanded.substring(1, closing);
      }
      final executable = expanded.split(RegExp(r'\s+')).first;
      return executable;
    } catch (_) {
      return null;
    }
  }

  String _expandWindowsEnvironment(String value) {
    return value.replaceAllMapped(RegExp(r'%([^%]+)%'), (match) {
      return Platform.environment[match.group(1)] ?? match.group(0)!;
    });
  }

  bool _windowsPathsEqual(String left, String right) {
    try {
      return normalize(absolute(left)).toLowerCase() ==
          normalize(absolute(right)).toLowerCase();
    } catch (_) {
      return false;
    }
  }

  Future<AuthorizeCode> registerService() async {
    final status = await checkService();

    if (status == WindowsHelperServiceStatus.running) {
      return AuthorizeCode.success;
    }
    if (status == WindowsHelperServiceStatus.coreHashMismatch) {
      return AuthorizeCode.coreHashMismatch;
    }

    final helperPath = appPath.helperPath;
    if (helperPath.contains('"')) {
      return AuthorizeCode.imagePathMismatch;
    }
    final token = DateTime.now().microsecondsSinceEpoch.toString();
    final scriptPath = join(
      await appPath.tempPath,
      'harborproxy-helper-install-$token.cmd',
    );
    final statusPath = join(
      await appPath.tempPath,
      'harborproxy-helper-install-$token.status',
    );
    final batchHelperPath = helperPath.replaceAll('%', '%%');
    final batchStatusPath = statusPath.replaceAll('%', '%%');
    final batchQuotedHelper = r'\"%HELPER%\"';
    final script =
        '''@echo off\r
setlocal\r
set "HELPER=$batchHelperPath"\r
set "STATUS=$batchStatusPath"\r
sc.exe query "$appHelperService" >nul 2>&1 || goto create_service\r
sc.exe stop "$appHelperService" >nul 2>&1\r
if errorlevel 1 (\r
  sc.exe query "$appHelperService" | findstr /R /C:"STATE.*: 1" >nul || goto fail_stop\r
)\r
for /L %%I in (1,1,20) do (\r
  sc.exe query "$appHelperService" | findstr /R /C:"STATE.*: 1" >nul && goto delete_service\r
  timeout /t 1 /nobreak >nul\r
)\r
goto fail_stop\r
:delete_service\r
sc.exe delete "$appHelperService" >nul 2>&1 || goto fail_delete\r
for /L %%I in (1,1,20) do (\r
  sc.exe query "$appHelperService" >nul 2>&1 || goto create_service\r
  timeout /t 1 /nobreak >nul\r
)\r
goto fail_delete\r
:create_service\r
sc.exe create "$appHelperService" binPath= "$batchQuotedHelper" start= demand DisplayName= "HarborProxy Helper Service" >nul\r
if errorlevel 1 goto fail_create\r
sc.exe start "$appHelperService" >nul\r
if errorlevel 1 goto fail_start\r
>"%STATUS%" echo success\r
exit /b 0\r
:fail_stop\r
>"%STATUS%" echo service_stop_failed\r
exit /b 10\r
:fail_delete\r
>"%STATUS%" echo service_delete_failed\r
exit /b 11\r
:fail_create\r
>"%STATUS%" echo service_create_failed\r
exit /b 12\r
:fail_start\r
>"%STATUS%" echo service_start_failed\r
exit /b 13\r
''';

    final scriptFile = File(scriptPath);
    final statusFile = File(statusPath);
    try {
      await scriptFile.writeAsString(script, flush: true);
      final launched = runas('cmd.exe', '/d /c ""$scriptPath""');
      if (!launched) {
        return AuthorizeCode.uacCancelled;
      }
      String? stage;
      for (var attempt = 0; attempt < 60; attempt++) {
        if (await statusFile.exists()) {
          stage = (await statusFile.readAsString()).trim();
          break;
        }
        await Future<void>.delayed(const Duration(seconds: 1));
      }
      final stageCode = switch (stage) {
        'service_stop_failed' => AuthorizeCode.serviceStopFailed,
        'service_delete_failed' => AuthorizeCode.serviceDeleteFailed,
        'service_create_failed' => AuthorizeCode.serviceCreateFailed,
        'service_start_failed' => AuthorizeCode.serviceStartFailed,
        'success' => null,
        _ => AuthorizeCode.serviceCreateFailed,
      };
      if (stageCode != null) return stageCode;
      final retryStatus = await retry(
        task: checkService,
        maxAttempts: 15,
        retryIf: (value) =>
            value == WindowsHelperServiceStatus.presence ||
            value == WindowsHelperServiceStatus.helperUnreachable,
        delay: const Duration(milliseconds: 500),
      );
      return switch (retryStatus) {
        WindowsHelperServiceStatus.running => AuthorizeCode.success,
        WindowsHelperServiceStatus.imagePathMismatch =>
          AuthorizeCode.imagePathMismatch,
        WindowsHelperServiceStatus.helperUnreachable =>
          AuthorizeCode.helperUnreachable,
        WindowsHelperServiceStatus.helperTokenMismatch =>
          AuthorizeCode.helperTokenMismatch,
        WindowsHelperServiceStatus.coreHashMismatch =>
          AuthorizeCode.coreHashMismatch,
        _ => AuthorizeCode.serviceStartFailed,
      };
    } finally {
      try {
        await scriptFile.delete();
      } catch (_) {}
      try {
        await statusFile.delete();
      } catch (_) {}
    }
  }

  Future<bool> registerTask(String appName) async {
    final taskXml =
        '''
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.3" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <Principals>
    <Principal id="Author">
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Triggers>
    <LogonTrigger/>
  </Triggers>
  <Settings>
    <MultipleInstancesPolicy>Parallel</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>false</AllowHardTerminate>
    <StartWhenAvailable>false</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>false</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT72H</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>"${Platform.resolvedExecutable}"</Command>
    </Exec>
  </Actions>
</Task>''';
    final taskPath = join(await appPath.tempPath, 'task.xml');
    await File(taskPath).create(recursive: true);
    await File(
      taskPath,
    ).writeAsBytes(taskXml.encodeUtf16LeWithBom, flush: true);
    final commandLine = [
      '/Create',
      '/TN',
      appName,
      '/XML',
      '%s',
      '/F',
    ].join(' ');
    return runas('schtasks', commandLine.replaceFirst('%s', taskPath));
  }
}

final windows = system.isWindows ? Windows() : null;

class MacOS {
  static MacOS? _instance;

  List<String>? originDns;

  MacOS._internal();

  factory MacOS() {
    _instance ??= MacOS._internal();
    return _instance!;
  }

  Future<String?> get defaultServiceName async {
    final result = await Process.run('route', ['-n', 'get', 'default']);
    final output = result.stdout.toString();
    final deviceLine = output
        .split('\n')
        .firstWhere((s) => s.contains('interface:'), orElse: () => '');
    final lineSplits = deviceLine.trim().split(' ');
    if (lineSplits.length != 2) {
      return null;
    }
    final device = lineSplits[1];
    final serviceResult = await Process.run('networksetup', [
      '-listnetworkserviceorder',
    ]);
    final serviceResultOutput = serviceResult.stdout.toString();
    final currentService = serviceResultOutput
        .split('\n\n')
        .firstWhere((s) => s.contains('Device: $device'), orElse: () => '');
    if (currentService.isEmpty) {
      return null;
    }
    final currentServiceNameLine = currentService
        .split('\n')
        .firstWhere(
          (line) => RegExp(r'^\(\d+\).*').hasMatch(line),
          orElse: () => '',
        );
    final currentServiceNameLineSplits = currentServiceNameLine.trim().split(
      ' ',
    );
    if (currentServiceNameLineSplits.length < 2) {
      return null;
    }
    return currentServiceNameLineSplits[1];
  }

  Future<List<String>?> get systemDns async {
    final deviceServiceName = await defaultServiceName;
    if (deviceServiceName == null) {
      return null;
    }
    final result = await Process.run('networksetup', [
      '-getdnsservers',
      deviceServiceName,
    ]);
    final output = result.stdout.toString().trim();
    if (output.startsWith("There aren't any DNS Servers set on")) {
      originDns = [];
    } else {
      originDns = output.split('\n');
    }
    return originDns;
  }

  Future<void> updateDns(bool restore) async {
    final serviceName = await defaultServiceName;
    if (serviceName == null) {
      return;
    }
    List<String>? nextDns;
    if (restore) {
      nextDns = originDns;
    } else {
      final originDns = await systemDns;
      if (originDns == null) {
        return;
      }
      const needAddDns = '223.5.5.5';
      if (originDns.contains(needAddDns)) {
        return;
      }
      nextDns = List.from(originDns)..add(needAddDns);
    }
    if (nextDns == null) {
      return;
    }
    await Process.run('networksetup', [
      '-setdnsservers',
      serviceName,
      if (nextDns.isNotEmpty) ...nextDns,
      if (nextDns.isEmpty) 'Empty',
    ]);
  }
}

final macOS = system.isMacOS ? MacOS() : null;
