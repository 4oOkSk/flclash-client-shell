import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('private mode publishes and refreshes its durable server choice', () {
    if (!kPrivateClientMode) return;

    privateClientSelectedMap
      ..clear()
      ..['Proxy'] = 'node-a';
    final container = ProviderContainer();
    addTearDown(() {
      container.dispose();
      privateClientSelectedMap.clear();
    });

    expect(container.read(selectedMapProvider), {'Proxy': 'node-a'});

    privateClientSelectedMap['Proxy'] = 'node-b';
    container.invalidate(selectedMapProvider);
    final refreshed = container.read(selectedMapProvider);
    expect(refreshed, {'Proxy': 'node-b'});
    expect(() => refreshed['Proxy'] = 'node-c', throwsUnsupportedError);
  });
}
