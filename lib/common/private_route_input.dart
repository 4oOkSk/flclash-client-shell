import 'dart:io';

import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';

const privateRouteCurrentLine = 'HARBORPROXY-SERVER';

String normalizePrivateRouteDestination(String input) {
  final value = input.trim();
  if (value.isEmpty ||
      value.length > 2048 ||
      RegExp(r'[\s,]').hasMatch(value)) {
    throw const FormatException('invalid destination');
  }
  final address = InternetAddress.tryParse(value);
  if (address != null) return address.address;
  final prefixParts = value.split('/');
  if (prefixParts.length == 2 &&
      InternetAddress.tryParse(prefixParts.first) != null &&
      RegExp(r'^\d+$').hasMatch(prefixParts.last)) {
    throw const FormatException('network requires advanced editor');
  }
  if (RegExp(r'^[0-9.]+$').hasMatch(value)) {
    throw const FormatException('invalid address');
  }
  final uri = Uri.tryParse(value.contains('://') ? value : 'https://$value');
  if (uri == null ||
      !const ['https', 'http'].contains(uri.scheme) ||
      uri.userInfo.isNotEmpty ||
      uri.host.isEmpty) {
    throw const FormatException('invalid destination');
  }
  final host = uri.host.toLowerCase().replaceFirst(RegExp(r'\.$'), '');
  if (InternetAddress.tryParse(host) != null) return host;
  if (RegExp(r'^[0-9.]+$').hasMatch(host)) {
    throw const FormatException('invalid address');
  }
  if (host.length > 253 ||
      !host.contains('.') ||
      host
          .split('.')
          .any(
            (label) => !RegExp(
              r'^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$',
            ).hasMatch(label),
          )) {
    throw const FormatException('invalid destination');
  }
  return host;
}

bool isSimplePrivateRoute(Rule rule) =>
    const [
      RuleAction.DOMAIN,
      RuleAction.DOMAIN_SUFFIX,
      RuleAction.IP_CIDR,
      RuleAction.IP_CIDR6,
    ].contains(rule.ruleAction) &&
    const [
      privateRouteCurrentLine,
      'DIRECT',
      'REJECT',
    ].contains(rule.ruleTarget) &&
    !rule.src &&
    !rule.noResolve &&
    rule.subRule == null &&
    rule.ruleProvider == null &&
    (rule.ruleAction != RuleAction.IP_CIDR &&
            rule.ruleAction != RuleAction.IP_CIDR6 ||
        rule.content?.endsWith(
              rule.ruleAction == RuleAction.IP_CIDR ? '/32' : '/128',
            ) ==
            true);

Rule buildSimplePrivateRoute({
  required String input,
  required String target,
  required bool includeSubdomains,
  required int id,
  String? order,
}) {
  if (!const [privateRouteCurrentLine, 'DIRECT', 'REJECT'].contains(target)) {
    throw const FormatException('invalid target');
  }
  final destination = normalizePrivateRouteDestination(input);
  final address = InternetAddress.tryParse(destination);
  final action = address == null
      ? (includeSubdomains ? RuleAction.DOMAIN_SUFFIX : RuleAction.DOMAIN)
      : (address.type == InternetAddressType.IPv4
            ? RuleAction.IP_CIDR
            : RuleAction.IP_CIDR6);
  return Rule(
    id: id,
    order: order,
    ruleAction: action,
    content: address == null
        ? destination
        : '$destination/${address.type == InternetAddressType.IPv4 ? 32 : 128}',
    ruleTarget: target,
  );
}
