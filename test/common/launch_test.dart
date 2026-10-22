import 'dart:io';

import 'package:fl_clash/common/launch.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'Linux uses XDG, quotes Exec, refreshes paths and rejects stale entries',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'harborproxy-startup-',
      );
      addTearDown(() => root.delete(recursive: true));
      final launch = AutoLaunch(
        platform: 'linux',
        executable: '/a path/HarborProxy',
        environment: {
          'HOME': '${root.path}/home',
          'XDG_CONFIG_HOME': '${root.path}/xdg',
        },
      );
      expect(await launch.isEnable, false);
      await launch.updateStatus(true);
      expect(await launch.isEnable, true);
      expect(
        await launch.desktopFile.readAsString(),
        contains('Exec="/a path/HarborProxy"'),
      );
      expect(await Directory('${root.path}/home').exists(), false);
      await launch.desktopFile.writeAsString(
        '${launch.desktopEntry}Hidden=true\n',
      );
      expect(await launch.isEnable, false);
      await launch.updateStatus(true);
      final moved = AutoLaunch(
        platform: 'linux',
        executable: '/new/HarborProxy',
        environment: launch.environment,
      );
      expect(await moved.isEnable, false);
      await moved.updateStatus(true);
      expect(await moved.isEnable, true);
      await moved.updateStatus(false);
      expect(await moved.isEnable, false);
    },
  );

  test(
    'Linux escapes desktop Exec reserved characters and falls back from relative XDG',
    () {
      final launch = AutoLaunch(
        platform: 'linux',
        executable: '/path/with "quotes"/100%/\$app',
        environment: {'HOME': '/home/user', 'XDG_CONFIG_HOME': 'relative'},
      );
      expect(
        launch.desktopFile.path,
        '/home/user/.config/autostart/HarborProxy.desktop',
      );
      expect(
        launch.desktopEntry,
        contains(r'Exec="/path/with \\"quotes\\"/100%%/\\$app"'),
      );
    },
  );

  const channel = MethodChannel('launch_at_startup');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));
  test('Mac waits for native acknowledgment and checks actual state', () async {
    var enabled = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'launchAtStartupIsEnabled') return enabled;
      enabled = (call.arguments as Map)['setEnabledValue'] as bool;
      return true;
    });
    final launch = AutoLaunch(platform: 'macos');
    await launch.updateStatus(true);
    expect(await launch.isEnable, true);
    await launch.updateStatus(false);
    expect(await launch.isEnable, false);
  });
  test(
    'Mac rejection and success acknowledgment with unchanged state both fail',
    () async {
      final launch = AutoLaunch(platform: 'macos');
      for (final accepted in [false, true]) {
        messenger.setMockMethodCallHandler(
          channel,
          (call) async =>
              call.method == 'launchAtStartupIsEnabled' ? false : accepted,
        );
        await expectLater(launch.updateStatus(true), throwsStateError);
      }
    },
  );
  test(
    'Windows waits for task registration and readback; never uses Run to enable',
    () async {
      final calls = <String>[];
      final launch = AutoLaunch(
        platform: 'windows',
        executable: r'C:\a path\HarborProxy.exe',
        environment: {'SystemRoot': r'C:\Windows'},
        runProcess: (command, args, {environment}) async {
          expect(
            command,
            r'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe',
          );
          expect(args, contains('-EncodedCommand'));
          expect(
            environment!['HARBORPROXY_STARTUP_EXE'],
            r'C:\a path\HarborProxy.exe',
          );
          calls.add(environment['HARBORPROXY_STARTUP_OPERATION']!);
          return ProcessResult(1, 0, 'True\r\n', '');
        },
      );
      await launch.updateStatus(true);
      expect(calls, ['enable', 'query']);
      expect(
        AutoLaunch.windowsScript,
        contains('-LogonType Interactive -RunLevel Highest'),
      );
      expect(AutoLaunch.windowsScript, isNot(contains('Set-ItemProperty')));
    },
  );
  test('Windows command failure is not reported as enabled', () async {
    final launch = AutoLaunch(
      platform: 'windows',
      environment: {'SystemRoot': r'C:\Windows'},
      runProcess: (_, _, {environment}) async =>
          ProcessResult(1, 5, '', 'denied'),
    );
    await expectLater(
      launch.updateStatus(true),
      throwsA(isA<ProcessException>()),
    );
  });
}
