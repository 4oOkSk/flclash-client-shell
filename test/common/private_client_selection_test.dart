import 'package:fl_clash/common/private_client_selection.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('changes core before publishing a durable private selection', () async {
    final events = <String>[];
    final next = await applyPrivateClientProxySelection(
      current: const {'Proxy': 'automatic'},
      groupName: 'Proxy',
      proxyName: 'manual-server',
      changeCore: () async {
        events.add('core');
        return '';
      },
      persist: (value) async {
        events.add('persist:${value['Proxy']}');
        return true;
      },
    );

    expect(events, ['core', 'persist:manual-server']);
    expect(next, {'Proxy': 'manual-server'});
    expect(() => next['Proxy'] = 'other', throwsUnsupportedError);
  });

  test('does not persist or publish a rejected core selection', () async {
    var persisted = false;
    await expectLater(
      applyPrivateClientProxySelection(
        current: const {'Proxy': 'automatic'},
        groupName: 'Proxy',
        proxyName: 'missing-server',
        changeCore: () async => 'Not found proxy',
        persist: (_) async {
          persisted = true;
          return true;
        },
      ),
      throwsStateError,
    );
    expect(persisted, isFalse);
  });

  test('fails closed when durable storage rejects the selection', () async {
    await expectLater(
      applyPrivateClientProxySelection(
        current: const {},
        groupName: 'Proxy',
        proxyName: 'manual-server',
        changeCore: () async => '',
        persist: (_) async => false,
      ),
      throwsStateError,
    );
  });
}
