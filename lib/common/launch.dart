import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'constant.dart';
import 'system.dart';

class AutoLaunch {
  final String platform;
  final String executable;
  final Map<String, String> environment;
  final Future<ProcessResult> Function(
    String,
    List<String>, {
    Map<String, String>? environment,
  })
  runProcess;

  AutoLaunch({
    String? platform,
    String? executable,
    Map<String, String>? environment,
    this.runProcess = Process.run,
  }) : platform = platform ?? Platform.operatingSystem,
       executable = executable ?? Platform.resolvedExecutable,
       environment = environment ?? Platform.environment;

  static const _channel = MethodChannel('launch_at_startup');

  File get desktopFile {
    final xdg = environment['XDG_CONFIG_HOME'];
    final config = xdg != null && p.isAbsolute(xdg)
        ? xdg
        : p.join(environment['HOME']!, '.config');
    return File(p.join(config, 'autostart', '$appName.desktop'));
  }

  String get desktopEntry {
    final quoted = executable
        .replaceAll(r'\', r'\\')
        .replaceAll('"', r'\"')
        .replaceAll(r'$', r'\$')
        .replaceAll('`', r'\`')
        .replaceAll('%', '%%')
        .replaceAll(r'\', r'\\');
    return '[Desktop Entry]\nType=Application\nName=$appName\n'
        'Exec="$quoted"\nTerminal=false\n';
  }

  Future<bool> get isEnable async {
    switch (platform) {
      case 'linux':
        final file = desktopFile;
        return await file.exists() && await file.readAsString() == desktopEntry;
      case 'windows':
        return _windows('query');
      case 'macos':
        return await _channel.invokeMethod<bool>('launchAtStartupIsEnabled') ??
            false;
      default:
        throw UnsupportedError('auto launch: $platform');
    }
  }

  Future<void> updateStatus(bool enabled) async {
    switch (platform) {
      case 'linux':
        final file = desktopFile;
        if (enabled) {
          await file.parent.create(recursive: true);
          await file.writeAsString(desktopEntry, flush: true);
        } else if (await file.exists()) {
          await file.delete();
        }
      case 'windows':
        await _windows(enabled ? 'enable' : 'disable');
      case 'macos':
        final accepted = await _channel.invokeMethod<bool>(
          'launchAtStartupSetEnabled',
          {'setEnabledValue': enabled},
        );
        if (accepted != true) {
          throw StateError('auto launch registration failed');
        }
      default:
        throw UnsupportedError('auto launch: $platform');
    }
    if (await isEnable != enabled) {
      throw StateError('auto launch state mismatch');
    }
  }

  Future<bool> _windows(String operation) async {
    final script = base64Encode([
      for (final unit in windowsScript.codeUnits) ...[unit & 255, unit >> 8],
    ]);
    final result = await runProcess(
      p.windows.join(
        environment['SystemRoot']!,
        r'System32\WindowsPowerShell\v1.0\powershell.exe',
      ),
      ['-NoProfile', '-NonInteractive', '-EncodedCommand', script],
      environment: {
        'HARBORPROXY_STARTUP_OPERATION': operation,
        'HARBORPROXY_STARTUP_EXE': executable,
      },
    );
    if (result.exitCode != 0) {
      throw ProcessException(
        'auto launch',
        [],
        '${result.stderr}',
        result.exitCode,
      );
    }
    return result.stdout.toString().trim() == 'True';
  }

  // A Run key cannot launch our requireAdministrator GUI at sign-in.
  static const windowsScript = r'''
$ErrorActionPreference = 'Stop'
$sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$name = "HarborProxy-$sid"
$exe = $env:HARBORPROXY_STARTUP_EXE
$operation = $env:HARBORPROXY_STARTUP_OPERATION
if ($operation -eq 'enable') {
  $action = New-ScheduledTaskAction -Execute $exe -WorkingDirectory ([IO.Path]::GetDirectoryName($exe))
  $trigger = New-ScheduledTaskTrigger -AtLogOn -User $sid
  $principal = New-ScheduledTaskPrincipal -UserId $sid -LogonType Interactive -RunLevel Highest
  $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero)
  Register-ScheduledTask -TaskName $name -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
} elseif ($operation -eq 'disable') {
  if (Get-ScheduledTask -TaskPath '\' | Where-Object TaskName -EQ $name) {
    Unregister-ScheduledTask -TaskName $name -Confirm:$false
  }
}
$task = Get-ScheduledTask -TaskPath '\' | Where-Object TaskName -EQ $name
$enabled = $false
if ($null -ne $task) {
  [xml]$xml = Export-ScheduledTask -TaskName $name
  $principal = $xml.Task.Principals.Principal
  $trigger = $xml.Task.Triggers.LogonTrigger
  $triggerSid = ([System.Security.Principal.NTAccount]::new($trigger.UserId)).Translate([System.Security.Principal.SecurityIdentifier]).Value
  $enabled = $task.Settings.Enabled -and $task.Actions.Count -eq 1 -and $task.Actions[0].Execute -eq $exe -and [string]::IsNullOrEmpty($task.Actions[0].Arguments) -and $principal.UserId -eq $sid -and $principal.LogonType -eq 'InteractiveToken' -and $principal.RunLevel -eq 'HighestAvailable' -and $task.Triggers.Count -eq 1 -and $triggerSid -eq $sid -and $task.Triggers[0].Enabled
}
if (($operation -eq 'enable' -and $enabled) -or ($operation -eq 'disable' -and $null -eq $task)) {
  foreach ($key in @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Run', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run')) {
    if (Test-Path $key) { Remove-ItemProperty -Path $key -Name HarborProxy -ErrorAction SilentlyContinue }
  }
}
Write-Output ([bool]$enabled)
''';
}

final autoLaunch = system.isDesktop ? AutoLaunch() : null;
