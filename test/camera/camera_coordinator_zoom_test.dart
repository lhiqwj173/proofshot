import 'dart:async';

import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proofshot/camera/camera_coordinator.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('1x 右滑到 0.75x 会切到超广角并设置真实镜头倍率', () async {
    final CameraPlatform original = CameraPlatform.instance;
    final _ZoomCameraPlatform platform = _ZoomCameraPlatform();
    CameraPlatform.instance = platform;
    final CameraCoordinator coordinator = CameraCoordinator();
    try {
      await coordinator.initialize();
      expect(coordinator.selectedCamera?.lensType, CameraLensType.wide);

      final Future<void> ultraWideReady = _waitForZoom(
        coordinator,
        CameraLensType.ultraWide,
        0.75,
      );
      coordinator.setZoomFactor(0.75);
      await ultraWideReady;
      expect(platform.lastZoomLevel, closeTo(1.5, 0.001));

      final Future<void> wideReady = _waitForZoom(
        coordinator,
        CameraLensType.wide,
        1.25,
      );
      coordinator.setZoomFactor(1.25);
      await wideReady;
      expect(platform.lastZoomLevel, closeTo(1.25, 0.001));
    } finally {
      await coordinator.shutdown();
      CameraPlatform.instance = original;
    }
  });

  test('切镜头前的变焦写入未完成时，新镜头仍收到最新倍率', () async {
    final CameraPlatform original = CameraPlatform.instance;
    final _ZoomCameraPlatform platform = _ZoomCameraPlatform();
    CameraPlatform.instance = platform;
    final CameraCoordinator coordinator = CameraCoordinator();
    try {
      await coordinator.initialize();
      platform.holdWideZoom = Completer<void>();
      final Future<void> ultraWideWritten = platform.zoomEvents.stream
          .firstWhere(
            ((CameraLensType, double) event) =>
                event.$1 == CameraLensType.ultraWide &&
                (event.$2 - 1.5).abs() < 0.001,
          )
          .then((_) {});

      coordinator.setZoomFactor(2);
      await platform.wideZoomStarted.future.timeout(const Duration(seconds: 5));
      coordinator.setZoomFactor(0.75);
      await _waitForZoom(coordinator, CameraLensType.ultraWide, 0.75);
      platform.holdWideZoom!.complete();
      await ultraWideWritten.timeout(const Duration(seconds: 5));
    } finally {
      if (platform.holdWideZoom case final Completer<void> held) {
        if (!held.isCompleted) {
          held.complete();
        }
      }
      await coordinator.shutdown();
      CameraPlatform.instance = original;
    }
  });
}

Future<void> _waitForZoom(
  CameraCoordinator coordinator,
  CameraLensType lensType,
  double factor,
) async {
  final Completer<void> ready = Completer<void>();
  void check() {
    if (coordinator.state == CameraSessionState.ready &&
        coordinator.selectedCamera?.lensType == lensType &&
        (coordinator.zoomFactor - factor).abs() < 0.001 &&
        !ready.isCompleted) {
      ready.complete();
    }
  }

  coordinator.addListener(check);
  try {
    check();
    await ready.future.timeout(const Duration(seconds: 5));
    await Future<void>.delayed(Duration.zero);
  } finally {
    coordinator.removeListener(check);
  }
}

class _ZoomCameraPlatform extends CameraPlatform {
  static const CameraDescription _wide = CameraDescription(
    name: 'wide',
    lensDirection: CameraLensDirection.back,
    sensorOrientation: 90,
    lensType: CameraLensType.wide,
  );
  static const CameraDescription _ultraWide = CameraDescription(
    name: 'ultra-wide',
    lensDirection: CameraLensDirection.back,
    sensorOrientation: 90,
    lensType: CameraLensType.ultraWide,
  );

  int _nextId = 0;
  final Map<int, CameraDescription> _cameras = <int, CameraDescription>{};
  double? lastZoomLevel;
  Completer<void>? holdWideZoom;
  final Completer<void> wideZoomStarted = Completer<void>();
  final StreamController<(CameraLensType, double)> zoomEvents =
      StreamController<(CameraLensType, double)>.broadcast();
  final StreamController<CameraErrorEvent> _errors =
      StreamController<CameraErrorEvent>.broadcast();

  @override
  Future<List<CameraDescription>> availableCameras() async =>
      <CameraDescription>[_wide, _ultraWide];

  @override
  Future<int> createCameraWithSettings(
    CameraDescription cameraDescription,
    MediaSettings mediaSettings,
  ) async {
    final int id = ++_nextId;
    _cameras[id] = cameraDescription;
    return id;
  }

  @override
  Future<void> initializeCamera(
    int cameraId, {
    ImageFormatGroup imageFormatGroup = ImageFormatGroup.unknown,
  }) async {}

  @override
  Stream<CameraInitializedEvent> onCameraInitialized(int cameraId) =>
      Stream<CameraInitializedEvent>.value(
        CameraInitializedEvent(
          cameraId,
          1920,
          1080,
          ExposureMode.auto,
          true,
          FocusMode.auto,
          true,
        ),
      );

  @override
  Stream<CameraErrorEvent> onCameraError(int cameraId) =>
      _errors.stream;

  @override
  Stream<DeviceOrientationChangedEvent> onDeviceOrientationChanged() =>
      const Stream<DeviceOrientationChangedEvent>.empty();

  @override
  Future<void> lockCaptureOrientation(
    int cameraId,
    DeviceOrientation orientation,
  ) async {}

  @override
  Future<void> setFlashMode(int cameraId, FlashMode mode) async {}

  @override
  Future<double> getMinZoomLevel(int cameraId) async => 1;

  @override
  Future<double> getMaxZoomLevel(int cameraId) async => 8;

  @override
  Future<void> setZoomLevel(int cameraId, double zoom) async {
    final CameraLensType lens = _cameras[cameraId]!.lensType;
    if (lens == CameraLensType.wide && zoom == 2 && holdWideZoom != null) {
      wideZoomStarted.complete();
      await holdWideZoom!.future;
    }
    lastZoomLevel = zoom;
    zoomEvents.add((lens, zoom));
  }

  @override
  Future<void> dispose(int cameraId) async {}
}
