import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxy/proxy.dart';

void main() {
  group('Linux proxy command builders', () {
    test('builds GNOME commands without duplicate port writes', () {
      final commands = Proxy.buildLinuxStartCommandsForTest(
        port: 7890,
        bypassDomain: ['localhost', '127.0.0.1'],
        desktop: 'GNOME',
        homeDir: '/home/user',
      );

      final portCommands = commands.where(
        (command) => command.args.length == 4 && command.args[2] == 'port',
      );
      final hostCommands = commands.where(
        (command) => command.args.length == 4 && command.args[2] == 'host',
      );

      expect(portCommands, hasLength(3));
      expect(hostCommands, hasLength(3));
      expect(
        commands
            .singleWhere(
              (command) =>
                  command.args.contains('org.gnome.system.proxy') &&
                  command.args.contains('ignore-hosts'),
            )
            .args
            .last,
        "['localhost', '127.0.0.1']",
      );
      expect(commands.last.args, [
        'set',
        'org.gnome.system.proxy',
        'mode',
        'manual',
      ]);
    });
    test('builds empty GNOME ignore-hosts as an empty list', () {
      final commands = Proxy.buildLinuxStartCommandsForTest(
        port: 7890,
        bypassDomain: const [],
        desktop: 'GNOME',
        homeDir: '/home/user',
      );

      expect(
        commands
            .singleWhere(
              (command) =>
                  command.args.contains('org.gnome.system.proxy') &&
                  command.args.contains('ignore-hosts'),
            )
            .args
            .last,
        '[]',
      );
    });

    test('builds MATE commands with MATE proxy schema', () {
      final commands = Proxy.buildLinuxStartCommandsForTest(
        port: 7890,
        bypassDomain: ['localhost'],
        desktop: 'MATE',
        homeDir: '/home/user',
      );

      expect(
        commands.any(
          (command) => command.args.contains('org.mate.system.proxy'),
        ),
        isTrue,
      );
      expect(
        commands.any(
          (command) => command.args.contains('org.gnome.system.proxy'),
        ),
        isFalse,
      );
    });

    test('does not apply GNOME settings to XFCE', () {
      final commands = Proxy.buildLinuxStartCommandsForTest(
        port: 7890,
        bypassDomain: ['localhost'],
        desktop: 'XFCE',
        homeDir: '/home/user',
        availableExecutables: {'gsettings'},
      );

      expect(commands, isEmpty);
    });

    test('prefers kwriteconfig6 for KDE when available', () {
      final commands = Proxy.buildLinuxStartCommandsForTest(
        port: 7890,
        bypassDomain: ['localhost'],
        desktop: 'KDE',
        homeDir: '/home/user',
        availableExecutables: {'kwriteconfig6', 'kwriteconfig5'},
      );

      expect(commands.map((command) => command.executable).toSet(), {
        'kwriteconfig6',
      });
      expect(commands.last.args, containsAllInOrder(['ProxyType', '1']));
    });

    test(
      'falls back to kwriteconfig5 for KDE when kwriteconfig6 is missing',
      () {
        final commands = Proxy.buildLinuxStartCommandsForTest(
          port: 7890,
          bypassDomain: ['localhost'],
          desktop: 'KDE',
          homeDir: '/home/user',
          availableExecutables: {'kwriteconfig5'},
        );

        expect(commands.map((command) => command.executable).toSet(), {
          'kwriteconfig5',
        });
      },
    );

    test('does not guess a backend for unknown desktops', () {
      final commands = Proxy.buildLinuxStartCommandsForTest(
        port: 7890,
        bypassDomain: ['localhost'],
        desktop: 'UNKNOWN',
        homeDir: '/home/user',
        availableExecutables: {'kwriteconfig5'},
      );

      expect(commands, isEmpty);
    });

    test('fails closed when the selected desktop backend is unavailable', () {
      final commands = Proxy.buildLinuxStartCommandsForTest(
        port: 7890,
        bypassDomain: ['localhost'],
        desktop: 'GNOME',
        homeDir: '/home/user',
        availableExecutables: const {},
      );

      expect(commands, isEmpty);
    });
  });

  group('macOS proxy command builders', () {
    test(
      'filters networksetup service list headers, disabled services, and blanks',
      () {
        final services = Proxy.parseMacosNetworkServicesForTest('''
An asterisk (*) denotes that a network service is disabled.
Wi-Fi
*Thunderbolt Bridge
USB 10/100/1000 LAN

''');

        expect(services, ['Wi-Fi', 'USB 10/100/1000 LAN']);
      },
    );

    test('passes bypass domains as separate networksetup arguments', () {
      final command = Proxy.buildMacosProxyBypassCommandForTest('Wi-Fi', [
        'localhost',
        '127.0.0.1',
      ]);

      expect(command.executable, '/usr/sbin/networksetup');
      expect(command.args, [
        '-setproxybypassdomains',
        'Wi-Fi',
        'localhost',
        '127.0.0.1',
      ]);
    });

    test('uses Empty when clearing bypass domains', () {
      final command = Proxy.buildMacosProxyBypassCommandForTest(
        'Wi-Fi',
        const [],
      );

      expect(command.args, ['-setproxybypassdomains', 'Wi-Fi', 'Empty']);
    });

    test('parses networksetup enabled state', () {
      expect(
        Proxy.parseMacosProxyEnabledForTest('Enabled: Yes\nServer: 127.0.0.1'),
        isTrue,
      );
      expect(
        Proxy.parseMacosProxyEnabledForTest('Enabled: No\nServer: 127.0.0.1'),
        isFalse,
      );
    });

    test('does not request elevation when every macOS proxy is already off',
        () async {
      final calls = <List<String>>[];
      final proxy = Proxy(
        processRunner: (
          executable,
          arguments, {
          runInShell = false,
        }) async {
          calls.add([executable, ...arguments]);
          return ProcessResult(1, 0, 'Enabled: No\n', '');
        },
      );

      expect(await proxy.stopProxyWithMacosDevicesForTest(['Wi-Fi']), isTrue);
      expect(calls, hasLength(4));
      expect(calls.any((call) => call.first == '/usr/bin/osascript'), isFalse);
    });

    test('uses one elevation when a macOS proxy is enabled', () async {
      final calls = <List<String>>[];
      final proxy = Proxy(
        processRunner: (
          executable,
          arguments, {
          runInShell = false,
        }) async {
          calls.add([executable, ...arguments]);
          final output =
              executable == '/usr/sbin/networksetup' ? 'Enabled: Yes\n' : '';
          return ProcessResult(1, 0, output, '');
        },
      );

      expect(await proxy.stopProxyWithMacosDevicesForTest(['Wi-Fi']), isTrue);
      expect(
        calls.where((call) => call.first == '/usr/bin/osascript'),
        hasLength(1),
      );
    });

    test('uses one elevated command and rolls back a failed start', () {
      final command = Proxy.buildMacosElevatedCommandForTest(
        ["Owner's Wi-Fi", 'USB LAN'],
        port: 7890,
        bypassDomain: ['localhost'],
        enable: true,
      );

      expect(command.executable, '/usr/bin/osascript');
      expect(command.args.first, '-e');
      final script = command.args.last;
      expect(script, contains('with administrator privileges'));
      expect(script, contains('trap cleanup EXIT'));
      expect(script, contains("Owner'\\\\''s Wi-Fi"));
      expect(script, contains('-setwebproxystate'));
      expect(script, contains('off'));
      final startSection = script.indexOf('trap cleanup EXIT');
      final webProxyConfig = script.indexOf("'-setwebproxy'", startSection);
      final webProxyEnable = script.indexOf(
        "'-setwebproxystate'",
        startSection,
      );
      expect(
        webProxyConfig,
        lessThan(webProxyEnable),
      );
    });

    test('attempts all proxy disables in one elevated stop command', () {
      final command = Proxy.buildMacosElevatedCommandForTest(
        ['Wi-Fi'],
        port: 0,
        bypassDomain: const [],
        enable: false,
      );

      final script = command.args.last;
      expect(script, contains('status=0'));
      expect(script, contains('-setautoproxystate'));
      expect(script, contains('-setwebproxystate'));
      expect(script, contains('-setsecurewebproxystate'));
      expect(script, contains('-setsocksfirewallproxystate'));
      expect(script, contains('|| status=1'));
    });

    test('generates POSIX-valid elevated shell bodies', () async {
      for (final enable in [true, false]) {
        final shell = Proxy.buildMacosShellForTest(
          ["Owner's Wi-Fi", 'USB LAN'],
          port: 7890,
          bypassDomain: ['localhost'],
          enable: enable,
        );
        final result = await Process.run('/bin/sh', ['-n', '-c', shell]);
        expect(result.exitCode, 0, reason: result.stderr.toString());
      }
    });
  });
}
