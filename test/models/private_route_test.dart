import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/private_route.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PrivateRuleProviderConfig', () {
    test('round trips supported fields', () {
      const provider = PrivateRuleProviderConfig(
        name: 'ads',
        url: 'https://example.com/ads.mrs',
        behavior: 'domain',
        format: 'mrs',
        interval: 3600,
      );
      final restored = PrivateRuleProviderConfig.fromJson(provider.toJson());
      expect(restored.name, provider.name);
      expect(restored.url, provider.url);
      expect(restored.behavior, provider.behavior);
      expect(restored.format, provider.format);
      expect(restored.interval, provider.interval);
    });

    test('rejects non-HTTPS URLs', () {
      expect(
        () => const PrivateRuleProviderConfig(
          name: 'unsafe',
          url: 'file:///etc/passwd',
        ).validate(),
        throwsFormatException,
      );
    });

    test('rejects classical MRS rule sets', () {
      expect(
        () => const PrivateRuleProviderConfig(
          name: 'invalid-mrs',
          url: 'https://example.com/rules.mrs',
          behavior: 'classical',
          format: 'mrs',
        ).validate(),
        throwsFormatException,
      );
    });
  });

  group('PrivateRouteOverlay', () {
    test('extracts only rules and typed rule providers from script result', () {
      final overlay = PrivateRouteOverlay.fromScriptResult({
        'rules': ['DOMAIN,example.com,DIRECT'],
        'rule-providers': {
          'local': {
            'type': 'file',
            'path': '/etc/passwd',
            'url': 'https://example.com/rules.yaml',
            'behavior': 'classical',
            'format': 'yaml',
            'interval': 86400,
          },
        },
        'proxies': [
          {'name': 'must-not-survive'},
        ],
      });
      expect(overlay.rules, ['DOMAIN,example.com,DIRECT']);
      expect(overlay.ruleProviders, hasLength(1));
      expect(overlay.ruleProviders.single.name, 'local');
      expect(overlay.ruleProviders.single.toJson(), isNot(contains('path')));
      expect(overlay.toJson(), isNot(contains('proxies')));
    });

    test('builds a script input without proxy endpoint fields', () {
      const overlay = PrivateRouteOverlay(
        rules: ['DOMAIN,example.com,DIRECT'],
        ruleProviders: [
          PrivateRuleProviderConfig(
            name: 'local',
            url: 'https://example.com/rules.yaml',
          ),
        ],
      );
      final config = overlay.toScriptConfig(['Proxy', 'DIRECT']);
      expect(config['proxies'], isEmpty);
      expect(config['proxy-providers'], isEmpty);
      expect(config['proxy-groups'], [
        {'name': 'Proxy'},
        {'name': 'DIRECT'},
      ]);
      expect(config.toString(), isNot(contains('server')));
    });

    test('serializes managed routing without exposing proxy fields', () {
      const overlay = PrivateRouteOverlay(
        managedRouting: PrivateManagedRouting(
          mode: ManagedRouteMode.bypassMainland,
        ),
      );

      expect(overlay.isEmpty, isFalse);
      expect(overlay.toJson()['managed-routing'], {
        'mode': 'bypass-mainland',
        'bypass-mainland': true,
        'bypass-overseas': false,
        'reject-ipv6': false,
      });
      expect(overlay.toJson(), isNot(contains('proxies')));
    });
  });
}
