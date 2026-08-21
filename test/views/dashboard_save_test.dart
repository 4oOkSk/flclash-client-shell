import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/views/dashboard/dashboard.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('dashboard save snapshots the current grid order synchronously', () {
    final widgets = dashboardWidgetsFromGridItems([
      DashboardWidget.trafficUsage.widget,
      DashboardWidget.networkSpeed.widget,
    ]);

    expect(widgets, [
      DashboardWidget.trafficUsage,
      DashboardWidget.networkSpeed,
    ]);
  });

  test('dashboard save persists managed account and website cards', () {
    final widgets = dashboardWidgetsFromGridItems([
      DashboardWidget.privateClientWebsite.widget,
      DashboardWidget.trafficUsage.widget,
      DashboardWidget.privateClientAccount.widget,
      DashboardWidget.networkSpeed.widget,
    ]);

    expect(widgets, [
      DashboardWidget.privateClientWebsite,
      DashboardWidget.trafficUsage,
      DashboardWidget.privateClientAccount,
      DashboardWidget.networkSpeed,
    ]);
  });

  test('dashboard save keeps managed cards removed when absent', () {
    final widgets = dashboardWidgetsFromGridItems([
      DashboardWidget.trafficUsage.widget,
      DashboardWidget.networkSpeed.widget,
    ]);

    expect(widgets, [
      DashboardWidget.trafficUsage,
      DashboardWidget.networkSpeed,
    ]);
  });
}
