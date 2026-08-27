import 'dart:async';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/models/models.dart';

import 'desktop/model.dart';
import 'method.dart';

mixin CoreInterface {
  Future<CoreLifecycleResult> start();

  Future<CoreLifecycleResult> restart();

  Future<CoreLifecycleResult> stop();

  Future<CoreLifecycleResult> close();

  Future<bool> init(InitParams params);

  Future<bool> get isInit;

  Future<bool> forceGc();

  Future<String> validateConfig(String path);

  Future<Map<String, dynamic>> getConfig(String path);

  Future<Delay> asyncTestDelay(String url, String proxyName);

  Future<String> updateConfig(UpdateParams updateParams);

  Future<String> setupConfig(SetupParams setupParams);

  Future<String> setupFromEnroll({
    required String blob,
    required Duration refreshInterval,
    Map<String, String> selectedMap = const {},
    String testUrl = defaultTestUrl,
  });

  Future<String> setupFromClient({
    required String endpoint,
    required Duration refreshInterval,
    Map<String, String> selectedMap = const {},
    String testUrl = defaultTestUrl,
    PrivateRouteOverlay routeOverlay = const PrivateRouteOverlay(),
  });

  Future<String> clientLogin({
    required String endpoint,
    required String email,
    required String password,
    required String code,
  });

  Future<bool> clientHasSession();

  Future<String> clientAccountInfo();

  Future<String> clientDiagnostics();

  Future<String> configureClientSecureStorage({
    required String key,
    required String source,
  });

  Future<String> clientClear({required String endpoint});

  Future<ProxiesData> getProxies();

  Future<String> changeProxy(ChangeProxyParams changeProxyParams);

  Future<bool> startListener();

  Future<bool> stopListener();

  Future<List<ExternalProvider>> getExternalProviders();

  Future<ExternalProvider?> getExternalProvider(String externalProviderName);

  Future<String> updateGeoData(String type);

  Future<String> sideLoadExternalProvider({
    required String providerName,
    required String data,
  });

  Future<String> updateExternalProvider(String providerName);

  FutureOr<Traffic> getTraffic(bool onlyStatisticsProxy);

  FutureOr<Traffic> getTotalTraffic(bool onlyStatisticsProxy);

  FutureOr<String> getCountryCode(String ip);

  FutureOr<int> getMemory();

  FutureOr<void> resetTraffic();

  FutureOr<void> startLog();

  FutureOr<void> stopLog();

  Future<List<String>> getPlatformDiagnosticLogs();

  Future<bool> crash();

  FutureOr<List<TrackerInfo>> getConnections();

  FutureOr<bool> closeConnection(String id);

  FutureOr<String> clearEffect(int profileId);

  FutureOr<bool> closeConnections();

  FutureOr<bool> resetConnections();
}

abstract class CoreHandlerInterface with CoreInterface {
  Future<T?> _invokeMethod<T>({
    required CoreMethod method,
    Object? arguments,
    Duration? timeout,
  }) async {
    return await utils.handleWatch(
      onStart: () {
        final safeArguments = switch (method) {
          CoreMethod.setupFromEnroll || CoreMethod.initClash => '<redacted>',
          _ => arguments,
        };
        commonPrint.log(
          'Invoke method ${method.name} ${DateTime.now()} $safeArguments',
        );
      },
      function: () async {
        return invokeMethod<T>(
          method: method,
          arguments: arguments,
          timeout: timeout,
        );
      },
      onEnd: (result, elapsedMilliseconds) {
        commonPrint.log(
          'Invoke method ${method.name} completed in ${elapsedMilliseconds}ms',
        );
      },
    );
  }

  Future<T?> invokeMethod<T>({
    required CoreMethod method,
    Object? arguments,
    Duration? timeout,
  });

  @override
  Future<List<String>> getPlatformDiagnosticLogs() async => const [];

  @override
  Future<bool> init(InitParams params) async {
    return await _invokeMethod<bool>(
          method: CoreMethod.initClash,
          arguments: params.toJson(),
        ) ??
        false;
  }

  @override
  Future<bool> get isInit async {
    return await _invokeMethod<bool>(method: CoreMethod.getIsInit) ?? false;
  }

  @override
  Future<bool> forceGc() async {
    return await _invokeMethod<bool>(method: CoreMethod.forceGc) ?? false;
  }

  @override
  Future<String> validateConfig(String path) async {
    return await _invokeMethod<String>(
          method: CoreMethod.validateConfig,
          arguments: path,
        ) ??
        '';
  }

  @override
  Future<String> updateConfig(UpdateParams updateParams) async {
    return await _invokeMethod<String>(
          method: CoreMethod.updateConfig,
          arguments: updateParams.toJson(),
        ) ??
        '';
  }

  @override
  Future<Map<String, dynamic>> getConfig(String path) async {
    final result = await _invokeMethod<Map<String, dynamic>>(
      method: CoreMethod.getConfig,
      arguments: path,
    );
    if (result == null) {
      throw const CoreMethodException(
        code: 'empty_result',
        message: 'Core returned an empty config result',
      );
    }
    return result;
  }

  @override
  Future<String> setupConfig(SetupParams setupParams) async {
    return await _invokeMethod<String>(
          method: CoreMethod.setupConfig,
          arguments: setupParams.toJson(),
        ) ??
        '';
  }

  Future<String> _invokeEnroll(Map<String, Object?> arguments) async {
    return await _invokeMethod<String>(
          method: CoreMethod.setupFromEnroll,
          arguments: arguments,
        ) ??
        '';
  }

  @override
  Future<String> setupFromEnroll({
    required String blob,
    required Duration refreshInterval,
    Map<String, String> selectedMap = const {},
    String testUrl = defaultTestUrl,
  }) => _invokeEnroll({
    'blob': blob,
    'selected-map': selectedMap,
    'test-url': testUrl,
    'refresh-interval-seconds': refreshInterval.inSeconds,
  });

  @override
  Future<String> setupFromClient({
    required String endpoint,
    required Duration refreshInterval,
    Map<String, String> selectedMap = const {},
    String testUrl = defaultTestUrl,
    PrivateRouteOverlay routeOverlay = const PrivateRouteOverlay(),
  }) => _invokeEnroll({
    'mode': 'client-setup',
    'endpoint': endpoint,
    'selected-map': selectedMap,
    'test-url': testUrl,
    'route-overlay': routeOverlay.toJson(),
    'refresh-interval-seconds': refreshInterval.inSeconds,
  });

  @override
  Future<String> clientLogin({
    required String endpoint,
    required String email,
    required String password,
    required String code,
  }) => _invokeEnroll({
    'mode': 'client-login',
    'endpoint': endpoint,
    'email': email,
    'password': password,
    'code': code,
  });

  @override
  Future<bool> clientHasSession() async =>
      (await _invokeEnroll({'mode': 'client-state'})).isEmpty;

  @override
  Future<String> clientAccountInfo() =>
      _invokeEnroll({'mode': 'client-info'});

  @override
  Future<String> clientDiagnostics() =>
      _invokeEnroll({'mode': 'client-diagnostics'});

  @override
  Future<String> configureClientSecureStorage({
    required String key,
    required String source,
  }) => _invokeEnroll({
    'mode': 'client-secure-storage',
    'secure-cache-key': key,
    'secure-cache-key-source': source,
  });

  @override
  Future<String> clientClear({required String endpoint}) => _invokeEnroll({
    'mode': 'client-clear',
    'endpoint': endpoint,
  });

  @override
  Future<bool> crash() async {
    return await _invokeMethod<bool>(method: CoreMethod.crash) ?? false;
  }

  @override
  Future<ProxiesData> getProxies() async {
    final data = await _invokeMethod<Map<String, dynamic>>(
      method: CoreMethod.getProxies,
    );
    return data != null
        ? ProxiesData.fromJson(data)
        : const ProxiesData(proxies: {}, all: []);
  }

  @override
  Future<String> changeProxy(ChangeProxyParams changeProxyParams) async {
    return await _invokeMethod<String>(
          method: CoreMethod.changeProxy,
          arguments: changeProxyParams.toJson(),
        ) ??
        '';
  }

  @override
  Future<List<ExternalProvider>> getExternalProviders() async {
    final data = await _invokeMethod<List<dynamic>>(
      method: CoreMethod.getExternalProviders,
    );
    return data
            ?.whereType<Map>()
            .map(
              (item) =>
                  ExternalProvider.fromJson(Map<String, Object?>.from(item)),
            )
            .toList() ??
        [];
  }

  @override
  Future<ExternalProvider?> getExternalProvider(
    String externalProviderName,
  ) async {
    final data = await _invokeMethod<Map<String, dynamic>>(
      method: CoreMethod.getExternalProvider,
      arguments: externalProviderName,
    );
    return data == null ? null : ExternalProvider.fromJson(data);
  }

  @override
  Future<String> updateGeoData(String type) async {
    return await _invokeMethod<String>(
          method: CoreMethod.updateGeoData,
          arguments: type,
        ) ??
        '';
  }

  @override
  Future<String> sideLoadExternalProvider({
    required String providerName,
    required String data,
  }) async {
    return await _invokeMethod<String>(
          method: CoreMethod.sideLoadExternalProvider,
          arguments: {'providerName': providerName, 'data': data},
        ) ??
        '';
  }

  @override
  Future<String> updateExternalProvider(String providerName) async {
    return await _invokeMethod<String>(
          method: CoreMethod.updateExternalProvider,
          arguments: providerName,
        ) ??
        '';
  }

  @override
  Future<List<TrackerInfo>> getConnections() async {
    final data = await _invokeMethod<Map<String, dynamic>>(
      method: CoreMethod.getConnections,
    );
    final connections = data?['connections'];
    if (connections is! List) {
      return [];
    }
    return connections
        .whereType<Map>()
        .map((item) => TrackerInfo.fromJson(Map<String, Object?>.from(item)))
        .toList();
  }

  @override
  Future<bool> closeConnections() async {
    return await _invokeMethod<bool>(method: CoreMethod.closeConnections) ??
        false;
  }

  @override
  Future<bool> resetConnections() async {
    return await _invokeMethod<bool>(method: CoreMethod.resetConnections) ??
        false;
  }

  @override
  Future<bool> closeConnection(String id) async {
    return await _invokeMethod<bool>(
          method: CoreMethod.closeConnection,
          arguments: id,
        ) ??
        false;
  }

  @override
  Future<Traffic> getTotalTraffic(bool onlyStatisticsProxy) async {
    final data = await _invokeMethod<Map<String, dynamic>>(
      method: CoreMethod.getTotalTraffic,
      arguments: onlyStatisticsProxy,
    );
    return data == null ? const Traffic() : Traffic.fromJson(data);
  }

  @override
  Future<Traffic> getTraffic(bool onlyStatisticsProxy) async {
    final data = await _invokeMethod<Map<String, dynamic>>(
      method: CoreMethod.getTraffic,
      arguments: onlyStatisticsProxy,
    );
    return data == null ? const Traffic() : Traffic.fromJson(data);
  }

  @override
  Future<String> clearEffect(int profileId) async {
    return await _invokeMethod<String>(
          method: CoreMethod.clearEffect,
          arguments: profileId,
        ) ??
        '';
  }

  @override
  FutureOr<void> resetTraffic() {
    _invokeMethod(method: CoreMethod.resetTraffic);
  }

  @override
  FutureOr<void> startLog() {
    _invokeMethod(method: CoreMethod.startLog);
  }

  @override
  FutureOr<void> stopLog() {
    _invokeMethod<bool>(method: CoreMethod.stopLog);
  }

  @override
  Future<bool> startListener() async {
    return await _invokeMethod<bool>(method: CoreMethod.startListener) ?? false;
  }

  @override
  Future<bool> stopListener() async {
    return await _invokeMethod<bool>(method: CoreMethod.stopListener) ?? false;
  }

  @override
  Future<Delay> asyncTestDelay(String url, String proxyName) async {
    final delayParams = {
      'proxy-name': proxyName,
      'timeout': httpTimeoutDuration.inMilliseconds,
      'test-url': url,
    };
    final data = await _invokeMethod<Map<String, dynamic>>(
      method: CoreMethod.asyncTestDelay,
      arguments: delayParams,
      timeout: const Duration(seconds: 6),
    );
    return data == null
        ? Delay(name: proxyName, value: -1, url: url)
        : Delay.fromJson(data);
  }

  @override
  Future<String> getCountryCode(String ip) async {
    return await _invokeMethod<String>(
          method: CoreMethod.getCountryCode,
          arguments: ip,
        ) ??
        '';
  }

  @override
  Future<int> getMemory() async {
    return await _invokeMethod<int>(method: CoreMethod.getMemory) ?? 0;
  }
}
