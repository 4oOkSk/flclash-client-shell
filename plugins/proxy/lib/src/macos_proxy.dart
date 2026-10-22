import 'dart:io';

import 'package:flutter/foundation.dart';

import 'proxy_command.dart';
import 'proxy_ownership.dart';

class MacosProxy {
  final ProxyCommandRunner _commandRunner;
  final ProxyOwnershipStore _ownership;

  MacosProxy({
    required ProxyCommandRunner commandRunner,
    ProxyOwnershipStore? ownership,
  }) : _commandRunner = commandRunner,
       _ownership = ownership ?? ProxyOwnershipStore();

  Future<bool> start(int port, List<String> bypassDomain) async {
    if (!await stop()) return false;
    final services = await _networkServices();
    if (services.isEmpty) return false;
    try {
      final snapshots = <String, dynamic>{};
      for (final service in services) {
        final state = await _snapshot(service);
        if ((state['manual'] as List).any(
          (proxy) => (proxy as Map)['authenticated'] == true,
        )) {
          return false; // networksetup cannot recover a corporate proxy password.
        }
        snapshots[service] = state;
      }
      await _ownership.write({
        'platform': 'macos',
        'port': port,
        'bypass': bypassDomain,
        'services': snapshots,
      });
      final restore = [
        for (final service in services)
          ..._restoreCommands(
            service,
            Map<String, dynamic>.from(snapshots[service] as Map),
          ),
      ];
      final success = await _commandRunner.run([
        MacosProxyCommands.buildElevatedCommands([
          for (final service in services)
            ...MacosProxyCommands.buildStart(service, port, bypassDomain),
        ], rollback: restore),
      ]);
      if (!success) {
        await stop();
        return false;
      }
      for (final service in services) {
        if (!_isOwned(await _snapshot(service), port, bypassDomain)) {
          await stop();
          return false;
        }
      }
      return true;
    } on Object {
      await stop();
      return false;
    }
  }

  Future<bool> stop() async {
    return stopServices(const []);
  }

  @visibleForTesting
  Future<bool> stopServices(List<String> services) async {
    try {
      final journal = await _ownership.read();
      if (journal.isEmpty) {
        return true; // Startup never clears somebody else's proxy.
      }
      if (journal['platform'] != 'macos') return false;
      final port = journal['port'] as int;
      if (port < 1 || port > 65535) return false;
      final bypass = List<String>.from(journal['bypass'] as List);
      final snapshots = Map<String, dynamic>.from(journal['services'] as Map);
      final commands = <ProxyCommand>[];
      final expected = <String, Map<String, dynamic>>{};
      for (final entry in snapshots.entries) {
        final current = await _snapshot(entry.key);
        final original = Map<String, dynamic>.from(entry.value as Map);
        final manual = current['manual'] as List;
        final previous = original['manual'] as List;
        final target = Map<String, dynamic>.from(current);
        final targetManual = [
          for (final proxy in manual) Map<String, dynamic>.from(proxy as Map),
        ];
        var endpointsUnchanged = true;
        for (var i = 0; i < 3; i++) {
          final value = manual[i] as Map;
          final old = previous[i] as Map;
          final safe =
              value['authenticated'] != true &&
              ((value['enabled'] == true &&
                      value['server'] == proxyHost &&
                      value['port'] == port) ||
                  (value['enabled'] == old['enabled'] &&
                      value['server'] == old['server'] &&
                      value['port'] == old['port']));
          endpointsUnchanged = endpointsUnchanged && safe;
          if (!safe) continue;
          targetManual[i] = Map<String, dynamic>.from(old);
          commands.addAll(_restoreManual(entry.key, i, old));
        }
        target['manual'] = targetManual;
        if (endpointsUnchanged) {
          // A newly selected external manual proxy must not be displaced by an old PAC.
          if (current['pacEnabled'] == false &&
              current['pacUrl'] == original['pacUrl']) {
            target['pacEnabled'] = original['pacEnabled'];
            commands.add(
              ProxyCommand('/usr/sbin/networksetup', [
                '-setautoproxystate',
                entry.key,
                original['pacEnabled'] == true ? 'on' : 'off',
              ]),
            );
          }
          if (current['discovery'] == false) {
            target['discovery'] = original['discovery'];
            commands.add(
              ProxyCommand('/usr/sbin/networksetup', [
                '-setproxyautodiscovery',
                entry.key,
                original['discovery'] == true ? 'on' : 'off',
              ]),
            );
          }
        }
        if (listEquals(List<String>.from(current['bypass'] as List), bypass)) {
          target['bypass'] = original['bypass'];
          commands.add(
            MacosProxyCommands.buildProxyBypass(
              entry.key,
              List<String>.from(original['bypass'] as List),
            ),
          );
        }
        expected[entry.key] = target;
        // An externally replaced endpoint/policy is not ours to undo.
      }
      if (commands.isNotEmpty &&
          !await _commandRunner.run([
            MacosProxyCommands.buildElevatedCommands(commands),
          ])) {
        return false;
      }
      for (final entry in expected.entries) {
        if (!_sameState(await _snapshot(entry.key), entry.value)) return false;
      }
      await _ownership.write({});
      return true;
    } on Object {
      return false;
    }
  }

  Future<Map<String, dynamic>> _snapshot(String service) async {
    Future<String> query(String option) async {
      final result = await _commandRunner.process('/usr/sbin/networksetup', [
        option,
        service,
      ]);
      if (result.exitCode != 0) {
        throw const FormatException('Unable to read system proxy');
      }
      return result.stdout.toString();
    }

    Map<String, String> fields(String text) => {
      for (final line in text.split('\n'))
        if (line.contains(':'))
          line.substring(0, line.indexOf(':')).trim(): line
              .substring(line.indexOf(':') + 1)
              .trim(),
    };
    final manual = <Map<String, dynamic>>[];
    for (final option in [
      '-getwebproxy',
      '-getsecurewebproxy',
      '-getsocksfirewallproxy',
    ]) {
      final value = fields(await query(option));
      if (!['Yes', 'No'].contains(value['Enabled']) ||
          value['Server'] == null ||
          int.tryParse(value['Port'] ?? '') == null) {
        throw const FormatException('Invalid proxy state');
      }
      manual.add({
        'enabled': value['Enabled'] == 'Yes',
        'server': value['Server'] ?? '',
        'port': int.tryParse(value['Port'] ?? '') ?? 0,
        'authenticated': value['Authenticated Proxy Enabled'] == '1',
      });
    }
    final pac = fields(await query('-getautoproxyurl'));
    final discovery = fields(await query('-getproxyautodiscovery'));
    if (!['Yes', 'No'].contains(pac['Enabled']) ||
        pac['URL'] == null ||
        !discovery.values.any((v) => ['On', 'Off', 'Yes', 'No'].contains(v))) {
      throw const FormatException('Invalid automatic proxy state');
    }
    final bypass = (await query('-getproxybypassdomains')).trim();
    return {
      'manual': manual,
      'pacEnabled': pac['Enabled'] == 'Yes',
      'pacUrl': pac['URL'] ?? '',
      'discovery': discovery.values.any((v) => v == 'On' || v == 'Yes'),
      'bypass': bypass.startsWith("There aren't") || bypass.isEmpty
          ? <String>[]
          : bypass.split('\n'),
    };
  }

  bool _isOwned(Map<String, dynamic> state, int port, List<String> bypass) {
    final manual = state['manual'] as List;
    return manual.length == 3 &&
        manual.every((value) {
          final proxy = value as Map;
          return proxy['enabled'] == true &&
              proxy['server'] == proxyHost &&
              proxy['port'] == port;
        }) &&
        state['pacEnabled'] == false &&
        state['discovery'] == false &&
        listEquals(List<String>.from(state['bypass'] as List), bypass);
  }

  List<ProxyCommand> _restoreCommands(
    String service,
    Map<String, dynamic> state,
  ) {
    final result = <ProxyCommand>[];
    final manual = state['manual'] as List;
    for (var i = 0; i < 3; i++) {
      result.addAll(_restoreManual(service, i, manual[i] as Map));
    }
    if ((state['pacUrl'] as String).isNotEmpty) {
      result.add(
        ProxyCommand('/usr/sbin/networksetup', [
          '-setautoproxyurl',
          service,
          state['pacUrl'] as String,
        ]),
      );
    }
    result.addAll([
      ProxyCommand('/usr/sbin/networksetup', [
        '-setautoproxystate',
        service,
        state['pacEnabled'] == true ? 'on' : 'off',
      ]),
      ProxyCommand('/usr/sbin/networksetup', [
        '-setproxyautodiscovery',
        service,
        state['discovery'] == true ? 'on' : 'off',
      ]),
      MacosProxyCommands.buildProxyBypass(
        service,
        List<String>.from(state['bypass'] as List),
      ),
    ]);
    return result;
  }

  List<ProxyCommand> _restoreManual(String service, int index, Map value) {
    const setters = [
      '-setwebproxy',
      '-setsecurewebproxy',
      '-setsocksfirewallproxy',
    ];
    const switches = [
      '-setwebproxystate',
      '-setsecurewebproxystate',
      '-setsocksfirewallproxystate',
    ];
    return [
      if ((value['server'] as String).isNotEmpty && (value['port'] as int) > 0)
        ProxyCommand('/usr/sbin/networksetup', [
          setters[index],
          service,
          value['server'] as String,
          '${value['port']}',
        ]),
      ProxyCommand('/usr/sbin/networksetup', [
        switches[index],
        service,
        value['enabled'] == true ? 'on' : 'off',
      ]),
    ];
  }

  bool _sameState(Map<String, dynamic> actual, Map<String, dynamic> expected) {
    for (var i = 0; i < 3; i++) {
      final a = (actual['manual'] as List)[i] as Map;
      final e = (expected['manual'] as List)[i] as Map;
      if (a['enabled'] != e['enabled'] ||
          a['authenticated'] != e['authenticated']) {
        return false;
      }
      if (e['server'] != '' &&
          (a['server'] != e['server'] || a['port'] != e['port'])) {
        return false;
      }
    }
    return actual['pacEnabled'] == expected['pacEnabled'] &&
        actual['pacUrl'] == expected['pacUrl'] &&
        actual['discovery'] == expected['discovery'] &&
        listEquals(
          List<String>.from(actual['bypass'] as List),
          List<String>.from(expected['bypass'] as List),
        );
  }

  Future<List<String>> _networkServices() async {
    try {
      final result = await _commandRunner.process('/usr/sbin/networksetup', [
        '-listallnetworkservices',
      ]);
      if (result.exitCode != 0) {
        return [];
      }
      return MacosProxyCommands.parseNetworkServices(result.stdout.toString());
    } on ProcessException {
      return [];
    }
  }
}

class MacosProxyCommands {
  static List<ProxyCommand> buildStart(
    String service,
    int port,
    List<String> bypassDomain,
  ) {
    return [
      ProxyCommand('/usr/sbin/networksetup', [
        '-setproxyautodiscovery',
        service,
        'off',
      ]),
      ProxyCommand('/usr/sbin/networksetup', [
        '-setautoproxystate',
        service,
        'off',
      ]),
      ProxyCommand('/usr/sbin/networksetup', [
        '-setwebproxy',
        service,
        proxyHost,
        '$port',
      ]),
      ProxyCommand('/usr/sbin/networksetup', [
        '-setsecurewebproxy',
        service,
        proxyHost,
        '$port',
      ]),
      ProxyCommand('/usr/sbin/networksetup', [
        '-setsocksfirewallproxy',
        service,
        proxyHost,
        '$port',
      ]),
      buildProxyBypass(service, bypassDomain),
      ProxyCommand('/usr/sbin/networksetup', [
        '-setwebproxystate',
        service,
        'on',
      ]),
      ProxyCommand('/usr/sbin/networksetup', [
        '-setsecurewebproxystate',
        service,
        'on',
      ]),
      ProxyCommand('/usr/sbin/networksetup', [
        '-setsocksfirewallproxystate',
        service,
        'on',
      ]),
    ];
  }

  static List<ProxyCommand> buildStop(String service) {
    return [
      ProxyCommand('/usr/sbin/networksetup', [
        '-setautoproxystate',
        service,
        'off',
      ]),
      ProxyCommand('/usr/sbin/networksetup', [
        '-setwebproxystate',
        service,
        'off',
      ]),
      ProxyCommand('/usr/sbin/networksetup', [
        '-setsecurewebproxystate',
        service,
        'off',
      ]),
      ProxyCommand('/usr/sbin/networksetup', [
        '-setsocksfirewallproxystate',
        service,
        'off',
      ]),
      buildProxyBypass(service, const []),
    ];
  }

  static ProxyCommand buildProxyBypass(
    String service,
    List<String> bypassDomain,
  ) {
    return ProxyCommand('/usr/sbin/networksetup', [
      '-setproxybypassdomains',
      service,
      if (bypassDomain.isEmpty) 'Empty' else ...bypassDomain,
    ]);
  }

  static List<String> parseNetworkServices(String stdout) {
    return stdout
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .where((line) => !line.startsWith('*'))
        .where((line) => !line.startsWith('An asterisk '))
        .toList();
  }

  static bool parseEnabled(String stdout) => stdout
      .split('\n')
      .any((line) => line.trim().toLowerCase() == 'enabled: yes');

  static ProxyCommand buildElevated(
    List<String> services, {
    required int port,
    required List<String> bypassDomain,
    required bool enable,
  }) {
    final shell = buildShell(
      services,
      port: port,
      bypassDomain: bypassDomain,
      enable: enable,
    );
    return ProxyCommand('/usr/bin/osascript', [
      '-e',
      'do shell script "${_escapeAppleScript(shell)}" with administrator privileges',
    ]);
  }

  static ProxyCommand buildElevatedCommands(
    List<ProxyCommand> commands, {
    List<ProxyCommand> rollback = const [],
  }) {
    final cleanup = rollback
        .map(_shellCommand)
        .map((command) => '$command || true')
        .join('; ');
    final shell = [
      'set -e',
      if (rollback.isNotEmpty)
        'cleanup() { code=\$?; trap - EXIT; if [ "\$code" -ne 0 ]; then $cleanup; fi; exit "\$code"; }',
      if (rollback.isNotEmpty) 'trap cleanup EXIT',
      ...commands.map(_shellCommand),
      'trap - EXIT',
    ].join('; ');
    return ProxyCommand('/usr/bin/osascript', [
      '-e',
      'do shell script "${_escapeAppleScript(shell)}" with administrator privileges',
    ]);
  }

  static String buildShell(
    List<String> services, {
    required int port,
    required List<String> bypassDomain,
    required bool enable,
  }) {
    final stopCommands = services
        .expand(buildStop)
        .map(_shellCommand)
        .toList(growable: false);
    if (!enable) {
      return <String>[
        'status=0',
        ...stopCommands.map((command) => '$command || status=1'),
        'exit "\$status"',
      ].join('; ');
    }
    final startCommands = services
        .expand((service) => buildStart(service, port, bypassDomain))
        .map(_shellCommand)
        .toList(growable: false);
    final rollback = stopCommands
        .map((command) => '$command || true')
        .join('; ');
    return <String>[
      'set -e',
      'cleanup() { code=\$?; trap - EXIT; if [ "\$code" -ne 0 ]; then $rollback; fi; exit "\$code"; }',
      'trap cleanup EXIT',
      ...startCommands,
      'trap - EXIT',
    ].join('; ');
  }

  static String _shellCommand(ProxyCommand command) => <String>[
    _shellQuote(command.executable),
    ...command.args.map(_shellQuote),
  ].join(' ');

  static String _shellQuote(String value) =>
      "'${value.replaceAll("'", "'\\''")}'";

  static String _escapeAppleScript(String value) =>
      value.replaceAll('\\', '\\\\').replaceAll('"', '\\"');
}
