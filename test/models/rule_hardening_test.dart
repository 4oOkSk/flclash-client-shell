import 'package:fl_clash/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final value in [
    'DOMAIN,src.example.com,DIRECT',
    'DOMAIN,no-resolve.example.com,REJECT',
    'IP-CIDR,10.0.0.0/8,REJECT,src,no-resolve',
    'AND,((DOMAIN,example.com),(NETWORK,TCP)),REJECT',
    'OR,((DOMAIN,example.com),(AND,((NETWORK,TCP),(DST-PORT,443)))),DIRECT',
    'NOT,((DOMAIN,example.com)),REJECT',
    r'DOMAIN-REGEX,^(a,b|src.*)\.example$,DIRECT',
    'MATCH,DIRECT',
  ]) {
    test('rule round trips $value', () {
      expect(Rule.parse(value).rawValue, value);
    });
  }
  test('legacy MATCH duplicates normalize without changing Core target', () {
    expect(Rule.parse('MATCH,DIRECT,DIRECT').rawValue, 'MATCH,DIRECT');
    expect(Rule.parse('MATCH,DIRECT,REJECT').rawValue, 'MATCH,DIRECT');
  });
  test('unexpected normal-rule fields do not silently change the target', () {
    expect(
      () => Rule.parse('DOMAIN,example.com,DIRECT,invalid'),
      throwsFormatException,
    );
  });
}
