import 'dart:io';

import 'package:fl_clash/common/system.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late MacOS mac;
  var device = 'en0';
  late Map<String, List<String>> dns;
  setUp(() {
    device = 'en0';
    dns = {
      'Wi-Fi': ['1.1.1.1'],
      'USB 10/100/1000 LAN': ['8.8.8.8'],
    };
    mac = MacOS.forTesting((command, args) async {
      String output;
      if (command == 'route') {
        output = ' interface: $device\n';
      } else if (args.first == '-listnetworkserviceorder') {
        output =
            '(1) Wi-Fi\n(Hardware Port: Wi-Fi, Device: en0)\n\n'
            '(2) USB 10/100/1000 LAN\n(Hardware Port: USB, Device: en5)\n';
      } else if (args.first == '-getdnsservers') {
        output = dns[args[1]]!.isEmpty
            ? "There aren't any DNS Servers set on ${args[1]}"
            : dns[args[1]]!.join('\n');
      } else {
        dns[args[1]] = args[2] == 'Empty' ? [] : args.sublist(2);
        output = '';
      }
      return ProcessResult(0, 0, output, '');
    });
  });

  test('full multiword service names survive parsing', () async {
    device = 'en5';
    expect(await mac.defaultServiceName, 'USB 10/100/1000 LAN');
  });

  test(
    'restore targets the services actually modified, not the current default',
    () async {
      await mac.updateDns(false);
      device = 'en5';
      await mac.updateDns(false);
      await mac.updateDns(true);
      expect(dns, {
        'Wi-Fi': ['1.1.1.1'],
        'USB 10/100/1000 LAN': ['8.8.8.8'],
      });
    },
  );

  test('an external DNS change is preserved on stop', () async {
    await mac.updateDns(false);
    dns['Wi-Fi'] = ['9.9.9.9'];
    await mac.updateDns(true);
    expect(dns['Wi-Fi'], ['9.9.9.9']);
  });
}
