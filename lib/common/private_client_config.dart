import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter/foundation.dart';

const clientLoginRequiredMessage = 'client login required';
const privateClientSessionRefreshDuration = Duration(minutes: 20);
const privateClientResumeValidationInterval = Duration(minutes: 1);
final clientAuthenticationRequiredNotifier = ValueNotifier<int>(0);

void notifyClientAuthenticationRequired() {
  clientAuthenticationRequiredNotifier.value += 1;
}

const privateClientHiddenDashboardWidgets = <DashboardWidget>{
  DashboardWidget.outboundMode,
  DashboardWidget.outboundModeV2,
  DashboardWidget.systemProxyButton,
  DashboardWidget.tunButton,
  DashboardWidget.vpnButton,
};

const privateClientOnlyDashboardWidgets = <DashboardWidget>{
  DashboardWidget.privateClientAccount,
  DashboardWidget.privateClientWebsite,
};

const defaultPrivateClientDashboardWidgets = <DashboardWidget>[
  DashboardWidget.privateClientAccount,
  DashboardWidget.privateClientWebsite,
];

List<DashboardWidget> privateClientDashboardWidgets(
  Iterable<DashboardWidget> widgets,
) {
  return widgets
      .where((item) => !privateClientHiddenDashboardWidgets.contains(item))
      .toList(growable: false);
}

List<DashboardWidget> genericDashboardWidgets(
  Iterable<DashboardWidget> widgets,
) {
  return widgets
      .where((item) => !privateClientOnlyDashboardWidgets.contains(item))
      .toList(growable: false);
}

bool requiresPrivilegedTunCoreAuthorization({
  required bool isAndroid,
  required bool requestedTun,
  required bool effectiveTun,
}) {
  if (isAndroid) return false;
  return requestedTun != effectiveTun && !effectiveTun;
}

Config normalizePrivateClientConfig(
  Config config, {
  bool initializeDashboardCards = false,
}) {
  final configuredDashboardWidgets = privateClientDashboardWidgets(
    config.appSettingProps.dashboardWidgets,
  );
  final dashboardWidgets = initializeDashboardCards
      ? [
          ...defaultPrivateClientDashboardWidgets.where(
            (item) => !configuredDashboardWidgets.contains(item),
          ),
          ...configuredDashboardWidgets,
        ]
      : configuredDashboardWidgets;
  return config.copyWith(
    appSettingProps: config.appSettingProps.copyWith(
      dashboardWidgets: dashboardWidgets,
    ),
    networkProps: config.networkProps.copyWith(
      systemProxy: false,
      routeMode: RouteMode.config,
    ),
    vpnProps: config.vpnProps.copyWith(enable: true, systemProxy: false),
    patchClashConfig: config.patchClashConfig.copyWith(
      mode: Mode.rule,
      allowLan: false,
      ipv6: true,
      tun: config.patchClashConfig.tun.copyWith(enable: true),
    ),
  );
}
