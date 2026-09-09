import 'package:fl_clash/common/private_route_input.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('URL input is normalized to the hostname, never its path', () {
    expect(
      normalizePrivateRouteDestination('https://Example.COM/path?q=1#section'),
      'example.com',
    );
    expect(normalizePrivateRouteDestination('example.com.'), 'example.com');
    expect(normalizePrivateRouteDestination('2001:db8::1'), '2001:db8::1');
  });

  test(
    'rejects credentials, raw rules, unsupported schemes and malformed addresses',
    () {
      for (final input in [
        'https://user:password@example.com',
        'DOMAIN,example.com,DIRECT',
        'file:///tmp/file',
        '999.999.1.1',
        'https://999.999.1.1',
        '192.0.2.0/24',
        '2001:db8::/32',
        'com',
        '*.example.com',
      ]) {
        expect(
          () => normalizePrivateRouteDestination(input),
          throwsFormatException,
        );
      }
    },
  );

  test('simple rules preserve identity and use explicit managed targets', () {
    final rule = buildSimplePrivateRoute(
      input: 'https://example.com/a',
      target: privateRouteCurrentLine,
      includeSubdomains: true,
      id: 7,
      order: 'a0',
    );
    expect(rule.rawValue, 'DOMAIN-SUFFIX,example.com,HARBORPROXY-SERVER');
    expect(rule.id, 7);
    expect(rule.order, 'a0');
    final address = buildSimplePrivateRoute(
      input: '192.0.2.1',
      target: 'REJECT',
      includeSubdomains: true,
      id: 8,
    );
    expect(address.rawValue, 'IP-CIDR,192.0.2.1/32,REJECT');
  });

  test(
    'advanced flags and ranges are never silently flattened by the simple editor',
    () {
      expect(
        isSimplePrivateRoute(
          const Rule(
            ruleAction: RuleAction.IP_CIDR,
            content: '192.0.2.0/24',
            ruleTarget: 'DIRECT',
          ),
        ),
        isFalse,
      );
      expect(
        isSimplePrivateRoute(
          const Rule(
            ruleAction: RuleAction.IP_CIDR,
            content: '192.0.2.1/32',
            ruleTarget: 'DIRECT',
            noResolve: true,
          ),
        ),
        isFalse,
      );
      expect(
        isSimplePrivateRoute(
          const Rule(
            ruleAction: RuleAction.DOMAIN,
            content: 'example.com',
            ruleTarget: 'PrivateGroup',
          ),
        ),
        isFalse,
      );
    },
  );
}
