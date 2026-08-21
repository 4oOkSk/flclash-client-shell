import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/views/proxies/private_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('fresh install defaults to bypass mainland routing', () {
    const network = NetworkProps();

    expect(network.managedRouteMode, ManagedRouteMode.bypassMainland);
  });

  test('the three route modes map to an exclusive routing policy', () {
    expect(privateClientVisibleRoutingModes, [
      ManagedRouteMode.global,
      ManagedRouteMode.bypassMainland,
      ManagedRouteMode.bypassOverseas,
    ]);
    expect(ManagedRouteMode.global.bypassesMainland, isFalse);
    expect(ManagedRouteMode.global.bypassesOverseas, isFalse);
    expect(ManagedRouteMode.bypassMainland.bypassesMainland, isTrue);
    expect(ManagedRouteMode.bypassMainland.bypassesOverseas, isFalse);
    expect(ManagedRouteMode.bypassOverseas.bypassesMainland, isFalse);
    expect(ManagedRouteMode.bypassOverseas.bypassesOverseas, isTrue);
  });

  test(
    'legacy all-direct mode stays hidden and projects to selected global',
    () {
      expect(
        privateClientVisibleRoutingModes,
        isNot(contains(ManagedRouteMode.directAllLegacy)),
      );
      expect(
        ManagedRouteMode.directAllLegacy.visibleMode,
        ManagedRouteMode.global,
      );
      expect(ManagedRouteMode.directAllLegacy.bypassesMainland, isTrue);
      expect(ManagedRouteMode.directAllLegacy.bypassesOverseas, isTrue);
    },
  );
}
