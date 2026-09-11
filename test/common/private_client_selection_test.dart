import 'package:fl_clash/common/private_client_selection.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final storageThrows in [false, true]) {
    test(
      'storage failure rolls back actual core selection: throws=$storageThrows',
      () async {
        var actual = 'automatic';
        final events = <String>[];
        await expectLater(
          applyPrivateClientProxySelection(
            current: const {'Proxy': 'automatic'},
            groupName: 'Proxy',
            proxyName: 'manual ',
            readCore: () async => actual,
            changeCore: (name) async {
              events.add(name);
              actual = name;
              return '';
            },
            persist: (_) async {
              if (storageThrows) throw StateError('disk');
              return false;
            },
          ),
          throwsA(
            isA<PrivateClientSelectionFailure>().having(
              (error) => error.outcome,
              'outcome',
              'save-failed-restored',
            ),
          ),
        );
        expect(actual, 'automatic');
        expect(events, ['manual ', 'automatic']);
      },
    );
  }
  test('lost ACK needs core readback before persisting', () async {
    var actual = 'automatic';
    final next = await applyPrivateClientProxySelection(
      current: const {},
      groupName: 'Proxy',
      proxyName: 'manual ',
      readCore: () async => actual,
      changeCore: (name) async {
        actual = name;
        throw StateError('lost ACK');
      },
      persist: (value) async {
        expect(value['Proxy'], 'manual ');
        return true;
      },
    );
    expect(next['Proxy'], 'manual ');
    expect(() => next['Proxy'] = 'other', throwsUnsupportedError);
  });
  test('unconfirmed change never persists an assumed selection', () async {
    var reads = 0;
    var persisted = false;
    await expectLater(
      applyPrivateClientProxySelection(
        current: const {},
        groupName: 'Proxy',
        proxyName: 'manual',
        readCore: () async => reads++ == 0 ? 'automatic' : null,
        changeCore: (_) async => throw StateError('timeout'),
        persist: (_) async {
          persisted = true;
          return true;
        },
      ),
      throwsA(
        isA<PrivateClientSelectionFailure>().having(
          (error) => error.outcome,
          'outcome',
          'unconfirmed',
        ),
      ),
    );
    expect(persisted, isFalse);
  });
  test('failed rollback reports actual unsaved selection', () async {
    var actual = 'automatic';
    await expectLater(
      applyPrivateClientProxySelection(
        current: const {},
        groupName: 'Proxy',
        proxyName: 'manual',
        readCore: () async => actual,
        changeCore: (name) async {
          if (name == 'automatic') return 'rejected';
          actual = name;
          return '';
        },
        persist: (_) async => false,
      ),
      throwsA(
        isA<PrivateClientSelectionFailure>()
            .having(
              (error) => error.outcome,
              'outcome',
              'save-failed-unconfirmed',
            )
            .having(
              (error) => error.actualSelection,
              'actual selection',
              'manual',
            ),
      ),
    );
  });
  test('rejected change does not write storage', () async {
    await expectLater(
      applyPrivateClientProxySelection(
        current: const {},
        groupName: 'Proxy',
        proxyName: 'missing',
        readCore: () async => 'automatic',
        changeCore: (_) async => 'rejected',
        persist: (_) async {
          fail('unexpected write');
        },
      ),
      throwsA(
        isA<PrivateClientSelectionFailure>().having(
          (error) => error.outcome,
          'outcome',
          'rejected',
        ),
      ),
    );
  });
}
