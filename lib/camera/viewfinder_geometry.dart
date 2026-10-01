import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// 为锁定竖屏的相机完整保留取景比例，控制区不参与成像。
Rect viewfinderRect(Size viewport, EdgeInsets safePadding, double aspectRatio) {
  if (!aspectRatio.isFinite || aspectRatio <= 0) {
    throw ArgumentError.value(aspectRatio, 'aspectRatio', '取景比例必须为正数。');
  }
  final double availableHeight =
      viewport.height - safePadding.top - 104 - 176 - safePadding.bottom;
  if (!viewport.width.isFinite ||
      viewport.width <= 0 ||
      !availableHeight.isFinite ||
      availableHeight <= 0) {
    throw ArgumentError.value(viewport, 'viewport', '没有足够的空间显示取景画面。');
  }
  final double height = math.min(viewport.width / aspectRatio, availableHeight);
  final double width = height * aspectRatio;
  return Rect.fromLTWH(
    (viewport.width - width) / 2,
    viewport.height - 176 - safePadding.bottom - height,
    width,
    height,
  );
}
