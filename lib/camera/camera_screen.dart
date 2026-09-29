import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../design/app_palette.dart';
import '../diagnostics/runtime_logs.dart';
import '../location/location_service.dart';
import '../location/location_map_picker.dart';
import '../media/watermark_bridge.dart';
import '../media/watermark_gallery_bridge.dart';
import '../settings/watermark_settings.dart';
import '../watermark/live_watermark_preview.dart';
import '../watermark/watermark_snapshot.dart';
import 'camera_coordinator.dart';
import 'capture_haptics.dart';
import 'hardware_capture_bridge.dart';
import 'zoom_control.dart';

class CameraScreen extends StatefulWidget {
  const CameraScreen({required this.settings, super.key});

  final WatermarkSettings settings;

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  static const Color _accentColor = AppPalette.accent;
  static const Color _recordingColor = AppPalette.recording;
  static const Color _cameraYellow = Color(0xFFFFD94D);

  late final CameraCoordinator _cameraCoordinator;
  late final LocationService _locationService;
  late final LocationMapPicker _locationMapPicker;
  late final WatermarkBridge _watermarkBridge;
  late final WatermarkGalleryBridge _galleryBridge;
  late final HardwareCaptureBridge _hardwareCaptureBridge;
  late final CaptureHaptics _captureHaptics;
  String? _locationText;
  LocationUnavailableException? _locationFailure;
  bool _locationLoading = false;
  int _thumbnailGeneration = 0;
  bool _isShuttingDown = false;
  bool _mediaBusy = false;
  bool _handlingInterruptedRecording = false;
  bool _settingsOpen = false;
  bool _galleryOpen = false;
  bool? _hardwareCaptureEnabled;
  bool _zoomGestureActive = false;
  double _zoomStartFactor = 1;
  bool _focusBusy = false;
  bool _recordingActionBusy = false;
  bool _recordingPhotoBusy = false;
  final Stopwatch _recordingClock = Stopwatch();
  Timer? _recordingTicker;
  Future<void> _mediaOperationTail = Future<void>.value();
  Offset? _focusIndicator;
  int? _focusIndicatorGeneration;
  WatermarkSnapshot? _recordingSnapshot;
  List<PendingWatermarkMedia> _pendingMedia = <PendingWatermarkMedia>[];
  RecentCaptureThumbnail? _recentThumbnail;
  Uint8List? _recentThumbnailBytes;
  String? _mediaMessage;
  CameraSessionState? _lastLoggedCameraState;

  @override
  void initState() {
    super.initState();
    _cameraCoordinator = CameraCoordinator()
      ..addListener(_handleCameraStateChanged);
    _locationService = LocationService();
    _locationMapPicker = LocationMapPicker();
    _locationText = widget.settings.activeLocation;
    _watermarkBridge = WatermarkBridge();
    _galleryBridge = WatermarkGalleryBridge();
    _captureHaptics = const CaptureHaptics();
    _hardwareCaptureBridge = HardwareCaptureBridge(_capturePhoto);
    widget.settings.addListener(_handleSettingsChanged);
    unawaited(
      RuntimeLogs.instance.trace(
        'camera.initialize',
        _cameraCoordinator.initialize,
      ),
    );
    unawaited(_refreshPendingMedia());
    unawaited(_loadRecentThumbnail());
  }

  @override
  void dispose() {
    _isShuttingDown = true;
    _recordingTicker?.cancel();
    _recordingClock.stop();
    widget.settings.removeListener(_handleSettingsChanged);
    _cameraCoordinator.removeListener(_handleCameraStateChanged);
    unawaited(
      _hardwareCaptureBridge.setEnabled(false).then((_) {
        _hardwareCaptureBridge.dispose();
      }),
    );
    unawaited(_cameraCoordinator.shutdown());
    super.dispose();
  }

  void _handleCameraStateChanged() {
    if (!mounted) {
      return;
    }
    setState(() {});
    _syncHardwareCapture();
    final CameraSessionState state = _cameraCoordinator.state;
    if (state != _lastLoggedCameraState) {
      _lastLoggedCameraState = state;
      RuntimeLogs.instance.observe(
        RuntimeLogs.instance.event(
          'camera.state',
          context: <String, Object?>{'state': state.name},
        ),
      );
    }
    if (state != CameraSessionState.recording) {
      _recordingClock.stop();
      _recordingTicker?.cancel();
      _recordingTicker = null;
    }
    if (state == CameraSessionState.processing &&
        _cameraCoordinator.pendingInterruptedRecording != null &&
        !_handlingInterruptedRecording) {
      _handlingInterruptedRecording = true;
      unawaited(_processInterruptedRecording());
    }
  }

  void _handleSettingsChanged() {
    if (!mounted) {
      return;
    }
    setState(() {
      _locationText = widget.settings.activeLocation;
      _locationFailure = null;
    });
    _syncHardwareCapture();
  }

  Future<void> _refreshLocation() async {
    if (_locationLoading ||
        _isShuttingDown ||
        _settingsOpen ||
        _galleryOpen ||
        _cameraCoordinator.state != CameraSessionState.ready) {
      return;
    }
    setState(() {
      _locationLoading = true;
      _locationFailure = null;
    });
    try {
      final ResolvedLocation location = await _locationService
          .refreshLocation();
      if (!mounted || _isShuttingDown) {
        return;
      }
      await widget.settings.useAutomaticLocation(location.text);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '已更新地点：${location.text}（坐标误差约 ${location.accuracyMeters.ceil()} 米；门牌请核对）',
            ),
            duration: const Duration(seconds: 5),
            action: SnackBarAction(label: '修改地点', onPressed: _openSettings),
          ),
        );
      }
    } on LocationUnavailableException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _locationFailure = error);
    } finally {
      if (mounted) {
        setState(() => _locationLoading = false);
        _syncHardwareCapture();
      }
    }
  }

  Future<void> _openLocationMap() async {
    if (_locationLoading ||
        _isShuttingDown ||
        _settingsOpen ||
        _galleryOpen ||
        _cameraCoordinator.state != CameraSessionState.ready) {
      return;
    }
    setState(() {
      _locationLoading = true;
      _locationFailure = null;
    });
    _syncHardwareCapture();
    try {
      final SelectedMapCoordinate? selected = await _locationMapPicker.open();
      if (selected == null || !mounted || _isShuttingDown) {
        return;
      }
      final NearbyMapPlace? selectedPlace = selected.candidates.isEmpty
          ? null
          : selected.candidates.single;
      final String? coordinateAddress = selectedPlace == null
          ? await _locationService.resolveSelectedCoordinate(
              selected.latitude,
              selected.longitude,
            )
          : null;
      if (!mounted || _isShuttingDown) {
        return;
      }
      final String preferred = selectedPlace == null
          ? coordinateAddress!
          : selectedPlace.address.isNotEmpty &&
                selectedPlace.address.characters.length <= 40
          ? selectedPlace.address
          : selectedPlace.name;
      final String? confirmed = await showDialog<String>(
        context: context,
        builder: (BuildContext dialogContext) => _LocationConfirmationDialog(
          initialAddress: preferred,
          coordinateAddress: coordinateAddress,
          nearbyPlaces: selected.candidates,
        ),
      );
      if (confirmed != null && mounted && !_isShuttingDown) {
        await widget.settings.useAutomaticLocation(confirmed);
      }
    } on LocationUnavailableException catch (error) {
      if (mounted) {
        setState(() => _locationFailure = error);
      }
    } on PlatformException catch (error) {
      _showMediaMessage('地图选点失败：${error.code} ${error.message ?? ''}');
    } finally {
      if (mounted) {
        setState(() => _locationLoading = false);
        _syncHardwareCapture();
      }
    }
  }

  Future<void> _openSettings() async {
    _settingsOpen = true;
    _syncHardwareCapture();
    try {
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (BuildContext context) =>
              WatermarkSettingsPage(settings: widget.settings),
        ),
      );
    } finally {
      _settingsOpen = false;
      _syncHardwareCapture();
    }
  }

  Future<void> _retryCamera() async {
    await _cameraCoordinator.retry();
  }

  String _locationForCapture() {
    final String? location = _locationText;
    if (location == null) {
      throw StateError('A capture requires a selected location.');
    }
    return location;
  }

  Future<void> _loadRecentThumbnail() async {
    final int generation = _thumbnailGeneration;
    try {
      final RecentCaptureThumbnail? thumbnail = await _watermarkBridge
          .recentThumbnail();
      if (thumbnail == null) {
        return;
      }
      final Uint8List bytes = await File(thumbnail.path).readAsBytes();
      if (!mounted || generation != _thumbnailGeneration) {
        return;
      }
      setState(() {
        _recentThumbnail = thumbnail;
        _recentThumbnailBytes = bytes;
      });
    } on Object catch (error) {
      _showMediaError(error);
    }
  }

  Future<void> _updateRecentThumbnail(String sourcePath, String kind) async {
    final int generation = ++_thumbnailGeneration;
    try {
      final RecentCaptureThumbnail thumbnail = await _watermarkBridge
          .updateRecentThumbnail(sourcePath: sourcePath, kind: kind);
      final Uint8List bytes = await File(thumbnail.path).readAsBytes();
      if (!mounted || generation != _thumbnailGeneration) {
        return;
      }
      setState(() {
        _recentThumbnail = thumbnail;
        _recentThumbnailBytes = bytes;
      });
    } on Object catch (error) {
      _showMediaError(error);
    }
  }

  WatermarkSnapshot _snapshotAt(String location, DateTime capturedAt) {
    return WatermarkSnapshot.capture(
      capturedAt: capturedAt,
      locationText: location,
      customText: widget.settings.customText,
    );
  }

  Future<void> _capturePhoto() async {
    if (_cameraCoordinator.state != CameraSessionState.ready ||
        _cameraCoordinator.captureMode != CameraCaptureMode.photo ||
        _locationText == null ||
        _locationLoading ||
        _mediaBusy ||
        _isShuttingDown ||
        _settingsOpen ||
        _galleryOpen) {
      return;
    }
    if (_mediaMessage != null && mounted) {
      setState(() => _mediaMessage = null);
    }
    try {
      final String location = _locationForCapture();
      final WatermarkSnapshot snapshot = _snapshotAt(location, DateTime.now());
      final XFile source = await RuntimeLogs.instance.trace(
        'camera.take_photo',
        _cameraCoordinator.takePicture,
        context: const <String, Object?>{'during_recording': false},
      );
      await Future.wait<void>(<Future<void>>[
        RuntimeLogs.instance.trace(
          'haptics.impact',
          _captureHaptics.captureImpact,
        ),
        _processCapturedMedia(source, snapshot, 'photo'),
      ]);
    } on Object catch (error, stack) {
      RuntimeLogs.instance.observe(
        RuntimeLogs.instance.failure('camera.photo', error, stack),
      );
      _showMediaError(error);
    } finally {
      await _finishCameraProcessingIfPossible();
    }
  }

  Future<void> _startVideoRecording() async {
    if (_cameraCoordinator.state != CameraSessionState.ready ||
        _mediaBusy ||
        _locationLoading) {
      return;
    }
    try {
      final String location = _locationForCapture();
      WatermarkSnapshot? snapshot;
      final bool started = await RuntimeLogs.instance.trace(
        'camera.start_recording',
        () => _cameraCoordinator.startVideoRecording(
          onRecordingStarting: () {
            snapshot = _snapshotAt(location, DateTime.now());
            _recordingSnapshot = snapshot;
          },
        ),
      );
      if (started) {
        _recordingSnapshot =
            snapshot ??
            (throw StateError(
              'The recording began without a frozen watermark snapshot.',
            ));
        if (mounted) {
          _recordingClock
            ..reset()
            ..start();
          _startRecordingTicker();
          setState(() => _mediaMessage = null);
        }
      } else {
        _recordingSnapshot = null;
      }
    } on Object catch (error) {
      _recordingSnapshot = null;
      _showMediaError(error);
    }
  }

  Future<void> _stopVideoRecording() async {
    if (_cameraCoordinator.state != CameraSessionState.recording ||
        _mediaBusy ||
        _recordingActionBusy ||
        _recordingPhotoBusy) {
      return;
    }
    setState(() => _recordingActionBusy = true);
    try {
      final WatermarkSnapshot? snapshot = _recordingSnapshot;
      final XFile source = await RuntimeLogs.instance.trace(
        'camera.stop_recording',
        _cameraCoordinator.stopVideoRecording,
      );
      _recordingSnapshot = null;
      if (snapshot == null) {
        throw StateError('The recording has no frozen watermark snapshot.');
      }
      await _updateRecentThumbnail(source.path, 'video');
      await _processCapturedMedia(source, snapshot, 'video');
    } on Object catch (error) {
      _showMediaError(error);
    } finally {
      await _finishCameraProcessingIfPossible();
      if (mounted) setState(() => _recordingActionBusy = false);
    }
  }

  Future<void> _toggleVideoRecordingPause() async {
    if (_cameraCoordinator.state != CameraSessionState.recording ||
        _recordingActionBusy ||
        _recordingPhotoBusy ||
        _mediaBusy) {
      return;
    }
    setState(() => _recordingActionBusy = true);
    try {
      if (_cameraCoordinator.isRecordingPaused) {
        await _cameraCoordinator.resumeVideoRecording();
        _recordingClock.start();
        _startRecordingTicker();
      } else {
        await _cameraCoordinator.pauseVideoRecording();
        _recordingClock.stop();
        _recordingTicker?.cancel();
        _recordingTicker = null;
      }
      if (mounted) setState(() {});
    } on Object catch (error) {
      _showMediaError(error);
    } finally {
      if (mounted) setState(() => _recordingActionBusy = false);
    }
  }

  void _startRecordingTicker() {
    _recordingTicker?.cancel();
    _recordingTicker = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (mounted) setState(() {});
    });
  }

  Future<void> _capturePhotoDuringRecording() async {
    if (_cameraCoordinator.state != CameraSessionState.recording ||
        _cameraCoordinator.isRecordingPaused ||
        _recordingActionBusy ||
        _recordingPhotoBusy ||
        _mediaBusy) {
      return;
    }
    setState(() => _recordingPhotoBusy = true);
    try {
      final WatermarkSnapshot snapshot = _snapshotAt(
        _locationForCapture(),
        DateTime.now(),
      );
      final XFile source = await RuntimeLogs.instance.trace(
        'camera.take_photo_during_recording',
        _cameraCoordinator.takePictureDuringRecording,
        context: const <String, Object?>{'during_recording': true},
      );
      await Future.wait<void>(<Future<void>>[
        RuntimeLogs.instance.trace(
          'haptics.impact',
          _captureHaptics.captureImpact,
        ),
        _processCapturedMedia(source, snapshot, 'photo'),
      ]);
    } on Object catch (error, stack) {
      RuntimeLogs.instance.observe(
        RuntimeLogs.instance.failure('camera.recording_photo', error, stack),
      );
      _showMediaError(error);
    } finally {
      if (mounted) setState(() => _recordingPhotoBusy = false);
    }
  }

  Future<void> _processInterruptedRecording() async {
    try {
      final WatermarkSnapshot? snapshot = _recordingSnapshot;
      if (snapshot == null) {
        throw StateError(
          'The interrupted recording has no frozen watermark snapshot.',
        );
      }
      final XFile? source = _cameraCoordinator
          .takePendingInterruptedRecording();
      if (source == null) {
        throw StateError(
          'The camera reported an interrupted recording without a file.',
        );
      }
      _recordingSnapshot = null;
      await _updateRecentThumbnail(source.path, 'video');
      await _processCapturedMedia(source, snapshot, 'video');
    } on Object catch (error) {
      _showMediaError(error);
    } finally {
      _recordingSnapshot = null;
      _handlingInterruptedRecording = false;
      await _finishCameraProcessingIfPossible();
    }
  }

  Future<void> _processCapturedMedia(
    XFile source,
    WatermarkSnapshot snapshot,
    String kind,
  ) async {
    final Future<void> previous = _mediaOperationTail;
    final Completer<void> completion = Completer<void>();
    _mediaOperationTail = completion.future;
    try {
      await previous;
      await _processCapturedMediaSerial(source, snapshot, kind);
    } finally {
      completion.complete();
    }
  }

  Future<void> _processCapturedMediaSerial(
    XFile source,
    WatermarkSnapshot snapshot,
    String kind,
  ) async {
    if (_mediaBusy) {
      throw StateError('Another media operation is already active.');
    }
    if (mounted) {
      setState(() {
        _mediaBusy = true;
      });
      _syncHardwareCapture();
    }
    try {
      await RuntimeLogs.instance.event(
        'media.process',
        phase: 'start',
        context: <String, Object?>{'kind': kind},
      );
      final String taskId = await RuntimeLogs.instance.trace(
        'media.prepare',
        () => _galleryBridge.prepareMedia(
          sourcePath: source.path,
          kind: kind,
          snapshot: snapshot,
        ),
        context: <String, Object?>{'kind': kind},
      );
      final String renderedPath = await RuntimeLogs.instance.trace(
        'media.render',
        () => kind == 'photo'
            ? _watermarkBridge.renderPhoto(
                sourcePath: source.path,
                snapshot: snapshot,
              )
            : _watermarkBridge.renderVideo(
                sourcePath: source.path,
                snapshot: snapshot,
              ),
        context: <String, Object?>{'kind': kind},
      );
      await _updateRecentThumbnail(renderedPath, kind);
      await RuntimeLogs.instance.trace(
        'media.mark_rendered',
        () => _galleryBridge.markRendered(
          taskId: taskId,
          renderedPath: renderedPath,
        ),
        context: <String, Object?>{'kind': kind},
      );
      await RuntimeLogs.instance.trace(
        'media.save_to_photos',
        () => _galleryBridge.saveToPhotos(taskId: taskId),
        context: <String, Object?>{'kind': kind},
      );
      await RuntimeLogs.instance.event(
        'media.process',
        phase: 'success',
        context: <String, Object?>{'kind': kind},
      );
      if (mounted) {
        unawaited(_refreshPendingMedia());
      }
    } on Object catch (error, stack) {
      RuntimeLogs.instance.observe(
        RuntimeLogs.instance.failure(
          'media.process',
          error,
          stack,
          context: <String, Object?>{'kind': kind},
        ),
      );
      _showMediaError(error);
      unawaited(_refreshPendingMedia());
    } finally {
      if (mounted) {
        setState(() => _mediaBusy = false);
        _syncHardwareCapture();
      }
    }
  }

  Future<void> _restorePendingMedia() async {
    if (_mediaBusy || _pendingMedia.isEmpty) {
      return;
    }
    PendingWatermarkMedia? pending;
    for (final PendingWatermarkMedia item in _pendingMedia) {
      if (item.status != 'saving') {
        pending = item;
        break;
      }
    }
    if (pending == null) {
      _showMediaMessage('上次保存结果不确定，请先检查系统照片；已跳过自动重试。');
      return;
    }
    if (pending.status == 'savedNeedsIndex') {
      await _refreshPendingMedia();
      return;
    }

    setState(() => _mediaBusy = true);
    try {
      String? renderedPath = pending.renderedPath;
      if (pending.status == 'prepared') {
        renderedPath = pending.kind == 'photo'
            ? await _watermarkBridge.renderPhoto(
                sourcePath: pending.sourcePath,
                snapshot: pending.snapshot,
              )
            : await _watermarkBridge.renderVideo(
                sourcePath: pending.sourcePath,
                snapshot: pending.snapshot,
              );
        await _galleryBridge.markRendered(
          taskId: pending.id,
          renderedPath: renderedPath,
        );
      }
      if (renderedPath == null) {
        throw StateError('A recoverable media operation has no rendered file.');
      }
      await _galleryBridge.saveToPhotos(taskId: pending.id);
      if (mounted) {
        setState(() => _mediaMessage = null);
      }
    } on Object catch (error) {
      _showMediaError(error);
    } finally {
      if (mounted) {
        setState(() => _mediaBusy = false);
        unawaited(_refreshPendingMedia());
      }
    }
  }

  Future<void> _refreshPendingMedia() async {
    try {
      final List<PendingWatermarkMedia> pending = await _galleryBridge
          .pendingMedia();
      if (!mounted) {
        return;
      }
      setState(() {
        _pendingMedia = pending;
        if (pending.any(
          (PendingWatermarkMedia item) => item.status == 'saving',
        )) {
          _mediaMessage = '上次保存结果不确定，请先检查系统照片；应用不会自动重复保存。';
        } else if (pending.any(
          (PendingWatermarkMedia item) => item.status == 'savedNeedsIndex',
        )) {
          _mediaMessage = '成品已保存到系统照片，应用内索引待修复。';
        } else if (pending.isNotEmpty && _mediaMessage == null) {
          _mediaMessage = '检测到未完成的水印媒体，可选择恢复保存。';
        } else if (pending.isEmpty &&
            (_mediaMessage?.startsWith('检测到未完成') == true ||
                _mediaMessage?.startsWith('成品已保存到系统照片') == true ||
                _mediaMessage?.contains('saved_but_index_failed') == true ||
                _mediaMessage?.contains('saved_but_cleanup_failed') == true)) {
          _mediaMessage = null;
        }
      });
    } on Object catch (error) {
      _showMediaError(error);
    }
  }

  Future<void> _finishCameraProcessingIfPossible() async {
    if (_cameraCoordinator.state != CameraSessionState.processing ||
        _cameraCoordinator.pendingInterruptedRecording != null) {
      return;
    }
    await _cameraCoordinator.finishProcessing();
  }

  bool get _canZoom =>
      !_isShuttingDown &&
      _cameraCoordinator.isBackCameraSelected &&
      (_cameraCoordinator.state == CameraSessionState.ready ||
          _cameraCoordinator.state == CameraSessionState.recording) &&
      _cameraCoordinator.controller?.value.isInitialized == true;

  void _handleZoomGestureStart(ScaleStartDetails details) {
    if (!_canZoom) {
      return;
    }
    _zoomStartFactor = _cameraCoordinator.zoomFactor;
  }

  void _handleZoomGestureUpdate(ScaleUpdateDetails details) {
    if (!_canZoom || details.pointerCount < 2) {
      return;
    }
    if (!_zoomGestureActive) {
      setState(() => _zoomGestureActive = true);
    }
    _cameraCoordinator.setZoomFactor(_zoomStartFactor * details.scale);
  }

  void _handleZoomGestureEnd(ScaleEndDetails details) {
    if (!_zoomGestureActive) {
      return;
    }
    setState(() => _zoomGestureActive = false);
    final CameraZoomStep? step = snapZoomStep(
      _cameraCoordinator.zoomSteps,
      _cameraCoordinator.zoomFactor,
    );
    if (step != null) {
      _selectZoomStep(step);
    }
  }

  void _selectZoomStep(CameraZoomStep step) {
    final CameraSessionState state = _cameraCoordinator.state;
    if (state != CameraSessionState.ready &&
        state != CameraSessionState.recording) {
      return;
    }
    _cameraCoordinator.setZoomFactor(step.factor);
  }

  bool get _canFocus =>
      !_isShuttingDown &&
      !_focusBusy &&
      _cameraCoordinator.focusPointSupported &&
      (_cameraCoordinator.state == CameraSessionState.ready ||
          _cameraCoordinator.state == CameraSessionState.recording);

  Future<void> _restoreAutoFocus() async {
    if (!_canFocus || _cameraCoordinator.focusMode == FocusMode.auto) {
      return;
    }
    setState(() => _focusBusy = true);
    try {
      await _cameraCoordinator.setFocusMode(FocusMode.auto);
      if (mounted) {
        setState(() {
          _focusIndicator = null;
          _focusIndicatorGeneration = null;
        });
      }
    } finally {
      if (mounted) {
        setState(() => _focusBusy = false);
      }
    }
  }

  Future<void> _focusAt(
    TapUpDetails details,
    Size previewSize,
    double frameTop,
    double frameBottom,
    CameraController controller,
  ) async {
    if (!_canFocus) {
      return;
    }
    final Offset tap = details.localPosition;
    if (tap.dy < frameTop || tap.dy > frameBottom) {
      return;
    }
    final double aspectRatio = previewSize.width > previewSize.height
        ? controller.value.aspectRatio
        : 1 / controller.value.aspectRatio;
    final double imageWidth = math.max(
      previewSize.width,
      previewSize.height * aspectRatio,
    );
    final double imageHeight = imageWidth / aspectRatio;
    final Offset point = Offset(
      (tap.dx + (imageWidth - previewSize.width) / 2) / imageWidth,
      (tap.dy + (imageHeight - previewSize.height) / 2) / imageHeight,
    );
    setState(() => _focusBusy = true);
    try {
      await _cameraCoordinator.setFocusPoint(point);
      if (mounted) {
        setState(() {
          _focusIndicator = tap;
          _focusIndicatorGeneration = _cameraCoordinator.generation;
        });
      }
    } finally {
      if (mounted) {
        setState(() => _focusBusy = false);
      }
    }
  }

  Future<void> _openGallery() async {
    _galleryOpen = true;
    _syncHardwareCapture();
    try {
      await _galleryBridge.openGallery();
    } on Object catch (error) {
      _showMediaError(error);
    } finally {
      _galleryOpen = false;
      _syncHardwareCapture();
    }
  }

  void _syncHardwareCapture() {
    if (!mounted || _isShuttingDown) {
      return;
    }
    final bool enabled =
        _cameraCoordinator.state == CameraSessionState.ready &&
        _cameraCoordinator.captureMode == CameraCaptureMode.photo &&
        _locationText != null &&
        !_locationLoading &&
        !_mediaBusy &&
        !_settingsOpen &&
        !_galleryOpen;
    if (_hardwareCaptureEnabled == enabled) {
      return;
    }
    _hardwareCaptureEnabled = enabled;
    unawaited(_hardwareCaptureBridge.setEnabled(enabled));
  }

  Future<void> _openSystemSettings() async {
    try {
      await _galleryBridge.openSystemSettings();
    } on Object catch (error) {
      _showMediaError(error);
    }
  }

  void _showMediaError(Object error) {
    if (!mounted) {
      return;
    }
    final String details = error is PlatformException
        ? '${error.code}: ${error.message ?? error.details ?? '未知原生错误'}'
        : error.toString();
    final String subject =
        error is PlatformException && error.code.startsWith('haptics_')
        ? '拍照震动失败'
        : '媒体处理失败';
    setState(() => _mediaMessage = '$subject：$details');
  }

  void _showMediaMessage(String message) {
    if (!mounted) {
      return;
    }
    setState(() => _mediaMessage = message);
  }

  String? get _visibleError {
    final String? cameraError = _cameraCoordinator.cameraErrorText;
    if (cameraError != null) {
      return cameraError;
    }
    if (_locationFailure case final LocationUnavailableException failure) {
      return failure.userMessage;
    }
    if (_locationText == null && !_locationLoading) {
      return '尚未设置拍摄地点。请点右上角定位按钮，或在设置中填写。';
    }
    return null;
  }

  bool get _locationNeedsSystemSettings =>
      _locationFailure?.reason == LocationUnavailableReason.reducedAccuracy ||
      _locationFailure?.reason ==
          LocationUnavailableReason.permissionDeniedForever;

  Widget _buildCameraSwitchControl(bool controlsEnabled) {
    final bool canSwitch =
        controlsEnabled && _cameraCoordinator.canSwitchCamera;
    return IconButton(
      tooltip: canSwitch ? '切换前后摄像头' : '当前设备没有可切换的镜头',
      onPressed: canSwitch
          ? () => unawaited(_cameraCoordinator.switchCamera())
          : null,
      style: IconButton.styleFrom(
        fixedSize: const Size(52, 52),
        backgroundColor: AppPalette.translucentPill,
        foregroundColor: canSwitch ? Colors.white : Colors.white38,
        shape: const CircleBorder(),
      ),
      icon: const Icon(Icons.cameraswitch_rounded, size: 27),
    );
  }

  Widget _buildFlashControl(bool controlsEnabled) {
    final String? unavailableReason = _cameraCoordinator.flashUnavailableReason;
    final bool enabled = controlsEnabled && unavailableReason == null;
    final FlashMode mode = _cameraCoordinator.flashMode;
    final bool isOn = mode != FlashMode.off;
    return IconButton(
      tooltip: unavailableReason ?? (isOn ? '关闭闪光灯' : '开启闪光灯'),
      onPressed: enabled
          ? () => unawaited(
              _cameraCoordinator.setFlashMode(
                isOn ? FlashMode.off : FlashMode.torch,
              ),
            )
          : null,
      style: IconButton.styleFrom(
        fixedSize: const Size(46, 46),
        backgroundColor: Colors.transparent,
        foregroundColor: isOn ? _cameraYellow : Colors.white,
        disabledForegroundColor: Colors.white38,
        shape: const CircleBorder(),
      ),
      icon: Icon(
        isOn ? Icons.flash_on_rounded : Icons.flash_off_rounded,
        size: 24,
      ),
    );
  }

  Widget _buildCaptureModeControl(bool canChangeMode) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(28),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          _buildCaptureModeOption(
            mode: CameraCaptureMode.video,
            label: '视频',
            canChangeMode: canChangeMode,
          ),
          _buildCaptureModeOption(
            mode: CameraCaptureMode.photo,
            label: '照片',
            canChangeMode: canChangeMode,
          ),
        ],
      ),
    );
  }

  Widget _buildCaptureModeOption({
    required CameraCaptureMode mode,
    required String label,
    required bool canChangeMode,
  }) {
    final bool selected = _cameraCoordinator.captureMode == mode;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: !canChangeMode || selected
            ? null
            : () => unawaited(_cameraCoordinator.setCaptureMode(mode)),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          width: 76,
          height: 40,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? AppPalette.translucentPill : Colors.transparent,
            borderRadius: BorderRadius.circular(24),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: selected ? _cameraYellow : Colors.white70,
              fontSize: 15,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCaptureButton(CameraSessionState cameraState) {
    final bool isRecording = cameraState == CameraSessionState.recording;
    final bool isReady = cameraState == CameraSessionState.ready;
    final bool canCapture =
        isReady && _locationText != null && !_mediaBusy && !_locationLoading;
    final VoidCallback? onPressed = isRecording
        ? () => unawaited(_stopVideoRecording())
        : !canCapture
        ? null
        : _cameraCoordinator.captureMode == CameraCaptureMode.photo
        ? () => unawaited(_capturePhoto())
        : () => unawaited(_startVideoRecording());
    final String tooltip = isRecording
        ? '停止录像'
        : _cameraCoordinator.captureMode == CameraCaptureMode.photo
        ? '拍摄照片'
        : '开始录像';
    final Widget centerMark =
        _mediaBusy || cameraState == CameraSessionState.processing
        ? const SizedBox.square(
            dimension: 28,
            child: CircularProgressIndicator(
              strokeWidth: 3,
              color: _accentColor,
            ),
          )
        : isRecording
        ? const Icon(Icons.stop_rounded, size: 30, color: Colors.white)
        : _cameraCoordinator.captureMode == CameraCaptureMode.video
        ? const DecoratedBox(
            decoration: BoxDecoration(
              color: _recordingColor,
              shape: BoxShape.circle,
            ),
            child: SizedBox.square(dimension: 20),
          )
        : const SizedBox.shrink();
    return Semantics(
      button: true,
      enabled: onPressed != null,
      label: tooltip,
      child: Tooltip(
        message: tooltip,
        child: SizedBox.square(
          dimension: 82,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: onPressed,
              customBorder: const CircleBorder(),
              child: Container(
                padding: const EdgeInsets.all(5),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Colors.white.withValues(
                      alpha: onPressed == null ? 0.34 : 0.92,
                    ),
                    width: 3,
                  ),
                ),
                child: Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: isRecording ? _recordingColor : Colors.white,
                  ),
                  alignment: Alignment.center,
                  child: centerMark,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRecordingTimer() {
    final int elapsedSeconds = _recordingClock.elapsed.inSeconds;
    final String duration = <int>[
      elapsedSeconds ~/ 3600,
      (elapsedSeconds ~/ 60) % 60,
      elapsedSeconds % 60,
    ].map((int value) => value.toString().padLeft(2, '0')).join(':');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: _recordingColor,
        borderRadius: BorderRadius.circular(9),
      ),
      child: Text(
        duration,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 25,
          fontWeight: FontWeight.w500,
          fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
        ),
      ),
    );
  }

  Widget _buildRecordingControl({
    required String tooltip,
    required double size,
    required Widget child,
    required VoidCallback? onTap,
  }) {
    return Semantics(
      button: true,
      enabled: onTap != null,
      label: tooltip,
      child: Tooltip(
        message: tooltip,
        child: SizedBox.square(
          dimension: size,
          child: Material(
            color: AppPalette.surface.withValues(alpha: 0.92),
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onTap,
              child: Center(child: child),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRecordingControls() {
    final bool paused = _cameraCoordinator.isRecordingPaused;
    final bool canAct =
        !_recordingActionBusy && !_recordingPhotoBusy && !_mediaBusy;
    return Row(
      children: <Widget>[
        Expanded(
          child: Align(
            alignment: Alignment.centerLeft,
            child: _buildRecordingControl(
              tooltip: paused ? '继续录像' : '暂停录像',
              size: 64,
              onTap: canAct
                  ? () => unawaited(_toggleVideoRecordingPause())
                  : null,
              child: Icon(
                paused ? Icons.play_arrow_rounded : Icons.pause_rounded,
                color: Colors.white,
                size: 33,
              ),
            ),
          ),
        ),
        _buildRecordingControl(
          tooltip: '停止录像',
          size: 82,
          onTap: canAct ? () => unawaited(_stopVideoRecording()) : null,
          child: Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: _recordingColor,
              borderRadius: BorderRadius.circular(7),
            ),
          ),
        ),
        Expanded(
          child: Align(
            alignment: Alignment.centerRight,
            child: _buildRecordingControl(
              tooltip: '录像时拍照',
              size: 64,
              onTap: canAct && !paused
                  ? () => unawaited(_capturePhotoDuringRecording())
                  : null,
              child: _recordingPhotoBusy
                  ? const SizedBox.square(
                      dimension: 25,
                      child: CircularProgressIndicator(
                        strokeWidth: 3,
                        color: Colors.white,
                      ),
                    )
                  : const DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        shape: BoxShape.circle,
                      ),
                      child: SizedBox.square(dimension: 48),
                    ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMediaMessage(String mediaMessage) {
    final ButtonStyle actionStyle = TextButton.styleFrom(
      foregroundColor: _accentColor,
      visualDensity: VisualDensity.compact,
    );
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppPalette.surface.withValues(alpha: 0.94),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white24),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            mediaMessage,
            textAlign: TextAlign.center,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
          if (_pendingMedia.any(
            (PendingWatermarkMedia item) => item.status != 'saving',
          ))
            TextButton.icon(
              style: actionStyle,
              onPressed:
                  _mediaBusy ||
                      _cameraCoordinator.state == CameraSessionState.recording
                  ? null
                  : () => unawaited(_restorePendingMedia()),
              icon: const Icon(Icons.restore),
              label: const Text('恢复未完成媒体'),
            ),
          if (_pendingMedia.isEmpty &&
              mediaMessage.startsWith('媒体处理失败：') &&
              !mediaMessage.contains('photo_save_result_uncertain'))
            TextButton.icon(
              style: actionStyle,
              onPressed: _mediaBusy
                  ? null
                  : () => unawaited(_refreshPendingMedia()),
              icon: const Icon(Icons.refresh),
              label: const Text('重新检查恢复状态'),
            ),
          if (mediaMessage.contains('permission_denied'))
            TextButton.icon(
              style: actionStyle,
              onPressed: _openSystemSettings,
              icon: const Icon(Icons.settings_outlined),
              label: const Text('打开系统设置'),
            ),
        ],
      ),
    );
  }

  Widget _buildTopAction({
    required String tooltip,
    required IconData icon,
    required VoidCallback? onPressed,
  }) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      style: IconButton.styleFrom(
        fixedSize: const Size(46, 46),
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        disabledForegroundColor: Colors.white38,
        shape: const CircleBorder(),
      ),
      icon: Icon(icon, size: 26),
    );
  }

  Widget _buildLocationControl(CameraSessionState cameraState) {
    final bool enabled =
        cameraState == CameraSessionState.ready &&
        !_locationLoading &&
        !_settingsOpen &&
        !_galleryOpen;
    return IconButton(
      tooltip: '在地图上确认地点',
      onPressed: enabled ? () => unawaited(_openLocationMap()) : null,
      style: IconButton.styleFrom(
        fixedSize: const Size(46, 46),
        foregroundColor: Colors.white,
        disabledForegroundColor: Colors.white38,
        shape: const CircleBorder(),
      ),
      icon: _locationLoading
          ? const SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            )
          : const Icon(Icons.gps_fixed_rounded, size: 24),
    );
  }

  Widget _buildTopBar(CameraSessionState cameraState) {
    return Row(
      children: <Widget>[
        const Spacer(),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            _buildFlashControl(cameraState == CameraSessionState.ready),
            _buildTopAction(
              tooltip: _cameraCoordinator.focusMode == FocusMode.auto
                  ? '自动对焦'
                  : '恢复自动对焦',
              icon: _cameraCoordinator.focusMode == FocusMode.auto
                  ? Icons.center_focus_weak
                  : Icons.center_focus_strong,
              onPressed:
                  _canFocus && _cameraCoordinator.focusMode == FocusMode.locked
                  ? () => unawaited(_restoreAutoFocus())
                  : null,
            ),
            _buildLocationControl(cameraState),
            _buildTopAction(
              tooltip: '设置',
              icon: Icons.more_horiz_rounded,
              onPressed: _locationLoading ? null : _openSettings,
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildGalleryControl(CameraSessionState cameraState) {
    final bool enabled =
        !_mediaBusy &&
        cameraState != CameraSessionState.recording &&
        cameraState != CameraSessionState.processing;
    return Semantics(
      button: true,
      enabled: enabled,
      label: '浏览照片与视频',
      child: Tooltip(
        message: '浏览照片与视频',
        child: SizedBox.square(
          dimension: 52,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(26),
              onTap: enabled ? _openGallery : null,
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  if (_recentThumbnailBytes case final Uint8List bytes)
                    ClipRRect(
                      borderRadius: BorderRadius.circular(26),
                      child: Image.memory(
                        bytes,
                        fit: BoxFit.cover,
                        cacheWidth: 480,
                        gaplessPlayback: true,
                      ),
                    )
                  else
                    DecoratedBox(
                      decoration: BoxDecoration(
                        color: AppPalette.surface,
                        borderRadius: BorderRadius.circular(26),
                      ),
                      child: const Icon(
                        Icons.photo_library_outlined,
                        color: Colors.white,
                        size: 28,
                      ),
                    ),
                  if (_recentThumbnail?.kind == 'video')
                    const Positioned(
                      top: 4,
                      left: 4,
                      child: Icon(
                        Icons.play_circle_fill_rounded,
                        color: Colors.white,
                        size: 20,
                        shadows: <Shadow>[
                          Shadow(color: Colors.black87, blurRadius: 4),
                        ],
                      ),
                    ),
                  if (_mediaBusy)
                    const Positioned(
                      top: 5,
                      right: 5,
                      child: SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  double _frameAspectRatio(
    CameraController controller,
    BoxConstraints constraints,
  ) => constraints.maxWidth > constraints.maxHeight
      ? controller.value.aspectRatio
      : 1 / controller.value.aspectRatio;

  Widget _buildCameraPreview(CameraController controller) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double frameAspectRatio = _frameAspectRatio(
          controller,
          constraints,
        );
        return ClipRect(
          child: FittedBox(
            fit: BoxFit.cover,
            child: SizedBox(
              width: constraints.maxWidth,
              height: constraints.maxWidth / frameAspectRatio,
              child: CameraPreview(controller),
            ),
          ),
        );
      },
    );
  }

  Widget? _buildWatermarkPreview(CameraSessionState cameraState) {
    final String? locationText = _locationText;
    if (locationText == null) {
      return null;
    }
    return LiveWatermarkPreview(
      locationText: locationText,
      customText: widget.settings.customText,
      frozenSnapshot: cameraState == CameraSessionState.recording
          ? _recordingSnapshot
          : null,
    );
  }

  Widget _buildControlPanel(CameraSessionState cameraState) {
    final bool recording = cameraState == CameraSessionState.recording;
    final bool canChangeMode = cameraState == CameraSessionState.ready;
    final List<CameraZoomStep> steps = _cameraCoordinator.zoomSteps;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (steps.isNotEmpty)
            IgnorePointer(
              ignoring: !_canZoom,
              child: CameraZoomControl(
                steps: steps,
                factor: _cameraCoordinator.zoomFactor,
                minimumFactor: _cameraCoordinator.minimumZoomFactor,
                maximumFactor: _cameraCoordinator.maximumZoomFactor,
                showDial: _zoomGestureActive,
                onFactorChanged: _cameraCoordinator.setZoomFactor,
                onStepSelected: _selectZoomStep,
              ),
            )
          else
            const SizedBox(height: 70),
          const SizedBox(height: 10),
          if (recording)
            _buildRecordingControls()
          else
            Row(
              children: <Widget>[
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: _buildGalleryControl(cameraState),
                  ),
                ),
                _buildCaptureButton(cameraState),
                Expanded(
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: _buildCameraSwitchControl(canChangeMode),
                  ),
                ),
              ],
            ),
          if (!recording) ...<Widget>[
            const SizedBox(height: 36),
            _buildCaptureModeControl(canChangeMode),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final CameraController? controller = _cameraCoordinator.controller;
    final CameraSessionState cameraState = _cameraCoordinator.state;
    final EdgeInsets safePadding = MediaQuery.viewPaddingOf(context);

    return Scaffold(
      backgroundColor: AppPalette.background,
      body: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final double panelBelowFrame = 176 + safePadding.bottom;
          final double frameHeight = math.min(
            constraints.maxWidth * 4 / 3,
            constraints.maxHeight - panelBelowFrame - safePadding.top - 104,
          );
          final double frameTop =
              constraints.maxHeight - panelBelowFrame - frameHeight;
          final double frameBottom = frameTop + frameHeight;
          final bool previewReady =
              controller != null && controller.value.isInitialized;

          return Stack(
            fit: StackFit.expand,
            children: <Widget>[
              if (previewReady)
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onScaleStart: _handleZoomGestureStart,
                  onScaleUpdate: _handleZoomGestureUpdate,
                  onScaleEnd: _handleZoomGestureEnd,
                  onTapUp: (TapUpDetails details) => unawaited(
                    _focusAt(
                      details,
                      constraints.biggest,
                      frameTop,
                      frameBottom,
                      controller,
                    ),
                  ),
                  child: _buildCameraPreview(controller),
                ),
              if (_focusIndicator case final Offset point)
                if (_cameraCoordinator.focusMode == FocusMode.locked &&
                    _focusIndicatorGeneration == _cameraCoordinator.generation)
                  Positioned(
                    left: point.dx - 22,
                    top: point.dy - 22,
                    child: const IgnorePointer(
                      child: Icon(
                        Icons.filter_center_focus,
                        color: _cameraYellow,
                        size: 44,
                        shadows: <Shadow>[
                          Shadow(color: Colors.black87, blurRadius: 6),
                        ],
                      ),
                    ),
                  ),
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                height: frameTop,
                child: const IgnorePointer(
                  child: ColoredBox(color: AppPalette.previewScrim),
                ),
              ),
              Positioned(
                top: frameBottom,
                left: 0,
                right: 0,
                bottom: 0,
                child: const IgnorePointer(
                  child: ColoredBox(color: AppPalette.controlBar),
                ),
              ),
              if (previewReady && _locationText != null)
                Positioned(
                  top: frameTop,
                  left: 0,
                  right: 0,
                  height: frameHeight,
                  child: IgnorePointer(
                    child: _buildWatermarkPreview(cameraState),
                  ),
                ),
              if (cameraState == CameraSessionState.recording)
                Positioned(
                  top: frameTop + 18,
                  left: 0,
                  right: 0,
                  child: Center(child: _buildRecordingTimer()),
                )
              else
                Positioned(
                  top: safePadding.top + 18,
                  left: 20,
                  right: 20,
                  child: _buildTopBar(cameraState),
                ),
              Positioned(
                top: safePadding.top + 92,
                left: 16,
                right: 16,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    if (_visibleError case final String errorText)
                      _StatusCard(
                        message: errorText,
                        actionLabel: cameraState == CameraSessionState.error
                            ? '重试相机'
                            : _locationNeedsSystemSettings
                            ? '系统设置'
                            : '刷新定位',
                        onAction: cameraState == CameraSessionState.error
                            ? _retryCamera
                            : _locationNeedsSystemSettings
                            ? _openSystemSettings
                            : _refreshLocation,
                      ),
                    if (_mediaMessage case final String mediaMessage)
                      _buildMediaMessage(mediaMessage),
                  ],
                ),
              ),
              Positioned(
                top: frameBottom - 70,
                left: 0,
                right: 0,
                child: _buildControlPanel(cameraState),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _LocationConfirmationDialog extends StatefulWidget {
  const _LocationConfirmationDialog({
    required this.initialAddress,
    required this.coordinateAddress,
    required this.nearbyPlaces,
  });

  final String initialAddress;
  final String? coordinateAddress;
  final List<NearbyMapPlace> nearbyPlaces;

  @override
  State<_LocationConfirmationDialog> createState() =>
      _LocationConfirmationDialogState();
}

class _LocationConfirmationDialogState
    extends State<_LocationConfirmationDialog> {
  late final TextEditingController _addressController;

  @override
  void initState() {
    super.initState();
    _addressController = TextEditingController(text: widget.initialAddress)
      ..addListener(_handleAddressChanged);
  }

  @override
  void dispose() {
    _addressController.removeListener(_handleAddressChanged);
    _addressController.dispose();
    super.dispose();
  }

  void _handleAddressChanged() => setState(() {});

  void _chooseAddress(String address) {
    _addressController.value = TextEditingValue(
      text: address,
      selection: TextSelection.collapsed(offset: address.length),
    );
  }

  @override
  Widget build(BuildContext context) {
    final String value = _addressController.text.trim();
    final bool canConfirm = value.isNotEmpty && value.characters.length <= 40;
    return AlertDialog(
      title: const Text('确认水印地点'),
      content: SizedBox(
        width: MediaQuery.sizeOf(context).width - 96,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 420),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text('请核对地点，也可以直接修改水印文字。'),
                const SizedBox(height: 12),
                if (widget.coordinateAddress case final String address)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('坐标反查地址'),
                    subtitle: Text(address),
                    onTap: () => _chooseAddress(address),
                  ),
                for (final NearbyMapPlace place in widget.nearbyPlaces)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(place.name),
                    subtitle: place.address.isEmpty
                        ? null
                        : Text(
                            place.address,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                    onTap: () => _chooseAddress(
                      place.address.isEmpty ? place.name : place.address,
                    ),
                  ),
                const SizedBox(height: 12),
                TextField(
                  controller: _addressController,
                  maxLength: 40,
                  decoration: const InputDecoration(labelText: '最终水印文字'),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: canConfirm ? () => Navigator.of(context).pop(value) : null,
          child: const Text('使用此地点'),
        ),
      ],
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({
    required this.message,
    required this.actionLabel,
    required this.onAction,
  });

  final String message;
  final String actionLabel;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppPalette.surface.withValues(alpha: 0.94),
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              message,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                height: 1.45,
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(onPressed: onAction, child: Text(actionLabel)),
            ),
          ],
        ),
      ),
    );
  }
}
