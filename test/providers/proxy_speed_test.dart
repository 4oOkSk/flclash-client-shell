import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/core/interface.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _TrafficCore extends Fake implements CoreHandlerInterface {
  final speedRequests = <bool>[];
  final totalRequests = <bool>[];
  static const proxySpeed = Traffic(up: 128, down: 256);
  static const allTraffic = Traffic(up: 8192, down: 16384);

  @override
  Future<Traffic> getTraffic(bool onlyStatisticsProxy) async {
    speedRequests.add(onlyStatisticsProxy);
    return onlyStatisticsProxy ? proxySpeed : allTraffic;
  }

  @override
  Future<Traffic> getTotalTraffic(bool onlyStatisticsProxy) async {
    totalRequests.add(onlyStatisticsProxy);
    return onlyStatisticsProxy ? proxySpeed : allTraffic;
  }
}

class _TrafficAction extends CommonAction {
  final CoreController controller;
  _TrafficAction(this.controller);

  @override
  CoreController get trafficController => controller;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final onlyProxyTotal in [false, true]) {
    test(
      'speed and tray exclude direct traffic, total preference=$onlyProxyTotal',
      () async {
        final core = _TrafficCore();
        final container = ProviderContainer(
          overrides: [
            commonActionProvider.overrideWith(
              () => _TrafficAction(CoreController.test(core)),
            ),
          ],
        );
        addTearDown(container.dispose);
        container.listen(trayTitleStateProvider, (_, _) {});
        container.listen(totalTrafficProvider, (_, _) {});
        container
            .read(appSettingProvider.notifier)
            .update(
              (value) => value.copyWith(
                onlyStatisticsProxy: onlyProxyTotal,
                showTrayTitle: true,
              ),
            );
        await container.read(commonActionProvider.notifier).updateTraffic();
        expect(core.speedRequests, [true]);
        expect(core.totalRequests, [onlyProxyTotal]);
        expect(
          container.read(trafficsProvider).list.safeLast(const Traffic()),
          _TrafficCore.proxySpeed,
        );
        expect(
          container.read(trayTitleStateProvider).traffic,
          _TrafficCore.proxySpeed,
        );
        expect(
          container.read(totalTrafficProvider),
          onlyProxyTotal ? _TrafficCore.proxySpeed : _TrafficCore.allTraffic,
        );
      },
    );
  }
}
