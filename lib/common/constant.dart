// ignore_for_file: constant_identifier_names

import 'dart:math';
import 'dart:ui';

import 'package:collection/collection.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter/material.dart';

import 'private_build_input.dart';

const appName = 'HarborProxy';
const coreManifestName = 'manifest.json';
const coreName = 'clash.meta';
const browserUa =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

/// Stable MethodChannel namespace; intentionally independent of the Android
/// applicationId used by branded release packages.
const packageName = 'com.follow.clash';
final unixSocketPath = '/tmp/HarborProxySocket_${Random().nextInt(10000)}.sock';
final windowsPipeName = '\\\\.\\pipe\\HarborProxyCore_${_randomPipeId()}';
const maxTextScale = 1.4;
const minTextScale = 0.8;
final baseInfoEdgeInsets = EdgeInsets.symmetric(
  vertical: 16.mAp,
  horizontal: 16.mAp,
);
final listHeaderPadding = EdgeInsets.only(
  left: 16.mAp,
  right: 8.mAp,
  top: 24.mAp,
  bottom: 8.mAp,
);
const sheetAppBarHeight = 68.0;

const watchExecution = false;

String _randomPipeId() {
  final random = Random.secure();
  return List.generate(
    16,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

final defaultTextScaleFactor =
    WidgetsBinding.instance.platformDispatcher.textScaleFactor;
const httpTimeoutDuration = Duration(milliseconds: 5000);

/// Keep at or below the Core's delay-test concurrency (`mBatch` in
/// core/common.go). Surplus requests queue inside the Core behind a full wave
/// of 5s timeouts, which no RPC timeout can cover.
const maxConcurrentDelayTests = 50;
const moreDuration = Duration(milliseconds: 100);
const animateDuration = Duration(milliseconds: 100);
const midDuration = Duration(milliseconds: 200);
const commonDuration = Duration(milliseconds: 300);
const defaultUpdateDuration = Duration(days: 1);
const MMDB = 'GEOIP.metadb';
const ASN = 'ASN.mmdb';
const GEOIP = 'GEOIP.dat';
const GEOSITE = 'GEOSITE.dat';
final double kHeaderHeight = system.isDesktop
    ? !system.isMacOS
          ? 40
          : 28
    : 0;
const profilesDirectoryName = 'profiles';
const localhost = '127.0.0.1';
const clashConfigKey = 'clash_config';
const configKey = 'config';
const double dialogCommonWidth = 300;
const repository = 'chen08209/FlClash';
const defaultExternalController = '127.0.0.1:9090';
const maxMobileWidth = 600;
const maxLaptopWidth = 840;
const defaultTestUrl = 'https://www.gstatic.com/generate_204';
final commonFilter = ImageFilter.blur(
  sigmaX: 5,
  sigmaY: 5,
  tileMode: TileMode.clamp,
);

const listEquality = ListEquality();
const navigationItemListEquality = ListEquality<NavigationItem>();
const trackerInfoListEquality = ListEquality<TrackerInfo>();
const stringListEquality = ListEquality<String>();
const intListEquality = ListEquality<int>();
const logListEquality = ListEquality<Log>();
const groupListEquality = ListEquality<Group>();
const ruleListEquality = ListEquality<Rule>();
const scriptListEquality = ListEquality<Script>();
const externalProviderListEquality = ListEquality<ExternalProvider>();
const packageListEquality = ListEquality<Package>();
const profileListEquality = ListEquality<Profile>();
const proxyGroupsEquality = ListEquality<ProxyGroup>();
const hotKeyActionListEquality = ListEquality<HotKeyAction>();
const stringAndStringMapEquality = MapEquality<String, String>();
const stringAndStringMapEntryListEquality =
    ListEquality<MapEntry<String, String>>();
const stringAndStringMapEntryIterableEquality =
    IterableEquality<MapEntry<String, String>>();
const stringAndObjectMapEntryIterableEquality =
    IterableEquality<MapEntry<String, Object?>>();
const delayMapEquality = MapEquality<String, Map<String, int?>>();
const stringSetEquality = SetEquality<String>();
const keyboardModifierListEquality = SetEquality<KeyboardModifier>();

const viewModeColumnsMap = {
  ViewMode.mobile: [2, 1],
  ViewMode.laptop: [3, 2],
  ViewMode.desktop: [4, 3],
};

const proxiesListStoreKey = PageStorageKey<String>('proxies_list');
const toolsStoreKey = PageStorageKey<String>('tools');
const profilesStoreKey = PageStorageKey<String>('profiles');

const defaultPrimaryColor = 0xFF1976D2;

double getWidgetHeight(num lines) {
  final space = 14.mAp;
  return max(lines * (80.ap + space) - space, 0);
}

const maxLength = 1000;

const mainIsolate = 'HarborProxyMainIsolate';

const serviceIsolate = 'HarborProxyServiceIsolate';

const defaultPrimaryColors = [
  defaultPrimaryColor,
  0xFF795548,
  0xFF03A9F4,
  0xFFFFFF00,
  0XFFBBC9CC,
  0XFFABD397,
  0XFFD8C0C3,
  0XFF665390,
];

const scriptTemplate = '''
const main = (config) => {
  return config;
}''';

const privateRouteScriptTemplate = '''
/*
 * The private client exposes only a redacted routing view here:
 * config.rules, config['rule-providers'], and policy-group names.
 * Proxy endpoints and the server-delivered configuration are never provided.
 */
const main = (config) => {
  return config;
}''';

const backupDatabaseName = 'database.sqlite';
const configJsonName = 'config.json';

/// 入册(enroll) blob。正式包用 `--dart-define=PRIVATE_CLIENT_ENROLL_BLOB=...` 注入；
/// 仓库默认留空，避免把 per-build/per-device token 材料写进 Git。
const kEmbeddedEnrollBlob = String.fromEnvironment(
  'PRIVATE_CLIENT_ENROLL_BLOB',
);

/// 自有客户端 API 入口。正式构建只注入经过可逆变换的字节串，避免安装包被
/// `strings` 一扫就直接得到入口；这不替代服务端认证或源站 FC-only 闸门。
final kClientApiBase = decodePrivateClientApiBase(
  const String.fromEnvironment('PRIVATE_CLIENT_API_BASE_OBF'),
);

/// Private release website. It is supplied by the local release inputs so the
/// generic source tree does not embed an operational domain.
const kPrivateClientWebsiteUrl = String.fromEnvironment(
  'PRIVATE_CLIENT_WEBSITE_URL',
);

bool get kPrivateClientMode =>
    kEmbeddedEnrollBlob.isNotEmpty || kClientApiBase.isNotEmpty;

/// The mixed/system TUN stacks can create a working adapter on managed
/// Windows, Android or macOS clients while application payloads still stall.
/// Managed clients prefer the predictable gVisor stack on those platforms;
/// generic builds keep the user's choice.
TunStack effectiveClientTunStack({
  required TunStack configured,
  required bool privateClientMode,
  required bool isWindows,
  required bool isAndroid,
  required bool isMacOS,
}) {
  if (privateClientMode && (isWindows || isAndroid || isMacOS)) {
    return TunStack.gvisor;
  }
  return configured;
}

/// Darwin's recvmsgx batch path continuously returns EBADF on macOS 26 while
/// ordinary UTUN reads remain functional. Disable only that optional batching
/// path on macOS; other platforms retain the configured core default.
bool effectiveClientTunRecvMsgX({
  required bool configured,
  required bool isMacOS,
}) => isMacOS ? false : configured;

String effectiveClientVpnStackName({
  required TunStack configured,
  required bool privateClientMode,
  required bool isWindows,
  required bool isAndroid,
  required bool isMacOS,
}) => effectiveClientTunStack(
  configured: configured,
  privateClientMode: privateClientMode,
  isWindows: isWindows,
  isAndroid: isAndroid,
  isMacOS: isMacOS,
).name;

/// Managed builds must capture IPv6 as well as IPv4. Leaving the platform
/// default disabled lets dual-stack traffic bypass TUN, which makes routing
/// differ across Android, Linux, Windows and macOS.
bool effectiveClientIpv6({
  required bool configured,
  required bool privateClientMode,
  required bool isAndroid,
}) => configured || privateClientMode;

/// Managed Android keeps the platform IPv6 route inside VpnService so traffic
/// cannot bypass the tunnel, but the embedded core deliberately rejects IPv6
/// and AAAA answers. Applications can still send literal IPv6 destinations
/// learned through HTTPDNS; the Android runtime test covers that data path.
/// Desktop managed clients retain their existing dual-stack behavior.
bool effectiveClientCoreIpv6({
  required bool configured,
  required bool privateClientMode,
  required bool isAndroid,
}) => privateClientMode && isAndroid ? false : configured;

/// Managed clients use TUN only. Advertising the local mixed port as an
/// additional platform HTTP proxy creates a second, protocol-limited path and
/// makes browser behavior differ across platforms.
bool effectiveClientVpnSystemProxy({
  required bool configured,
  required bool privateClientMode,
  required bool isAndroid,
}) => configured && !privateClientMode;

/// 自有客户端启动/定时 setup 时最多每天回源一次；命中本地加密缓存则不访问 FC。
/// 如果后续想更省账单，改成 `Duration(days: 7)` 即可切到每周。
const kEnrollAutoUpdateDuration = defaultUpdateDuration;

final privateClientSelectedMap = <String, String>{};
