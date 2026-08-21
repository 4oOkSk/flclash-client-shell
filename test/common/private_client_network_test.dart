import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/common/task.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/clash_config.dart';
import 'package:fl_clash/models/state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

void main() {
  test('managed Windows, Android and macOS use reliable gVisor TUN', () {
    expect(
      effectiveClientTunStack(
        configured: TunStack.mixed,
        privateClientMode: true,
        isWindows: true,
        isAndroid: false,
        isMacOS: false,
      ),
      TunStack.gvisor,
    );
    expect(
      effectiveClientTunStack(
        configured: TunStack.system,
        privateClientMode: true,
        isWindows: false,
        isAndroid: true,
        isMacOS: false,
      ),
      TunStack.gvisor,
    );
    expect(
      effectiveClientVpnStackName(
        configured: TunStack.mixed,
        privateClientMode: true,
        isWindows: false,
        isAndroid: true,
        isMacOS: false,
      ),
      'gvisor',
    );
    expect(
      effectiveClientTunStack(
        configured: TunStack.system,
        privateClientMode: true,
        isWindows: false,
        isAndroid: false,
        isMacOS: true,
      ),
      TunStack.gvisor,
    );
  });

  test(
    'generic and other-platform clients preserve the selected TUN stack',
    () {
      expect(
        effectiveClientTunStack(
          configured: TunStack.mixed,
          privateClientMode: false,
          isWindows: true,
          isAndroid: false,
          isMacOS: false,
        ),
        TunStack.mixed,
      );
      expect(
        effectiveClientTunStack(
          configured: TunStack.system,
          privateClientMode: true,
          isWindows: false,
          isAndroid: false,
          isMacOS: false,
        ),
        TunStack.system,
      );
    },
  );

  test(
    'macOS disables recvmsgx batching while other platforms preserve it',
    () {
      expect(
        effectiveClientTunRecvMsgX(configured: true, isMacOS: true),
        isFalse,
      );
      expect(
        effectiveClientTunRecvMsgX(configured: true, isMacOS: false),
        isTrue,
      );
      expect(
        effectiveClientTunRecvMsgX(configured: false, isMacOS: false),
        isFalse,
      );
    },
  );

  test('TUN recvmsgx setting survives JSON serialization', () {
    const tun = Tun(recvmsgx: false);
    expect(tun.toJson()['recvmsgx'], isFalse);
    expect(Tun.fromJson(tun.toJson()).recvmsgx, isFalse);
  });

  test('rendered Mihomo YAML includes the effective recvmsgx value', () async {
    final result = await makeRealProfileTask(
      const MakeRealProfileState(
        profilesPath: '/tmp/harborproxy-test-profiles',
        profileId: 1,
        rawConfig: <String, dynamic>{'rules': <String>[]},
        realPatchConfig: PatchClashConfig(tun: Tun(recvmsgx: false)),
        overrideDns: false,
        appendSystemDns: false,
        proxyGroups: <ProxyGroup>[],
        rules: <Rule>[],
        addedRules: <Rule>[],
        defaultUA: 'HarborProxy-Test',
      ),
    );
    final document = loadYaml(result.a) as YamlMap;
    expect((document['tun'] as YamlMap)['recvmsgx'], isFalse);
  });

  test('managed clients always capture IPv6', () {
    expect(
      effectiveClientIpv6(
        configured: false,
        privateClientMode: true,
        isAndroid: true,
      ),
      isTrue,
    );
    expect(
      effectiveClientIpv6(
        configured: false,
        privateClientMode: true,
        isAndroid: false,
      ),
      isTrue,
    );
  });

  test('generic clients preserve the configured IPv6 value', () {
    expect(
      effectiveClientIpv6(
        configured: false,
        privateClientMode: false,
        isAndroid: true,
      ),
      isFalse,
    );
  });

  test('managed Android captures IPv6 but keeps managed DNS IPv4-only', () {
    expect(
      effectiveClientIpv6(
        configured: false,
        privateClientMode: true,
        isAndroid: true,
      ),
      isTrue,
    );
    expect(
      effectiveClientCoreIpv6(
        configured: true,
        privateClientMode: true,
        isAndroid: true,
      ),
      isFalse,
    );
  });

  test('desktop and generic clients preserve the configured core IPv6', () {
    expect(
      effectiveClientCoreIpv6(
        configured: true,
        privateClientMode: true,
        isAndroid: false,
      ),
      isTrue,
    );
    expect(
      effectiveClientCoreIpv6(
        configured: false,
        privateClientMode: false,
        isAndroid: true,
      ),
      isFalse,
    );
  });

  test('managed clients use TUN without advertising an HTTP proxy', () {
    expect(
      effectiveClientVpnSystemProxy(
        configured: true,
        privateClientMode: true,
        isAndroid: true,
      ),
      isFalse,
    );
    expect(
      effectiveClientVpnSystemProxy(
        configured: true,
        privateClientMode: true,
        isAndroid: false,
      ),
      isFalse,
    );
  });

  test('Android VPN consent is not treated as desktop core elevation', () {
    expect(
      requiresPrivilegedTunCoreAuthorization(
        isAndroid: true,
        requestedTun: true,
        effectiveTun: false,
      ),
      isFalse,
    );
    expect(
      requiresPrivilegedTunCoreAuthorization(
        isAndroid: false,
        requestedTun: true,
        effectiveTun: false,
      ),
      isTrue,
    );
    expect(
      requiresPrivilegedTunCoreAuthorization(
        isAndroid: false,
        requestedTun: true,
        effectiveTun: true,
      ),
      isFalse,
    );
  });

  test('generic clients preserve system proxy', () {
    expect(
      effectiveClientVpnSystemProxy(
        configured: true,
        privateClientMode: false,
        isAndroid: true,
      ),
      isTrue,
    );
    expect(
      effectiveClientVpnSystemProxy(
        configured: true,
        privateClientMode: false,
        isAndroid: false,
      ),
      isTrue,
    );
  });
}
