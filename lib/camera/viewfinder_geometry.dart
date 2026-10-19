import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// 拍照与录像共用的竖屏成片比例。
const double captureAspectRatio = 3 / 4;

/// 将居中裁切后的取景坐标映射回完整相机预览的归一化坐标。
Offset viewfinderFocusPoint(Offset tap, Size frame, double sourceAspectRatio) {
  if (!sourceAspectRatio.isFinite ||
      sourceAspectRatio <= 0 ||
      !frame.width.isFinite ||
      frame.width <= 0 ||
      !frame.height.isFinite ||
      frame.height <= 0 ||
      !tap.dx.isFinite ||
      !tap.dy.isFinite ||
      tap.dx < 0 ||
      tap.dx > frame.width ||
      tap.dy < 0 ||
      tap.dy > frame.height) {
    throw ArgumentError('取景尺寸、原始比例或对焦坐标无效。');
  }
  final double frameAspectRatio = frame.width / frame.height;
  final double visibleWidth = math.min(1, frameAspectRatio / sourceAspectRatio);
  final double visibleHeight = math.min(
    1,
    sourceAspectRatio / frameAspectRatio,
  );
  return Offset(
    0.5 + (tap.dx / frame.width - 0.5) * visibleWidth,
    0.5 + (tap.dy / frame.height - 0.5) * visibleHeight,
  );
}

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
