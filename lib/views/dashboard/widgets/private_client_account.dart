import 'dart:math' as math;

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

class PrivateClientAccountCard extends ConsumerWidget {
  final bool adaptive;

  const PrivateClientAccountCard({super.key, this.adaptive = false});

  String _remaining(int bytes) => bytes.traffic.show;

  String _expiry(int seconds) {
    if (seconds <= 0) return '--';
    final date = DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
    String two(int value) => value.toString().padLeft(2, '0');
    return '${date.year}-${two(date.month)}-${two(date.day)}';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(privateClientAccountInfoProvider);
    final text = context.appLocalizations;
    return SizedBox(
      height: adaptive ? null : getWidgetHeight(1),
      child: CommonCard(
        info: Info(
          label: text.clientAccountOverview,
          iconData: Icons.account_balance_wallet_outlined,
        ),
        child: Padding(
          padding: baseInfoEdgeInsets.copyWith(top: 0),
          child: account.when(
            data: (value) {
              final remaining = value == null
                  ? '--'
                  : _remaining(value.remainingBytes);
              final expiry = value == null ? '--' : _expiry(value.expireAt);
              return LayoutBuilder(
                builder: (context, constraints) {
                  final valueStyle = _sharedValueStyle(
                    context,
                    constraints.maxWidth,
                    [remaining, expiry],
                  );
                  return Row(
                    children: [
                      Expanded(
                        child: _AccountValue(
                          label: text.clientDataRemaining,
                          value: remaining,
                          valueStyle: valueStyle,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _AccountValue(
                          label: text.clientExpiresOn,
                          value: expiry,
                          valueStyle: valueStyle,
                        ),
                      ),
                    ],
                  );
                },
              );
            },
            error: (_, _) => Center(child: Text(text.clientAccountUnavailable)),
            loading: () => const Center(child: CommonCircleLoading()),
          ),
        ),
      ),
    );
  }
}

TextStyle? _sharedValueStyle(
  BuildContext context,
  double availableWidth,
  List<String> values,
) {
  final baseStyle = kPrivateClientMode
      ? context.textTheme.bodyLarge
      : context.textTheme.bodyMedium?.toLight;
  if (baseStyle == null || !availableWidth.isFinite || values.isEmpty) {
    return baseStyle;
  }
  final columnWidth = math.max(0, (availableWidth - 12) / 2);
  if (columnWidth == 0) return baseStyle;
  final textDirection = Directionality.of(context);
  final textScaler = MediaQuery.textScalerOf(context);
  var widest = 0.0;
  for (final value in values) {
    final painter = TextPainter(
      text: TextSpan(text: value, style: baseStyle),
      maxLines: 1,
      textDirection: textDirection,
      textScaler: textScaler,
    )..layout();
    widest = math.max(widest, painter.width);
    painter.dispose();
  }
  if (widest <= columnWidth) return baseStyle;
  final baseFontSize =
      baseStyle.fontSize ?? DefaultTextStyle.of(context).style.fontSize ?? 14;
  return baseStyle.copyWith(fontSize: baseFontSize * columnWidth / widest);
}

class _AccountValue extends StatelessWidget {
  final String label;
  final String value;
  final TextStyle? valueStyle;

  const _AccountValue({
    required this.label,
    required this.value,
    required this.valueStyle,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.end,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: kPrivateClientMode
              ? context.textTheme.bodySmall?.copyWith(
                  color: context.colorScheme.onSurfaceVariant,
                )
              : context.textTheme.bodySmall?.toLighter,
        ),
        const SizedBox(height: 4),
        Text(
          value,
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.clip,
          style: valueStyle,
        ),
      ],
    );
  }
}

class PrivateClientWebsiteCard extends StatelessWidget {
  const PrivateClientWebsiteCard({super.key});

  Future<void> _open() async {
    final uri = Uri.tryParse(kPrivateClientWebsiteUrl);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: kPrivateClientMode ? null : getWidgetHeight(1),
      child: CommonCard(
        info: Info(
          label: context.appLocalizations.clientOfficialWebsite,
          iconData: Icons.public,
        ),
        onPressed: kPrivateClientWebsiteUrl.isEmpty ? null : _open,
        child: Padding(
          padding: baseInfoEdgeInsets.copyWith(top: 0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(
                  context.appLocalizations.clientVisitWebsite,
                  style: kPrivateClientMode
                      ? context.textTheme.bodyMedium?.copyWith(
                          color: context.colorScheme.onSurfaceVariant,
                        )
                      : context.textTheme.bodyMedium?.toLight,
                ),
              ),
              Icon(Icons.open_in_new, color: context.colorScheme.primary),
            ],
          ),
        ),
      ),
    );
  }
}
