import 'dart:math' as math;

import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

Duration clientMotionDuration(BuildContext context, WidgetRef ref) =>
    MediaQuery.disableAnimationsOf(context) ||
        !ref.watch(appSettingProvider.select((value) => value.isAnimateToPage))
    ? Duration.zero
    : const Duration(milliseconds: 220);

// AnimatedSize must not complete its controller synchronously during layout.
Duration clientSizeMotionDuration(BuildContext context, WidgetRef ref) {
  final duration = clientMotionDuration(context, ref);
  return duration == Duration.zero ? const Duration(microseconds: 1) : duration;
}

Future<void> selectClientPage(
  BuildContext context,
  WidgetRef ref,
  PageLabel page,
) async {
  ref.read(currentPageLabelProvider.notifier).toPage(page);
}

/// One live destination card. No outgoing image or intermediate tab is painted.
class ClientPageTransition extends StatelessWidget {
  final Animation<double> animation;
  final Axis axis;
  final double direction;
  final Widget child;

  const ClientPageTransition({
    super.key,
    required this.animation,
    required this.axis,
    required this.direction,
    required this.child,
  });

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    key: const ValueKey('client-page-viewport'),
    child: ClipRect(
      child: AnimatedBuilder(
        animation: animation,
        child: child,
        builder: (context, child) {
          final remaining = 1 - Curves.easeOutCubic.transform(animation.value);
          final offset = axis == Axis.horizontal
              ? Offset(direction * 24 * remaining, 0)
              : Offset(0, direction * 24 * remaining);
          return Transform.translate(
            offset: offset,
            child: Transform.scale(
              scale: 1 - .025 * remaining,
              child: PhysicalModel(
                color: Theme.of(context).scaffoldBackgroundColor,
                elevation: 6 * remaining,
                shadowColor: Theme.of(context).colorScheme.shadow,
                borderRadius: BorderRadius.circular(18 * remaining),
                clipBehavior: Clip.antiAlias,
                child: Opacity(opacity: 1 - .04 * remaining, child: child),
              ),
            ),
          );
        },
      ),
    ),
  );
}

/// Responsive decisions use the destination canvas, not a moving sidebar edge.
class ClientLayoutWidth extends InheritedWidget {
  final double width;

  const ClientLayoutWidth({
    super.key,
    required this.width,
    required super.child,
  });

  static double? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ClientLayoutWidth>()?.width;

  @override
  bool updateShouldNotify(ClientLayoutWidth oldWidget) =>
      width != oldWidget.width;
}

/// Reflows the same two subtrees; no outgoing layout or duplicate controls.
class ClientAdaptivePair extends ConsumerWidget {
  final bool horizontal;
  final Widget first;
  final Widget second;
  final int firstFlex;
  final int secondFlex;
  final double gap;
  final bool stretch;

  const ClientAdaptivePair({
    super.key,
    required this.horizontal,
    required this.first,
    required this.second,
    this.firstFlex = 1,
    this.secondFlex = 1,
    this.gap = 20,
    this.stretch = true,
  }) : assert(firstFlex > 0 && secondFlex > 0),
       assert(gap >= 0);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final target = horizontal ? 1.0 : 0.0;
    // A reversal starts at the displayed geometry, not the previous endpoint.
    // One clock owns widths, positions and the surrounding document height.
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: target, end: target),
      duration: clientMotionDuration(context, ref) == Duration.zero
          ? Duration.zero
          : const Duration(milliseconds: 280),
      builder: (context, progress, _) => _ClientPairLayout(
        progress: progress,
        firstFlex: firstFlex,
        secondFlex: secondFlex,
        gap: gap,
        stretch: stretch,
        textDirection: Directionality.of(context),
        children: [first, second],
      ),
    );
  }
}

// Measure real children, not intrinsics: controls may contain LayoutBuilder.
class _ClientPairLayout extends MultiChildRenderObjectWidget {
  final double progress;
  final bool stretch;
  final int firstFlex, secondFlex;
  final double gap;
  final TextDirection textDirection;
  const _ClientPairLayout({
    required this.progress,
    required this.firstFlex,
    required this.secondFlex,
    required this.gap,
    required this.stretch,
    required this.textDirection,
    required super.children,
  });
  @override
  _ClientPairRenderBox createRenderObject(BuildContext context) =>
      _ClientPairRenderBox(
        progress,
        firstFlex,
        secondFlex,
        gap,
        stretch,
        textDirection,
      );
  @override
  void updateRenderObject(
    BuildContext context,
    _ClientPairRenderBox renderObject,
  ) => renderObject.update(
    progress,
    firstFlex,
    secondFlex,
    gap,
    stretch,
    textDirection,
  );
}

class _PairParentData extends ContainerBoxParentData<RenderBox> {}

class _ClientPairRenderBox extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _PairParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _PairParentData> {
  double _progress;
  bool _stretch;
  int _firstFlex, _secondFlex;
  double _gap;
  TextDirection _textDirection;
  _ClientPairRenderBox(
    this._progress,
    this._firstFlex,
    this._secondFlex,
    this._gap,
    this._stretch,
    this._textDirection,
  );
  void update(
    double progress,
    int firstFlex,
    int secondFlex,
    double gap,
    bool stretch,
    TextDirection textDirection,
  ) {
    if ((_progress, _firstFlex, _secondFlex, _gap, _stretch, _textDirection) ==
        (progress, firstFlex, secondFlex, gap, stretch, textDirection)) {
      return;
    }
    _progress = progress;
    _firstFlex = firstFlex;
    _secondFlex = secondFlex;
    _gap = gap;
    _stretch = stretch;
    _textDirection = textDirection;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _PairParentData) {
      child.parentData = _PairParentData();
    }
  }

  @override
  void performLayout() {
    assert(childCount == 2 && constraints.hasBoundedWidth);
    final first = firstChild!,
        second = lastChild!,
        width = constraints.maxWidth;
    final available = math.max(0.0, width - _gap);
    // Shrink into opposite columns before lifting the second panel. Reversing
    // lowers it before expanding, so live controls never cross or overlap.
    final widthProgress = Curves.easeInOutCubic.transform(
      (_progress * 2).clamp(0.0, 1.0),
    );
    final liftProgress = Curves.easeInOutCubic.transform(
      (_progress * 2 - 1).clamp(0.0, 1.0),
    );
    final columnWidth = available * _firstFlex / (_firstFlex + _secondFlex);
    final firstWidth = width + (columnWidth - width) * widthProgress;
    final secondWidth =
        width + (available - columnWidth - width) * widthProgress;
    first.layout(
      BoxConstraints.tightFor(width: firstWidth),
      parentUsesSize: true,
    );
    second.layout(
      BoxConstraints.tightFor(width: secondWidth),
      parentUsesSize: true,
    );
    final firstHeight = first.size.height, secondHeight = second.size.height;
    if (_stretch && liftProgress > 0) {
      final rowHeight = math.max(firstHeight, secondHeight);
      first.layout(
        BoxConstraints.tight(
          Size(
            firstWidth,
            firstHeight + (rowHeight - firstHeight) * liftProgress,
          ),
        ),
        parentUsesSize: true,
      );
      second.layout(
        BoxConstraints.tight(
          Size(
            secondWidth,
            secondHeight + (rowHeight - secondHeight) * liftProgress,
          ),
        ),
        parentUsesSize: true,
      );
    }
    final secondY = (firstHeight + _gap) * (1 - liftProgress);
    size = constraints.constrain(
      Size(width, math.max(first.size.height, secondY + second.size.height)),
    );
    final firstData = first.parentData! as _PairParentData,
        secondData = second.parentData! as _PairParentData;
    firstData.offset = _textDirection == TextDirection.rtl
        ? Offset(width - firstWidth, 0)
        : Offset.zero;
    secondData.offset = Offset(
      _textDirection == TextDirection.rtl ? 0 : width - secondWidth,
      secondY,
    );
  }

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);
  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}
