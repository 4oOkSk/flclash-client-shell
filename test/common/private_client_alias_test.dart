import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/views/proxies/private_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'duplicate aliases remain distinct without changing wire identities',
    () {
      const proxies = [
        Proxy(name: 'Backup ', type: 'Vless'),
        Proxy(name: 'Backup', type: 'Vless'),
      ];
      expect(privateClientServerAlias(proxies, 'Backup'), 'Backup · 1');
      expect(
        privateClientServerAlias(proxies.reversed, 'Backup '),
        'Backup · 2',
      );
      expect(proxies.first.name, 'Backup ');
    },
  );
}
