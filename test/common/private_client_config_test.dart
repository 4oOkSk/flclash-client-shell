import 'package:fl_clash/common/private_client_config.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('managed client configuration is rule-mode TUN-only', () {
    const source = Config(
      themeProps: defaultThemeProps,
      appSettingProps: AppSettingProps(
        dashboardWidgets: [
          DashboardWidget.networkSpeed,
          DashboardWidget.outboundMode,
          DashboardWidget.systemProxyButton,
          DashboardWidget.tunButton,
          DashboardWidget.vpnButton,
        ],
      ),
      networkProps: NetworkProps(systemProxy: true),
      vpnProps: VpnProps(enable: false, systemProxy: true),
      patchClashConfig: PatchClashConfig(
        mode: Mode.global,
        allowLan: true,
        ipv6: false,
        tun: Tun(enable: false),
      ),
    );

    final normalized = normalizePrivateClientConfig(
      source,
      initializeDashboardCards: true,
    );

    expect(normalized.patchClashConfig.mode, Mode.rule);
    expect(normalized.patchClashConfig.tun.enable, isTrue);
    expect(normalized.patchClashConfig.allowLan, isFalse);
    expect(normalized.patchClashConfig.ipv6, isTrue);
    expect(normalized.networkProps.systemProxy, isFalse);
    expect(normalized.vpnProps.enable, isTrue);
    expect(normalized.vpnProps.systemProxy, isFalse);
    expect(normalized.appSettingProps.dashboardWidgets, [
      DashboardWidget.privateClientAccount,
      DashboardWidget.privateClientWebsite,
      DashboardWidget.networkSpeed,
    ]);
  });

  test('managed fixed cards are initialized once and remain removable', () {
    const source = Config(
      themeProps: defaultThemeProps,
      appSettingProps: AppSettingProps(
        dashboardWidgets: [DashboardWidget.networkSpeed],
      ),
    );

    final initialized = normalizePrivateClientConfig(
      source,
      initializeDashboardCards: true,
    );
    final afterUserRemoval = normalizePrivateClientConfig(
      initialized.copyWith(
        appSettingProps: initialized.appSettingProps.copyWith(
          dashboardWidgets: [DashboardWidget.networkSpeed],
        ),
      ),
    );

    expect(initialized.appSettingProps.dashboardWidgets, [
      DashboardWidget.privateClientAccount,
      DashboardWidget.privateClientWebsite,
      DashboardWidget.networkSpeed,
    ]);
    expect(afterUserRemoval.appSettingProps.dashboardWidgets, [
      DashboardWidget.networkSpeed,
    ]);
  });

  test('generic dashboard filtering hides managed-only cards', () {
    final widgets = genericDashboardWidgets(const [
      DashboardWidget.privateClientAccount,
      DashboardWidget.networkSpeed,
      DashboardWidget.privateClientWebsite,
    ]);

    expect(widgets, [DashboardWidget.networkSpeed]);
  });

  test('managed routing defaults bypass mainland but proxy overseas', () {
    const props = NetworkProps();
    expect(props.managedRouteMode, ManagedRouteMode.bypassMainland);
  });
}
