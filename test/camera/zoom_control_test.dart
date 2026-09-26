import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proofshot/camera/camera_coordinator.dart';
import 'package:proofshot/camera/zoom_control.dart';

void main() {
  const CameraZoomStep ultraWide = CameraZoomStep(camera: null, factor: 0.5);
  const CameraZoomStep wide = CameraZoomStep(camera: null, factor: 1);
  const CameraZoomStep doubleZoom = CameraZoomStep(camera: null, factor: 2);

  Future<void> pumpControl(
    WidgetTester tester, {
    required ValueChanged<double> onFactorChanged,
    required ValueChanged<CameraZoomStep> onStepSelected,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: CameraZoomControl(
              steps: const <CameraZoomStep>[ultraWide, wide, doubleZoom],
              factor: 1,
              minimumFactor: 1,
              maximumFactor: 8,
              showDial: false,
              onFactorChanged: onFactorChanged,
              onStepSelected: onStepSelected,
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('右滑 1x 可选中 0.5x 超广角', (WidgetTester tester) async {
    CameraZoomStep? selected;
    await pumpControl(
      tester,
      onFactorChanged: (_) {},
      onStepSelected: (CameraZoomStep step) => selected = step,
    );

    await tester.drag(find.byType(CameraZoomControl), const Offset(100, 0));
    await tester.pumpAndSettle();

    expect(selected, same(ultraWide));
  });

  testWidgets('左滑 1x 会放大', (WidgetTester tester) async {
    double? changedFactor;
    await pumpControl(
      tester,
      onFactorChanged: (double factor) => changedFactor = factor,
      onStepSelected: (_) {},
    );

    await tester.drag(find.byType(CameraZoomControl), const Offset(-100, 0));
    await tester.pumpAndSettle();

    expect(changedFactor, greaterThan(1));
  });
}
