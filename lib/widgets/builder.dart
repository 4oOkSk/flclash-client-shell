import 'package:fl_clash/widgets/active_polling.dart';
import 'package:fl_clash/widgets/inherited.dart';
import 'package:flutter/material.dart';

typedef TickWidgetBuilder = Widget Function(BuildContext context, int tick);

class TickBuilder extends StatefulWidget {
  final Duration duration;
  final TickWidgetBuilder builder;

  const TickBuilder({super.key, required this.duration, required this.builder})
    : assert(duration > Duration.zero);

  @override
  State<TickBuilder> createState() => _TickBuilderState();
}

class _TickBuilderState extends State<TickBuilder>
    with WidgetsBindingObserver, ActivePollingMixin<TickBuilder> {
  int _tick = 0;

  @override
  Duration get pollInterval => widget.duration;

  @override
  bool get pollOnStart => false;

  @override
  Future<void> poll(PollGuard isCurrent) async {
    setState(() {
      _tick++;
    });
  }

  @override
  void didUpdateWidget(covariant TickBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.duration != widget.duration) {
      restartPolling();
    }
  }

  @override
  Widget build(BuildContext context) {
    return widget.builder(context, _tick);
  }
}

class FloatingActionButtonExtendedBuilder extends StatelessWidget {
  final Widget Function(bool isExtend) builder;

  const FloatingActionButtonExtendedBuilder({super.key, required this.builder});

  @override
  Widget build(BuildContext context) {
    final isExtended =
        CommonScaffoldFabExtendedProvider.of(context)?.isExtended ?? true;
    return builder(isExtended);
  }
}
