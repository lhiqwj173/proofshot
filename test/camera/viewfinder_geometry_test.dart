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

  test('录像的 16:9 取景保留完整画面', () {
    final Rect frame = viewfinderRect(
      const Size(390, 844),
      const EdgeInsets.only(top: 47, bottom: 34),
      9 / 16,
    );
    expect(frame.width / frame.height, closeTo(9 / 16, 1e-10));
    expect(frame.top, 151);
    expect(frame.bottom, 634);
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
