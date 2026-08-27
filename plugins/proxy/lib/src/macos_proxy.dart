import 'dart:io';

import 'package:flutter/foundation.dart';

import 'proxy_command.dart';

class MacosProxy {
  final ProxyCommandRunner _commandRunner;

  MacosProxy({required ProxyCommandRunner commandRunner})
    : _commandRunner = commandRunner;

  Future<bool> start(int port, List<String> bypassDomain) async {
    final services = await _networkServices();
    if (services.isEmpty) return false;
    return _commandRunner.run([
      MacosProxyCommands.buildElevated(
        services,
        port: port,
        bypassDomain: bypassDomain,
        enable: true,
      ),
    ]);
  }

  Future<bool> stop() async {
    final services = await _networkServices();
    return stopServices(services);
  }

  @visibleForTesting
  Future<bool> stopServices(List<String> services) async {
    if (services.isEmpty) return false;
    final enabled = await _proxyIsEnabled(services);
    if (enabled == false) return true;
    return _commandRunner.run([
      MacosProxyCommands.buildElevated(
        services,
        port: 0,
        bypassDomain: const [],
        enable: false,
      ),
    ]);
  }

  Future<bool?> _proxyIsEnabled(List<String> services) async {
    const queries = [
      '-getwebproxy',
      '-getsecurewebproxy',
      '-getsocksfirewallproxy',
      '-getautoproxyurl',
    ];
    try {
      for (final service in services) {
        for (final query in queries) {
          final result = await _commandRunner.process(
            '/usr/sbin/networksetup',
            [query, service],
          );
          if (result.exitCode != 0) return null;
          if (MacosProxyCommands.parseEnabled(result.stdout.toString())) {
            return true;
          }
        }
      }
      return false;
    } on ProcessException {
      return null;
    }
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

  static bool parseEnabled(String stdout) => stdout.split('\n').any(
    (line) => line.trim().toLowerCase() == 'enabled: yes',
  );

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
        .expand(
          (service) => buildStart(service, port, bypassDomain),
        )
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
