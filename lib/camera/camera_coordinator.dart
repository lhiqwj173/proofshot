import 'dart:async';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

enum CameraCaptureMode { photo, video }

/// A zoom shortcut offered by the camera zoom control.
@immutable
class CameraZoomStep {
  const CameraZoomStep({required this.factor});

  /// The zoom factor relative to the wide angle lens of the back camera, for example `0.5` or `2`.
  final double factor;

  /// The factor the lens shows on its own, for example `1x` or `0.5x`.
  String get label {
    final double rounded = (factor * 100).roundToDouble() / 100;
    final String value = rounded % 1 == 0
        ? rounded.toInt().toString()
        : rounded.toStringAsFixed(2).replaceFirst(RegExp(r'0+$'), '');
    return '${value}x';
  }
}

enum CameraSessionState {
  idle,
  requestingPermission,
  initializing,
  ready,
  recording,
  processing,
  interrupted,
  error,
  disposed,
}

/// Owns the app's only camera controller and serializes camera operations.
class CameraCoordinator extends ChangeNotifier with WidgetsBindingObserver {
  CameraCoordinator();

  CameraSessionState _state = CameraSessionState.idle;
  CameraCaptureMode _captureMode = CameraCaptureMode.photo;
  CameraController? _controller;
  CameraDescription? _selectedCamera;
  List<CameraDescription> _availableCameras = <CameraDescription>[];
  CameraException? _lastCameraException;
  XFile? _pendingInterruptedRecording;
  FlashMode _flashMode = FlashMode.off;
  FocusMode _focusMode = FocusMode.auto;
  Offset? _focusPoint;
  double _minZoomLevel = 1;
  double _maxZoomLevel = 1;
  double _zoomLevel = 1;
  double? _queuedZoomLevel;
  bool _zoomDraining = false;
  Future<void> _operationTail = Future<void>.value();
  Future<void>? _shutdownFuture;
  int _generation = 0;
  bool _controllerHasAudio = false;
  bool _isBackgrounded = false;
  bool _observerRegistered = false;
  bool _isShuttingDown = false;

  CameraSessionState get state => _state;
  int get generation => _generation;
  CameraCaptureMode get captureMode => _captureMode;
  FlashMode get flashMode => _flashMode;
  FocusMode get focusMode => _focusMode;
  Offset? get focusPoint => _focusPoint;
  bool get focusPointSupported =>
      _controller?.value.focusPointSupported == true;
  CameraController? get controller => _controller;
  CameraDescription? get selectedCamera => _selectedCamera;
  bool get canSwitchCamera => _hasCameraDirection(
    _selectedCamera?.lensDirection == CameraLensDirection.back
        ? CameraLensDirection.front
        : CameraLensDirection.back,
  );
  bool get hasHardwareFlash => _supportsFlash(_selectedCamera);
  String? get flashUnavailableReason {
    if (_selectedCamera == null) {
      return '相机尚未就绪。';
    }
    return hasHardwareFlash ? null : '当前前置摄像头不支持硬件闪光灯或补光。';
  }

  Set<FlashMode> get supportedFlashModes =>
      _supportedFlashModesFor(_captureMode, _selectedCamera);
  CameraException? get lastCameraException => _lastCameraException;
  XFile? get pendingInterruptedRecording => _pendingInterruptedRecording;
  bool get isBackCameraSelected =>
      _selectedCamera?.lensDirection == CameraLensDirection.back;

  /// The zoom shown to the user, where `1` is the wide angle lens of the back camera and `0.5`
  /// the ultra wide angle lens of a device that hands off between the two lenses.
  double get zoomFactor => _zoomLevel;
  double get minimumZoomFactor => _minZoomLevel;
  double get maximumZoomFactor => _maxZoomLevel;

  /// Zoom shortcuts for the selected back lens, ordered by reach.
  List<CameraZoomStep> get zoomSteps {
    if (!isBackCameraSelected || _controller == null) {
      return const <CameraZoomStep>[];
    }
    final double widest = minimumZoomFactor;
    final double maximum = maximumZoomFactor;
    return <CameraZoomStep>[
      if (widest < 1) CameraZoomStep(factor: widest),
      const CameraZoomStep(factor: 1),
      if (maximum >= 2) const CameraZoomStep(factor: 2),
    ];
  }

  String? get cameraErrorText {
    final CameraException? error = _lastCameraException;
    if (error == null) {
      return null;
    }
    final String? description = error.description;
    return description == null || description.isEmpty
        ? error.code
        : '${error.code}: $description';
  }

  Future<void> initialize() {
    _ensureOpen();
    if (!_observerRegistered) {
      WidgetsBinding.instance.addObserver(this);
      _observerRegistered = true;
    }
    return _run<void>(_initializeInternal);
  }

  Future<void> retry() {
    _ensureOpen();
    return _run<void>(() async {
      if (_state != CameraSessionState.error &&
          _state != CameraSessionState.interrupted) {
        throw StateError(
          'Camera retry is only valid after an error or interruption.',
        );
      }
      _lastCameraException = null;
      await _initializeInternal();
    });
  }

  Future<void> setCaptureMode(CameraCaptureMode mode) {
    _ensureOpen();
    return _run<void>(() async {
      if (_state != CameraSessionState.ready) {
        throw StateError(
          'Capture mode can only change while the camera is ready.',
        );
      }
      if (_captureMode == mode) {
        return;
      }

      if (!_supportedFlashModesFor(
        mode,
        _selectedCamera,
      ).contains(_flashMode)) {
        final CameraController controller = _requireController();
        try {
          await controller.setFlashMode(FlashMode.off);
        } on CameraException catch (error) {
          _recordCameraException(error);
          return;
        }
        _flashMode = FlashMode.off;
      }
      _captureMode = mode;
      notifyListeners();
    });
  }

  Future<void> setFlashMode(FlashMode mode) {
    _ensureOpen();
    return _run<void>(() async {
      if (_state != CameraSessionState.ready) {
        throw StateError(
          'Flash mode can only change while the camera is ready.',
        );
      }
      if (!supportedFlashModes.contains(mode)) {
        throw ArgumentError.value(
          mode,
          'mode',
          'Flash mode is not supported by the selected camera and capture mode.',
        );
      }
      final CameraController controller = _requireController();
      try {
        await controller.setFlashMode(mode);
      } on CameraException catch (error) {
        _recordCameraException(error);
        return;
      }
      _flashMode = mode;
      notifyListeners();
    });
  }

  Future<void> setFocusMode(FocusMode mode) {
    _ensureOpen();
    return _run<void>(() async {
      if (_state != CameraSessionState.ready &&
          _state != CameraSessionState.recording) {
        throw StateError(
          'Focus mode can only change while the camera is active.',
        );
      }
      if (mode == FocusMode.locked && !focusPointSupported) {
        throw StateError('The selected camera does not support focus points.');
      }
      if (_focusMode == mode) {
        return;
      }
      final CameraController controller = _requireController();
      try {
        await controller.setFocusMode(mode);
        if (mode == FocusMode.auto) {
          await controller.setFocusPoint(null);
        }
      } on CameraException catch (error) {
        _recordCameraException(error);
        rethrow;
      }
      _focusMode = mode;
      _focusPoint = null;
      notifyListeners();
    });
  }

  Future<void> setFocusPoint(Offset point) {
    _ensureOpen();
    if (!point.dx.isFinite ||
        !point.dy.isFinite ||
        point.dx < 0 ||
        point.dx > 1 ||
        point.dy < 0 ||
        point.dy > 1) {
      throw ArgumentError.value(
        point,
        'point',
        'Focus point must be within the unit square.',
      );
    }
    return _run<void>(() async {
      if (_state != CameraSessionState.ready &&
          _state != CameraSessionState.recording) {
        throw StateError(
          'Focus point can only change while the camera is active.',
        );
      }
      if (!focusPointSupported) {
        throw StateError('The selected camera does not support focus points.');
      }
      try {
        final CameraController controller = _requireController();
        if (_focusMode != FocusMode.locked) {
          await controller.setFocusMode(FocusMode.locked);
        }
        await controller.setFocusPoint(point);
      } on CameraException catch (error) {
        _recordCameraException(error);
        rethrow;
      }
      _focusMode = FocusMode.locked;
      _focusPoint = point;
      notifyListeners();
    });
  }

  /// Applies a zoom factor on the selected lens, clamped to what it can reach.
  void setZoomFactor(double factor) {
    _ensureOpen();
    if (!factor.isFinite || factor <= 0) {
      throw ArgumentError.value(factor, 'factor', 'Zoom must be positive.');
    }
    if (_state != CameraSessionState.ready &&
        _state != CameraSessionState.recording) {
      throw StateError('Zoom can only change while the camera is active.');
    }
    final double level = math.min(
      _maxZoomLevel,
      math.max(_minZoomLevel, factor),
    );
    if (level == _zoomLevel) {
      return;
    }
    _zoomLevel = level;
    _queuedZoomLevel = level;
    notifyListeners();
    unawaited(_drainZoomQueue());
  }

  Future<void> switchCamera() {
    _ensureOpen();
    return _run<void>(() async {
      if (_state != CameraSessionState.ready) {
        throw StateError('Camera can only switch while ready.');
      }
      final CameraDescription currentCamera = _requireSelectedCamera();
      final CameraLensDirection targetDirection =
          currentCamera.lensDirection == CameraLensDirection.back
          ? CameraLensDirection.front
          : CameraLensDirection.back;
      CameraDescription? targetCamera;
      for (final CameraDescription camera in _availableCameras) {
        if (camera.lensDirection == targetDirection) {
          targetCamera = camera;
          break;
        }
      }
      if (targetCamera == null) {
        throw StateError(
          'No ${targetDirection.name} camera is available to switch to.',
        );
      }

      _selectedCamera = targetCamera;
      _setState(CameraSessionState.initializing);
      await _installController(
        targetCamera,
        enableAudio: false,
        flashToRestore: FlashMode.off,
      );
    });
  }

  Future<XFile> takePicture() {
    _ensureOpen();
    return _run<XFile>(() async {
      if (_state != CameraSessionState.ready ||
          _captureMode != CameraCaptureMode.photo) {
        throw StateError('A photo can only be captured in ready photo mode.');
      }
      final CameraController controller = _requireController();
      _setState(CameraSessionState.processing);
      try {
        return await controller.takePicture();
      } on CameraException catch (error) {
        _recordCameraException(error);
        rethrow;
      }
    });
  }

  Future<bool> startVideoRecording({void Function()? onRecordingStarting}) {
    _ensureOpen();
    return _run<bool>(() async {
      if (_state != CameraSessionState.ready ||
          _captureMode != CameraCaptureMode.video) {
        throw StateError('Video recording can only start in ready video mode.');
      }

      if (!_controllerHasAudio) {
        _setState(CameraSessionState.requestingPermission);
        final CameraDescription camera = _requireSelectedCamera();
        final bool audioControllerReady = await _installController(
          camera,
          enableAudio: true,
          flashToRestore: _flashMode,
        );
        if (!audioControllerReady) {
          return false;
        }
      }
      if (_isBackgrounded) {
        _setState(CameraSessionState.interrupted);
        return false;
      }

      final CameraController controller = _requireController();
      onRecordingStarting?.call();
      _setState(CameraSessionState.initializing);
      try {
        await controller.startVideoRecording();
      } on CameraException catch (error) {
        _recordCameraException(error);
        rethrow;
      }
      _setState(CameraSessionState.recording);
      return true;
    });
  }

  Future<XFile> stopVideoRecording({bool interrupted = false}) {
    _ensureOpen();
    return _run<XFile>(() async {
      if (_state != CameraSessionState.recording) {
        throw StateError('A video can only stop while recording.');
      }
      return _stopRecordingInternal(interrupted: interrupted);
    });
  }

  XFile? takePendingInterruptedRecording() {
    _ensureOpen();
    if (_state != CameraSessionState.processing) {
      throw StateError(
        'An interrupted recording can only be consumed while processing.',
      );
    }
    final XFile? recording = _pendingInterruptedRecording;
    _pendingInterruptedRecording = null;
    return recording;
  }

  Future<void> finishProcessing() {
    _ensureOpen();
    return _run<void>(() async {
      if (_state != CameraSessionState.processing) {
        throw StateError(
          'Camera processing can only finish from processing state.',
        );
      }
      if (_pendingInterruptedRecording != null) {
        throw StateError(
          'The interrupted recording must be handled before processing can finish.',
        );
      }
      if (_isBackgrounded) {
        _setState(CameraSessionState.interrupted);
      } else if (_controller?.value.isInitialized == true) {
        _setState(CameraSessionState.ready);
      } else {
        _setState(CameraSessionState.interrupted);
      }
    });
  }

  Future<void> shutdown() => _shutdownFuture ??= _shutdown();

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_isShuttingDown) {
      return;
    }
    switch (state) {
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        if (_isBackgrounded) {
          return;
        }
        _isBackgrounded = true;
        _generation++;
        unawaited(_run<void>(_suspendInternal));
      case AppLifecycleState.resumed:
        if (!_isBackgrounded) {
          return;
        }
        _isBackgrounded = false;
        _generation++;
        unawaited(_run<void>(_initializeInternal));
    }
  }

  Future<void> _initializeInternal() async {
    if (_isShuttingDown) {
      throw StateError('Camera coordinator is shutting down.');
    }
    if (_isBackgrounded) {
      _setState(CameraSessionState.interrupted);
      return;
    }
    if (_controller?.value.isInitialized == true &&
        (_state == CameraSessionState.ready ||
            _state == CameraSessionState.processing ||
            _state == CameraSessionState.recording)) {
      return;
    }

    _setState(CameraSessionState.requestingPermission);
    late final List<CameraDescription> cameras;
    try {
      cameras = await availableCameras();
    } on CameraException catch (error) {
      _recordCameraException(error);
      return;
    }
    if (cameras.isEmpty) {
      _recordCameraException(
        CameraException('no_available_cameras', 'No camera is available.'),
      );
      return;
    }

    _availableCameras = List<CameraDescription>.unmodifiable(cameras);
    final String? selectedCameraName = _selectedCamera?.name;
    CameraDescription? refreshedSelection;
    if (selectedCameraName != null) {
      for (final CameraDescription camera in _availableCameras) {
        if (camera.name == selectedCameraName) {
          refreshedSelection = camera;
          break;
        }
      }
    }
    final CameraDescription camera =
        refreshedSelection ?? _defaultCamera(_availableCameras);
    _selectedCamera = camera;
    await _installController(
      camera,
      enableAudio: false,
      flashToRestore: FlashMode.off,
    );
  }

  Future<bool> _installController(
    CameraDescription camera, {
    required bool enableAudio,
    required FlashMode flashToRestore,
  }) async {
    try {
      await _releaseCurrentController();
    } on CameraException catch (error) {
      _recordCameraException(error);
      return false;
    }
    if (_isShuttingDown) {
      return false;
    }
    if (_isBackgrounded) {
      _setState(CameraSessionState.interrupted);
      return false;
    }
    final int operationGeneration = ++_generation;
    final CameraController candidate = CameraController(
      camera,
      ResolutionPreset.veryHigh,
      enableAudio: enableAudio,
    );
    _setState(CameraSessionState.initializing);

    try {
      await candidate.initialize();
      if (!_isCurrentGeneration(operationGeneration)) {
        await candidate.dispose();
        return false;
      }
      await candidate.lockCaptureOrientation(DeviceOrientation.portraitUp);
      if (!_isCurrentGeneration(operationGeneration)) {
        await candidate.dispose();
        return false;
      }
      final Set<FlashMode> allowedModes = _supportedFlashModesFor(
        _captureMode,
        camera,
      );
      final FlashMode modeToApply = allowedModes.contains(flashToRestore)
          ? flashToRestore
          : FlashMode.off;
      if (_supportsFlash(camera)) {
        await candidate.setFlashMode(modeToApply);
      }
      final bool supportsFocusPoint = candidate.value.focusPointSupported;
      final FocusMode modeToRestore = supportsFocusPoint
          ? _focusMode
          : FocusMode.auto;
      await candidate.setFocusMode(modeToRestore);
      if (supportsFocusPoint &&
          _focusPoint != null &&
          modeToRestore == FocusMode.locked) {
        await candidate.setFocusPoint(_focusPoint);
      }
      if (!_isCurrentGeneration(operationGeneration)) {
        await candidate.dispose();
        return false;
      }
      final double minZoomLevel = await candidate.getMinZoomLevel();
      final double maxZoomLevel = await candidate.getMaxZoomLevel();
      if (!_isCurrentGeneration(operationGeneration)) {
        await candidate.dispose();
        return false;
      }

      _controller = candidate;
      _controllerHasAudio = enableAudio;
      _flashMode = modeToApply;
      _focusMode = modeToRestore;
      if (!supportsFocusPoint) {
        _focusPoint = null;
      }
      _minZoomLevel = minZoomLevel;
      _maxZoomLevel = maxZoomLevel;
      _zoomLevel = 1;
      _queuedZoomLevel = null;
      _lastCameraException = null;
      _setState(
        _pendingInterruptedRecording == null
            ? CameraSessionState.ready
            : CameraSessionState.processing,
      );
      return true;
    } on CameraException catch (error) {
      try {
        await candidate.dispose();
      } on CameraException catch (disposeError, disposeStackTrace) {
        if (disposeError.code != error.code ||
            disposeError.description != error.description) {
          Error.throwWithStackTrace(disposeError, disposeStackTrace);
        }
      }
      if (_isCurrentGeneration(operationGeneration)) {
        _recordCameraException(error);
      }
      return false;
    } on Object catch (error, stackTrace) {
      try {
        await candidate.dispose();
      } on Object catch (disposeError, disposeStackTrace) {
        if (!identical(disposeError, error)) {
          Error.throwWithStackTrace(disposeError, disposeStackTrace);
        }
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<void> _drainZoomQueue() async {
    if (_zoomDraining) {
      return;
    }
    _zoomDraining = true;
    try {
      while (true) {
        final double? target = _queuedZoomLevel;
        final CameraController? controller = _controller;
        if (target == null ||
            controller == null ||
            !controller.value.isInitialized) {
          return;
        }
        _queuedZoomLevel = null;
        try {
          await controller.setZoomLevel(target);
        } on CameraException catch (error) {
          if (identical(_controller, controller)) {
            _recordCameraException(error);
            rethrow;
          }
          return;
        } on StateError {
          if (identical(_controller, controller)) {
            rethrow;
          }
          return;
        }
      }
    } finally {
      _zoomDraining = false;
      if (_queuedZoomLevel != null &&
          _controller?.value.isInitialized == true &&
          (_state == CameraSessionState.ready ||
              _state == CameraSessionState.recording)) {
        unawaited(_drainZoomQueue());
      }
    }
  }

  Future<XFile> _stopRecordingInternal({required bool interrupted}) async {
    final CameraController controller = _requireController();
    _setState(CameraSessionState.processing);
    late final XFile recording;
    try {
      recording = await controller.stopVideoRecording();
    } on CameraException catch (error) {
      _recordCameraException(error);
      rethrow;
    }
    if (interrupted) {
      _pendingInterruptedRecording = recording;
    }
    _setState(CameraSessionState.processing);
    return recording;
  }

  Future<void> _suspendInternal() async {
    if (_state == CameraSessionState.recording) {
      try {
        await _stopRecordingInternal(interrupted: true);
      } on CameraException catch (error) {
        _recordCameraException(error);
      }
    }

    try {
      await _releaseCurrentController();
    } on CameraException catch (error) {
      _recordCameraException(error);
    }

    if (_pendingInterruptedRecording != null) {
      _setState(CameraSessionState.processing);
    } else if (_state != CameraSessionState.error) {
      _setState(CameraSessionState.interrupted);
    }
  }

  Future<void> _shutdown() async {
    _isShuttingDown = true;
    if (_observerRegistered) {
      WidgetsBinding.instance.removeObserver(this);
      _observerRegistered = false;
    }
    try {
      await _run<void>(() async {
        if (_state == CameraSessionState.recording) {
          try {
            await _stopRecordingInternal(interrupted: true);
          } on CameraException catch (error) {
            _recordCameraException(error);
          }
        }
        try {
          await _releaseCurrentController();
        } on CameraException catch (error) {
          _recordCameraException(error);
        }
        _state = CameraSessionState.disposed;
      });
    } finally {
      super.dispose();
    }
  }

  Future<void> _releaseCurrentController() async {
    final CameraController? controller = _controller;
    _controller = null;
    _controllerHasAudio = false;
    _zoomLevel = 1;
    _queuedZoomLevel = null;
    if (controller != null) {
      try {
        if (controller.value.isInitialized && _flashMode != FlashMode.off) {
          await controller.setFlashMode(FlashMode.off);
        }
      } finally {
        _flashMode = FlashMode.off;
        await controller.dispose();
      }
    }
  }

  CameraController _requireController() {
    final CameraController? controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      throw StateError('Camera controller is not initialized.');
    }
    return controller;
  }

  CameraDescription _requireSelectedCamera() {
    final CameraDescription? camera = _selectedCamera;
    if (camera == null) {
      throw StateError('No camera has been selected.');
    }
    return camera;
  }

  CameraDescription _defaultCamera(List<CameraDescription> cameras) {
    final CameraDescription? wideAngle = _backCameraOfType(CameraLensType.wide);
    if (wideAngle != null) {
      return wideAngle;
    }
    for (final CameraDescription camera in cameras) {
      if (camera.lensDirection == CameraLensDirection.back) {
        return camera;
      }
    }
    return cameras.first;
  }

  CameraDescription? _backCameraOfType(CameraLensType lensType) {
    for (final CameraDescription camera in _availableCameras) {
      if (camera.lensDirection == CameraLensDirection.back &&
          camera.lensType == lensType) {
        return camera;
      }
    }
    return null;
  }

  bool _supportsFlash(CameraDescription? camera) =>
      camera?.lensDirection == CameraLensDirection.back &&
      camera?.lensType != CameraLensType.ultraWide;

  bool _hasCameraDirection(CameraLensDirection direction) {
    for (final CameraDescription camera in _availableCameras) {
      if (camera.lensDirection == direction) {
        return true;
      }
    }
    return false;
  }

  Set<FlashMode> _supportedFlashModesFor(
    CameraCaptureMode mode,
    CameraDescription? camera,
  ) {
    if (!_supportsFlash(camera)) {
      return const <FlashMode>{FlashMode.off};
    }
    return switch (mode) {
      CameraCaptureMode.photo => const <FlashMode>{
        FlashMode.off,
        FlashMode.always,
        FlashMode.auto,
      },
      CameraCaptureMode.video => const <FlashMode>{
        FlashMode.off,
        FlashMode.torch,
      },
    };
  }

  bool _isCurrentGeneration(int generation) =>
      generation == _generation && !_isBackgrounded && !_isShuttingDown;

  void _recordCameraException(CameraException error) {
    _lastCameraException = error;
    _setState(CameraSessionState.error);
  }

  void _setState(CameraSessionState state) {
    _state = state;
    if (!_isShuttingDown) {
      notifyListeners();
    }
  }

  void _ensureOpen() {
    if (_isShuttingDown || _state == CameraSessionState.disposed) {
      throw StateError('Camera coordinator is disposed.');
    }
  }

  Future<T> _run<T>(Future<T> Function() operation) {
    final Completer<T> result = Completer<T>();
    final Completer<void> turn = Completer<void>();
    final Future<void> previous = _operationTail;
    _operationTail = turn.future;

    unawaited(
      previous.then((_) async {
        try {
          result.complete(await operation());
        } on Object catch (error, stackTrace) {
          result.completeError(error, stackTrace);
        } finally {
          turn.complete();
        }
      }),
    );
    return result.future;
  }
}
