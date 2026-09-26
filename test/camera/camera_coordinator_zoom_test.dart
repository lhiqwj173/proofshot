import 'dart:async';
import 'dart:math' show Point;

import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proofshot/camera/camera_coordinator.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('后摄 0.5x 到 2x 全程在同一镜头上变焦，不重建控制器', () async {
    final CameraPlatform original = CameraPlatform.instance;
    final _ZoomCameraPlatform platform = _ZoomCameraPlatform();
    CameraPlatform.instance = platform;
    final CameraCoordinator coordinator = CameraCoordinator();
    try {
      await coordinator.initialize();
      expect(coordinator.selectedCamera?.lensType, CameraLensType.wide);
      expect(platform.createdCameras, hasLength(1));

      for (final double factor in <double>[0.5, 0.75, 1.25, 2]) {
        coordinator.setZoomFactor(factor);
        await _waitForZoom(coordinator, factor);
        expect(platform.lastZoomLevel, closeTo(factor, 0.001));
        expect(coordinator.state, CameraSessionState.ready);
      }

      expect(platform.createdCameras, hasLength(1));
      expect(platform.disposedCameras, isEmpty);
    } finally {
      await coordinator.shutdown();
      CameraPlatform.instance = original;
    }
  });

  test('超出镜头能力的倍率收敛到 0.5x 与 8x', () async {
    final CameraPlatform original = CameraPlatform.instance;
    final _ZoomCameraPlatform platform = _ZoomCameraPlatform();
    CameraPlatform.instance = platform;
    final CameraCoordinator coordinator = CameraCoordinator();
    try {
      await coordinator.initialize();

      coordinator.setZoomFactor(0.1);
      await _waitForZoom(coordinator, 0.5);

      coordinator.setZoomFactor(20);
      await _waitForZoom(coordinator, 8);
    } finally {
      await coordinator.shutdown();
      CameraPlatform.instance = original;
    }
  });

  test('能跨 0.5x 的镜头给出 0.5x、1x、2x 三档', () async {
    final CameraPlatform original = CameraPlatform.instance;
    final _ZoomCameraPlatform platform = _ZoomCameraPlatform();
    CameraPlatform.instance = platform;
    final CameraCoordinator coordinator = CameraCoordinator();
    try {
      await coordinator.initialize();

      expect(
        coordinator.zoomSteps.map((CameraZoomStep step) => step.label).toList(),
        <String>['0.5x', '1x', '2x'],
      );
    } finally {
      await coordinator.shutdown();
      CameraPlatform.instance = original;
    }
  });

  test('不能低于 1x 的镜头只给出 1x 与 2x 两档', () async {
    final CameraPlatform original = CameraPlatform.instance;
    final _ZoomCameraPlatform platform = _ZoomCameraPlatform(
      minimumZoomLevel: 1,
    );
    CameraPlatform.instance = platform;
    final CameraCoordinator coordinator = CameraCoordinator();
    try {
      await coordinator.initialize();

      expect(
        coordinator.zoomSteps.map((CameraZoomStep step) => step.label).toList(),
        <String>['1x', '2x'],
      );
    } finally {
      await coordinator.shutdown();
      CameraPlatform.instance = original;
    }
  });

  test('最大倍率不足 2x 时只给出 1x 档', () async {
    final CameraPlatform original = CameraPlatform.instance;
    final _ZoomCameraPlatform platform = _ZoomCameraPlatform(
      minimumZoomLevel: 1,
      maximumZoomLevel: 1.5,
    );
    CameraPlatform.instance = platform;
    final CameraCoordinator coordinator = CameraCoordinator();
    try {
      await coordinator.initialize();

      expect(
        coordinator.zoomSteps.map((CameraZoomStep step) => step.label).toList(),
        <String>['1x'],
      );
    } finally {
      await coordinator.shutdown();
      CameraPlatform.instance = original;
    }
  });

  test('最广档位按两位小数显示', () async {
    final CameraPlatform original = CameraPlatform.instance;
    final _ZoomCameraPlatform platform = _ZoomCameraPlatform(
      minimumZoomLevel: 0.5416666,
    );
    CameraPlatform.instance = platform;
    final CameraCoordinator coordinator = CameraCoordinator();
    try {
      await coordinator.initialize();

      expect(
        coordinator.zoomSteps.map((CameraZoomStep step) => step.label).toList(),
        <String>['0.54x', '1x', '2x'],
      );
    } finally {
      await coordinator.shutdown();
      CameraPlatform.instance = original;
    }
  });

  test('录像中跨 0.5x 变焦不报错并保持录制状态', () async {
    final CameraPlatform original = CameraPlatform.instance;
    final _ZoomCameraPlatform platform = _ZoomCameraPlatform();
    CameraPlatform.instance = platform;
    final CameraCoordinator coordinator = CameraCoordinator();
    try {
      await coordinator.initialize();
      await coordinator.setCaptureMode(CameraCaptureMode.video);
      expect(await coordinator.startVideoRecording(), isTrue);
      expect(coordinator.state, CameraSessionState.recording);

      coordinator.setZoomFactor(0.5);
      await _waitForZoom(coordinator, 0.5, state: CameraSessionState.recording);

      expect(coordinator.state, CameraSessionState.recording);
      expect(platform.lastZoomLevel, closeTo(0.5, 0.001));
    } finally {
      await coordinator.shutdown();
      CameraPlatform.instance = original;
    }
  });

  test('点按取景区自动切换手动对焦，并可切回持续自动对焦', () async {
    final CameraPlatform original = CameraPlatform.instance;
    final _ZoomCameraPlatform platform = _ZoomCameraPlatform();
    CameraPlatform.instance = platform;
    final CameraCoordinator coordinator = CameraCoordinator();
    try {
      await coordinator.initialize();
      expect(coordinator.focusMode, FocusMode.auto);
      await coordinator.setFocusPoint(const Offset(0.25, 0.7));
      expect(coordinator.focusMode, FocusMode.locked);
      expect(platform.lastFocusMode, FocusMode.locked);
      expect(platform.lastFocusPoint, const Point<double>(0.25, 0.7));
      expect(coordinator.focusPoint, const Offset(0.25, 0.7));

      await coordinator.setFocusPoint(const Offset(0.6, 0.4));
      expect(platform.lastFocusPoint, const Point<double>(0.6, 0.4));
      expect(coordinator.focusPoint, const Offset(0.6, 0.4));

      await coordinator.setFocusMode(FocusMode.auto);
      expect(platform.lastFocusMode, FocusMode.auto);
      expect(platform.lastFocusPoint, isNull);
      expect(coordinator.focusPoint, isNull);
    } finally {
      await coordinator.shutdown();
      CameraPlatform.instance = original;
    }
  });

  test('录像重建控制器后恢复手动对焦点', () async {
    final CameraPlatform original = CameraPlatform.instance;
    final _ZoomCameraPlatform platform = _ZoomCameraPlatform();
    CameraPlatform.instance = platform;
    final CameraCoordinator coordinator = CameraCoordinator();
    try {
      await coordinator.initialize();
      await coordinator.setFocusMode(FocusMode.locked);
      await coordinator.setFocusPoint(const Offset(0.3, 0.6));
      await coordinator.setCaptureMode(CameraCaptureMode.video);
      expect(await coordinator.startVideoRecording(), isTrue);
      expect(platform.createdCameras, hasLength(2));
      expect(platform.lastFocusMode, FocusMode.locked);
      expect(platform.lastFocusPoint, const Point<double>(0.3, 0.6));
      expect(coordinator.focusPoint, const Offset(0.3, 0.6));
    } finally {
      await coordinator.shutdown();
      CameraPlatform.instance = original;
    }
  });
}

Future<void> _waitForZoom(
  CameraCoordinator coordinator,
  double factor, {
  CameraSessionState state = CameraSessionState.ready,
}) async {
  final Completer<void> ready = Completer<void>();
  void check() {
    if (coordinator.state == state &&
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
  _ZoomCameraPlatform({this.minimumZoomLevel = 0.5, this.maximumZoomLevel = 8});

  static const CameraDescription _back = CameraDescription(
    name: 'back',
    lensDirection: CameraLensDirection.back,
    sensorOrientation: 90,
    lensType: CameraLensType.wide,
  );

  final double minimumZoomLevel;
  final double maximumZoomLevel;
  final List<int> createdCameras = <int>[];
  final List<int> disposedCameras = <int>[];
  final Map<int, CameraDescription> _cameras = <int, CameraDescription>{};
  final StreamController<CameraErrorEvent> _errors =
      StreamController<CameraErrorEvent>.broadcast();
  double? lastZoomLevel;
  FocusMode? lastFocusMode;
  Point<double>? lastFocusPoint;

  @override
  Future<List<CameraDescription>> availableCameras() async =>
      <CameraDescription>[_back];

  @override
  Future<int> createCameraWithSettings(
    CameraDescription cameraDescription,
    MediaSettings mediaSettings,
  ) async {
    final int id = _cameras.length + 1;
    _cameras[id] = cameraDescription;
    createdCameras.add(id);
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
  Stream<CameraErrorEvent> onCameraError(int cameraId) => _errors.stream;

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
  Future<void> setFocusMode(int cameraId, FocusMode mode) async {
    lastFocusMode = mode;
  }

  @override
  Future<void> setFocusPoint(int cameraId, Point<double>? point) async {
    lastFocusPoint = point;
  }

  @override
  Future<double> getMinZoomLevel(int cameraId) async => minimumZoomLevel;

  @override
  Future<double> getMaxZoomLevel(int cameraId) async => maximumZoomLevel;

  @override
  Future<void> setZoomLevel(int cameraId, double zoom) async {
    lastZoomLevel = zoom;
  }

  @override
  Future<void> startVideoCapturing(VideoCaptureOptions options) async {}

  @override
  Future<XFile> stopVideoRecording(int cameraId) async =>
      XFile('interrupted_video.mp4');

  @override
  Future<void> dispose(int cameraId) async {
    disposedCameras.add(cameraId);
  }
}
