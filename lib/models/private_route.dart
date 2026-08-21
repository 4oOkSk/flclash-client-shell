import 'dart:convert';

import 'package:fl_clash/enum/enum.dart';

const privateRuleProviderBehaviors = <String>['domain', 'ipcidr', 'classical'];

const privateRuleProviderFormats = <String>['yaml', 'text', 'mrs'];

class PrivateRuleProviderConfig {
  final String name;
  final String url;
  final String behavior;
  final String format;
  final int interval;

  const PrivateRuleProviderConfig({
    required this.name,
    required this.url,
    this.behavior = 'classical',
    this.format = 'yaml',
    this.interval = 86400,
  });

  factory PrivateRuleProviderConfig.fromJson(Map<String, dynamic> json) {
    final intervalValue = json['interval'];
    final interval = switch (intervalValue) {
      final int value => value,
      final num value => value.toInt(),
      final String value => int.tryParse(value),
      _ => null,
    };
    final provider = PrivateRuleProviderConfig(
      name: (json['name'] as String? ?? '').trim(),
      url: (json['url'] as String? ?? '').trim(),
      behavior: (json['behavior'] as String? ?? 'classical').toLowerCase(),
      format: (json['format'] as String? ?? 'yaml').toLowerCase(),
      interval: interval ?? 86400,
    );
    provider.validate();
    return provider;
  }

  factory PrivateRuleProviderConfig.fromScriptEntry(
    String name,
    Object? value,
  ) {
    if (value is! Map) {
      throw const FormatException('rule provider must be an object');
    }
    return PrivateRuleProviderConfig.fromJson({
      'name': name,
      ...value.map((key, value) => MapEntry(key.toString(), value)),
    });
  }

  void validate() {
    if (name.isEmpty ||
        name.length > 64 ||
        name.contains(',') ||
        name.contains('\n') ||
        name.contains('\r') ||
        name.startsWith('__neutralvendor_local_')) {
      throw const FormatException('invalid rule provider name');
    }
    final uri = Uri.tryParse(url);
    if (url.length > 2048 ||
        uri == null ||
        uri.scheme.toLowerCase() != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      throw const FormatException('rule provider URL must use HTTPS');
    }
    if (!privateRuleProviderBehaviors.contains(behavior)) {
      throw const FormatException('invalid rule provider behavior');
    }
    if (!privateRuleProviderFormats.contains(format)) {
      throw const FormatException('invalid rule provider format');
    }
    if (format == 'mrs' && behavior == 'classical') {
      throw const FormatException(
        'mrs rule provider must use domain or ipcidr behavior',
      );
    }
    if (interval < 300 || interval > 604800) {
      throw const FormatException('invalid rule provider interval');
    }
  }

  Map<String, Object> toJson() {
    return {
      'name': name,
      'url': url,
      'behavior': behavior,
      'format': format,
      'interval': interval,
    };
  }

  Map<String, Object> toScriptJson() {
    return {
      'type': 'http',
      'url': url,
      'behavior': behavior,
      'format': format,
      'interval': interval,
    };
  }

  PrivateRuleProviderConfig copyWith({
    String? name,
    String? url,
    String? behavior,
    String? format,
    int? interval,
  }) {
    return PrivateRuleProviderConfig(
      name: name ?? this.name,
      url: url ?? this.url,
      behavior: behavior ?? this.behavior,
      format: format ?? this.format,
      interval: interval ?? this.interval,
    );
  }
}

class PrivateRouteOverlay {
  final List<String> rules;
  final List<PrivateRuleProviderConfig> ruleProviders;
  final PrivateManagedRouting? managedRouting;

  const PrivateRouteOverlay({
    this.rules = const [],
    this.ruleProviders = const [],
    this.managedRouting,
  });

  factory PrivateRouteOverlay.fromScriptResult(
    Map<String, dynamic> value, {
    PrivateManagedRouting? managedRouting,
  }) {
    final rawRules = value['rules'] ?? const <Object>[];
    if (rawRules is! List) {
      throw const FormatException('script rules must be a list');
    }
    if (rawRules.length > 5000) {
      throw const FormatException('too many local rules');
    }
    final rules = rawRules
        .map((item) {
          if (item is! String || item.isEmpty || item.length > 4096) {
            throw const FormatException('invalid local rule');
          }
          return item;
        })
        .toList(growable: false);

    final rawProviders = value['rule-providers'] ?? const <String, Object>{};
    if (rawProviders is! Map) {
      throw const FormatException('script rule-providers must be an object');
    }
    if (rawProviders.length > 64) {
      throw const FormatException('too many local rule providers');
    }
    final providers = rawProviders.entries
        .map(
          (entry) => PrivateRuleProviderConfig.fromScriptEntry(
            entry.key.toString(),
            entry.value,
          ),
        )
        .toList(growable: false);
    final names = providers.map((item) => item.name).toSet();
    if (names.length != providers.length) {
      throw const FormatException('duplicate local rule provider');
    }
    return PrivateRouteOverlay(
      rules: rules,
      ruleProviders: providers,
      managedRouting: managedRouting,
    );
  }

  bool get isEmpty =>
      rules.isEmpty && ruleProviders.isEmpty && managedRouting == null;

  PrivateRouteOverlay copyWith({
    List<String>? rules,
    List<PrivateRuleProviderConfig>? ruleProviders,
    PrivateManagedRouting? managedRouting,
  }) {
    return PrivateRouteOverlay(
      rules: rules ?? this.rules,
      ruleProviders: ruleProviders ?? this.ruleProviders,
      managedRouting: managedRouting ?? this.managedRouting,
    );
  }

  Map<String, Object> toJson() {
    return {
      'rules': rules,
      'rule-providers': {
        for (final provider in ruleProviders)
          provider.name: provider.toJson()..remove('name'),
      },
      if (managedRouting != null) 'managed-routing': managedRouting!.toJson(),
    };
  }

  Map<String, dynamic> toScriptConfig(Iterable<String> routeTargets) {
    final encoded = jsonEncode({
      'rules': rules,
      'rule-providers': {
        for (final provider in ruleProviders)
          provider.name: provider.toScriptJson(),
      },
      'proxy-groups': routeTargets
          .toSet()
          .map((name) => {'name': name})
          .toList(growable: false),
      'proxies': const <Object>[],
      'proxy-providers': const <String, Object>{},
    });
    return Map<String, dynamic>.from(jsonDecode(encoded) as Map);
  }
}

class PrivateManagedRouting {
  final ManagedRouteMode mode;
  final bool rejectIpv6;

  const PrivateManagedRouting({required this.mode, this.rejectIpv6 = false});

  Map<String, Object> toJson() {
    return {
      'mode': mode.wireValue,
      // Keep a rollback-compatible wire representation while Go and Dart move
      // to [mode] as the only runtime source of truth.
      'bypass-mainland': mode.bypassesMainland,
      'bypass-overseas': mode.bypassesOverseas,
      'reject-ipv6': rejectIpv6,
    };
  }
}
