import 'dart:async';
import 'dart:convert';

import 'package:fl_clash/models/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'constant.dart';

class Preferences {
  static Preferences? _instance;
  Completer<SharedPreferences?> sharedPreferencesCompleter = Completer();

  Future<bool> get isInit async =>
      await sharedPreferencesCompleter.future != null;

  Preferences._internal() {
    SharedPreferences.getInstance()
        .then((value) => sharedPreferencesCompleter.complete(value))
        .onError((_, _) => sharedPreferencesCompleter.complete(null));
  }

  factory Preferences() {
    _instance ??= Preferences._internal();
    return _instance!;
  }

  Future<int> getVersion() async {
    final preferences = await sharedPreferencesCompleter.future;
    return preferences?.getInt('version') ?? 0;
  }

  Future<void> setVersion(int version) async {
    final preferences = await sharedPreferencesCompleter.future;
    await preferences?.setInt('version', version);
  }

  Future<void> saveShareState(SharedState shareState) async {
    final preferences = await sharedPreferencesCompleter.future;
    await preferences?.setString('sharedState', json.encode(shareState));
  }

  Future<Map<String, Object?>?> getConfigMap() async {
    try {
      final preferences = await sharedPreferencesCompleter.future;
      final configString = preferences?.getString(configKey);
      if (configString == null) return null;
      final Map<String, Object?>? configMap = json.decode(configString);
      return configMap;
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, Object?>?> getClashConfigMap() async {
    try {
      final preferences = await sharedPreferencesCompleter.future;
      final clashConfigString = preferences?.getString(clashConfigKey);
      if (clashConfigString == null) return null;
      return json.decode(clashConfigString);
    } catch (_) {
      return null;
    }
  }

  Future<void> clearClashConfig() async {
    try {
      final preferences = await sharedPreferencesCompleter.future;
      await preferences?.remove(clashConfigKey);
      return;
    } catch (_) {
      return;
    }
  }

  Future<Config?> getConfig() async {
    final configMap = await getConfigMap();
    if (configMap == null) {
      return null;
    }
    return Config.fromJson(configMap);
  }

  Future<bool> saveConfig(Config config) async {
    final preferences = await sharedPreferencesCompleter.future;
    return preferences?.setString(
          configKey,
          json.encode(configToCompatibleJson(config)),
        ) ??
        false;
  }

  Future<Map<String, String>> getPrivateClientSelectedMap() async {
    try {
      final preferences = await sharedPreferencesCompleter.future;
      final selectedMapString = preferences?.getString(
        'private_client_selected_map',
      );
      if (selectedMapString == null) return {};
      final map = json.decode(selectedMapString) as Map<String, dynamic>;
      return map.map((key, value) => MapEntry(key, value.toString()));
    } catch (_) {
      return {};
    }
  }

  Future<bool> savePrivateClientSelectedMap(
    Map<String, String> selectedMap,
  ) async {
    final preferences = await sharedPreferencesCompleter.future;
    return preferences?.setString(
          'private_client_selected_map',
          json.encode(selectedMap),
        ) ??
        false;
  }

  Future<void> clearPrivateClientSelectedMap() async {
    final preferences = await sharedPreferencesCompleter.future;
    await preferences?.remove('private_client_selected_map');
  }

  Future<bool> getPrivateDashboardCardsInitialized() async {
    final preferences = await sharedPreferencesCompleter.future;
    return preferences?.getBool('private_dashboard_cards_initialized') ?? false;
  }

  Future<bool> setPrivateDashboardCardsInitialized() async {
    final preferences = await sharedPreferencesCompleter.future;
    return preferences?.setBool('private_dashboard_cards_initialized', true) ??
        false;
  }

  Future<List<PrivateRuleProviderConfig>> getPrivateRuleProviders() async {
    try {
      final preferences = await sharedPreferencesCompleter.future;
      final value = preferences?.getString('private_client_rule_providers');
      if (value == null) return [];
      final decoded = json.decode(value);
      if (decoded is! List) return [];
      final providers = <PrivateRuleProviderConfig>[];
      for (final item in decoded) {
        try {
          if (item is Map) {
            providers.add(
              PrivateRuleProviderConfig.fromJson(
                item.map((key, value) => MapEntry(key.toString(), value)),
              ),
            );
          }
        } catch (_) {
          continue;
        }
      }
      return providers;
    } catch (_) {
      return [];
    }
  }

  Future<bool> savePrivateRuleProviders(
    List<PrivateRuleProviderConfig> providers,
  ) async {
    for (final provider in providers) {
      provider.validate();
    }
    final preferences = await sharedPreferencesCompleter.future;
    return preferences?.setString(
          'private_client_rule_providers',
          json.encode(providers.map((item) => item.toJson()).toList()),
        ) ??
        false;
  }

  Future<int?> getPrivateRouteScriptId() async {
    final preferences = await sharedPreferencesCompleter.future;
    return preferences?.getInt('private_client_route_script_id');
  }

  Future<bool> savePrivateRouteScriptId(int? scriptId) async {
    final preferences = await sharedPreferencesCompleter.future;
    if (scriptId == null) {
      return preferences?.remove('private_client_route_script_id') ?? false;
    }
    return preferences?.setInt('private_client_route_script_id', scriptId) ??
        false;
  }

  Future<void> clearPrivateRoutePreferences() async {
    final preferences = await sharedPreferencesCompleter.future;
    await preferences?.remove('private_client_rule_providers');
    await preferences?.remove('private_client_route_script_id');
  }

  Future<void> clearPreferences() async {
    final sharedPreferencesIns = await sharedPreferencesCompleter.future;
    await sharedPreferencesIns?.clear();
  }
}

final preferences = Preferences();
