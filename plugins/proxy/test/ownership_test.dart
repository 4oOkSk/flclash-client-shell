import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxy/src/linux_proxy.dart';
import 'package:proxy/src/macos_proxy.dart';
import 'package:proxy/src/proxy_command.dart';
import 'package:proxy/src/proxy_ownership.dart';

void main() {
  test('Linux startup stop leaves an external proxy alone', () async {
    final proxy = LinuxProxy(
      commandRunner: ProxyCommandRunner((_, _, {runInShell = false}) async {
        fail('no owned journal means no system command');
      }),
    );
    expect(await proxy.stop(desktop: 'GNOME', homeDir: '/home/test'), isTrue);
  });

  for (final externalChange in [false, true]) {
    test(
      'GNOME restores owned fields; external change=$externalChange',
      () async {
        final state = <String, String>{
          'org.gnome.system.proxy/mode': "'auto'",
          'org.gnome.system.proxy/ignore-hosts': "['corporate.local']",
          for (final kind in ['http', 'https', 'socks']) ...{
            'org.gnome.system.proxy.$kind/host': "'corporate.local'",
            'org.gnome.system.proxy.$kind/port': '8080',
          },
        };
        final original = Map<String, String>.from(state);
        final proxy = LinuxProxy(
          executableChecker: (_) async => true,
          commandRunner: ProxyCommandRunner((
            _,
            args, {
            runInShell = false,
          }) async {
            final key = '${args[1]}/${args[2]}';
            if (args[0] == 'get') {
              return ProcessResult(1, 0, '${state[key]}\n', '');
            }
            var value = args[3];
            if (['host', 'mode'].contains(args[2]) && !value.startsWith("'")) {
              value = "'$value'";
            }
            state[key] = value;
            return ProcessResult(1, 0, '', '');
          }),
        );
        expect(
          await proxy.start(
            7890,
            ['localhost'],
            desktop: 'GNOME',
            homeDir: '/home/test',
          ),
          isTrue,
        );
        if (externalChange) {
          state['org.gnome.system.proxy.https/host'] = "'another.proxy'";
        }
        // Restore the recorded backend, not a newly selected desktop environment.
        expect(await proxy.stop(desktop: 'KDE', homeDir: '/home/test'), isTrue);
        if (!externalChange) {
          expect(state, original);
        } else {
          expect(state['org.gnome.system.proxy.https/host'], "'another.proxy'");
          expect(state['org.gnome.system.proxy.https/port'], '7890');
          expect(state['org.gnome.system.proxy/mode'], "'manual'");
          expect(
            state['org.gnome.system.proxy.http/host'],
            "'corporate.local'",
          );
        }
      },
    );
  }

  test(
    'proxy recovery journal survives a new store instance',
    () async {
      final directory = await Directory.systemTemp.createTemp('proxy-test-');
      try {
        final file = File('${directory.path}/journal.json');
        await ProxyOwnershipStore(
          Future.value(file),
        ).write({'platform': 'linux', 'entries': []});
        expect(await ProxyOwnershipStore(Future.value(file)).read(), {
          'platform': 'linux',
          'entries': [],
        });
        await ProxyOwnershipStore(Future.value(file)).write({});
        expect(await ProxyOwnershipStore(Future.value(file)).read(), isEmpty);
      } finally {
        await directory.delete(recursive: true);
      }
    },
    skip: Platform.isWindows,
  );

  for (final change in ['none', 'endpoint', 'switch', 'split-endpoint']) {
    final externalChange = change == 'endpoint';
    final externalSwitch = change == 'switch';
    final splitEndpoint = change == 'split-endpoint';
    test('macOS preserves external proxy changes: $change', () async {
      Map<String, dynamic> manual(String server, int port, bool enabled) => {
        'server': server,
        'port': port,
        'enabled': enabled,
        'authenticated': false,
      };
      final original = <String, dynamic>{
        'manual': [
          for (var i = 0; i < 3; i++)
            manual('corporate.local', 8080, externalSwitch),
        ],
        'pacEnabled': true,
        'pacUrl': 'https://corporate.local/proxy.pac',
        'discovery': true,
        'bypass': ['corporate.local'],
      };
      var current = <String, dynamic>{
        ...original,
        'manual': [
          for (var i = 0; i < 3; i++)
            manual(
              i == 1 && externalChange ? 'external.local' : '127.0.0.1',
              i == 1 && splitEndpoint ? 8080 : 7890,
              !(i == 0 && externalSwitch),
            ),
        ],
        'pacEnabled': false,
        'discovery': false,
        'bypass': ['localhost'],
      };
      final expected = <String, dynamic>{
        ...original,
        if (externalChange || externalSwitch || splitEndpoint) ...{
          'manual': [
            externalSwitch
                ? manual('127.0.0.1', 7890, false)
                : manual('corporate.local', 8080, false),
            externalSwitch
                ? manual('corporate.local', 8080, true)
                : manual(
                    externalChange ? 'external.local' : '127.0.0.1',
                    splitEndpoint ? 8080 : 7890,
                    true,
                  ),
            manual('corporate.local', 8080, externalSwitch),
          ],
          'pacEnabled': false,
          'discovery': false,
        },
      };
      final store = ProxyOwnershipStore();
      await store.write({
        'platform': 'macos',
        'port': 7890,
        'bypass': ['localhost'],
        'services': {'USB 10/100/1000 LAN': original},
      });
      var writes = 0;
      final proxy = MacosProxy(
        ownership: store,
        commandRunner: ProxyCommandRunner((
          executable,
          args, {
          runInShell = false,
        }) async {
          if (executable == '/usr/bin/osascript') {
            writes++;
            expect(args.last, contains('USB 10/100/1000 LAN'));
            if (externalChange || splitEndpoint) {
              expect(args.last, isNot(contains('-setsecurewebproxy')));
            }
            if (externalSwitch) {
              expect(args.last, isNot(contains('-setwebproxy')));
            }
            if (externalChange || externalSwitch || splitEndpoint) {
              expect(args.last, isNot(contains('-setautoproxystate')));
              expect(args.last, isNot(contains('-setproxyautodiscovery')));
            }
            current = expected;
            return ProcessResult(1, 0, '', '');
          }
          expect(args[1], 'USB 10/100/1000 LAN');
          final index = [
            '-getwebproxy',
            '-getsecurewebproxy',
            '-getsocksfirewallproxy',
          ].indexOf(args[0]);
          if (index >= 0) {
            final value = (current['manual'] as List)[index] as Map;
            return ProcessResult(
              1,
              0,
              'Enabled: ${value['enabled'] == true ? 'Yes' : 'No'}\nServer: ${value['server']}\nPort: ${value['port']}\nAuthenticated Proxy Enabled: 0\n',
              '',
            );
          }
          final text = switch (args[0]) {
            '-getautoproxyurl' =>
              'Enabled: ${current['pacEnabled'] == true ? 'Yes' : 'No'}\nURL: ${current['pacUrl']}\n',
            '-getproxyautodiscovery' =>
              'Auto Proxy Discovery: ${current['discovery'] == true ? 'On' : 'Off'}\n',
            '-getproxybypassdomains' => (current['bypass'] as List).join('\n'),
            _ => throw StateError('unexpected command'),
          };
          return ProcessResult(1, 0, text, '');
        }),
      );
      expect(await proxy.stopServices(['Wi-Fi']), true);
      expect(writes, 1);
      expect(await store.read(), isEmpty);
    });
  }
}
