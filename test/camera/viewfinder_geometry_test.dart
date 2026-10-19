import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proofshot/camera/viewfinder_geometry.dart';

void main() {
  test('常规竖屏完整显示 4:3 照片，画面不进入控制区', () {
    final Rect frame = viewfinderRect(
      const Size(390, 896),
      const EdgeInsets.only(top: 47, bottom: 34),
      3 / 4,
    );
    expect(frame.width, 390);
    expect(frame.height, 520);
    expect(frame.top, greaterThanOrEqualTo(47 + 104));
    expect(frame.bottom, 896 - 176 - 34);
  });

  test('较矮屏幕缩小完整画面，不裁切左右边缘', () {
    final Rect frame = viewfinderRect(
      const Size(375, 667),
      const EdgeInsets.only(top: 20),
      3 / 4,
    );
    expect(frame.width / frame.height, closeTo(3 / 4, 1e-10));
    expect(frame.left, greaterThan(0));
    expect(frame.center.dx, 375 / 2);
    expect(frame.top, 124);
  });

  test('录像与拍照共用 3:4 取景区域，切换模式不收窄', () {
    final Rect frame = viewfinderRect(
      const Size(390, 844),
      const EdgeInsets.only(top: 47, bottom: 34),
      captureAspectRatio,
    );
    expect(frame.width / frame.height, closeTo(3 / 4, 1e-10));
    expect(frame.width, 362.25);
    expect(frame.top, 151);
    expect(frame.bottom, 634);
  });

  test('9:16 视频裁切后，对焦映射保留中央 75% 的高度', () {
    const Size frame = Size(300, 400);
    expect(
      viewfinderFocusPoint(Offset.zero, frame, 9 / 16),
      const Offset(0, 0.125),
    );
    expect(
      viewfinderFocusPoint(const Offset(300, 400), frame, 9 / 16),
      const Offset(1, 0.875),
    );
    expect(
      viewfinderFocusPoint(const Offset(150, 200), frame, 9 / 16),
      const Offset(0.5, 0.5),
    );
  });

  test('照片比例不裁切，对焦坐标保持不变', () {
    expect(
      viewfinderFocusPoint(const Offset(75, 300), const Size(300, 400), 3 / 4),
      const Offset(0.25, 0.75),
    );
  });

  test('宽画面居中裁切时，对焦映射到中央区域', () {
    expect(
      viewfinderFocusPoint(Offset.zero, const Size(300, 400), 3 / 2),
      const Offset(0.25, 0),
    );
  });

  test('无效对焦输入直接报错', () {
    for (final double ratio in <double>[0, -1, double.nan, double.infinity]) {
      expect(
        () => viewfinderFocusPoint(Offset.zero, const Size(300, 400), ratio),
        throwsArgumentError,
      );
    }
    expect(
      () => viewfinderFocusPoint(
        const Offset(-1, 0),
        const Size(300, 400),
        3 / 4,
      ),
      throwsArgumentError,
    );
    expect(
      () => viewfinderFocusPoint(Offset.zero, Size.zero, 3 / 4),
      throwsArgumentError,
    );
  });

  test('无效比例与不足的显示空间直接报错', () {
    for (final double ratio in <double>[0, -1, double.nan, double.infinity]) {
      expect(
        () => viewfinderRect(const Size(390, 844), EdgeInsets.zero, ratio),
        throwsArgumentError,
      );
    }
    expect(
      () => viewfinderRect(const Size(390, 200), EdgeInsets.zero, 3 / 4),
      throwsArgumentError,
    );
  });
}
