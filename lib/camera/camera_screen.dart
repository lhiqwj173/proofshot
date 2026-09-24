import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../location/location_service.dart';
import '../media/watermark_bridge.dart';
import '../media/watermark_gallery_bridge.dart';
import '../settings/watermark_settings.dart';
import '../watermark/watermark_overlay.dart';
import '../watermark/watermark_snapshot.dart';
import 'camera_coordinator.dart';

class CameraScreen extends StatefulWidget {
  const CameraScreen({required this.settings, super.key});

  final WatermarkSettings settings;

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  late final CameraCoordinator _cameraCoordinator;
  late final LocationService _locationService;
  late final WatermarkBridge _watermarkBridge;
  late final WatermarkGalleryBridge _galleryBridge;
  late final Timer _previewClock;
  String? _locationText;
  LocationUnavailableException? _locationFailure;
  WatermarkSnapshot? _previewSnapshot;
  bool _locationLoading = false;
  bool _locationAttempted = false;
  int _lastLocationGeneration = -1;
  bool _isShuttingDown = false;
  bool _mediaBusy = false;
  bool _handlingInterruptedRecording = false;
  WatermarkSnapshot? _recordingSnapshot;
  List<PendingWatermarkMedia> _pendingMedia = <PendingWatermarkMedia>[];
  String? _mediaMessage;

  @override
  void initState() {
    super.initState();
    _cameraCoordinator = CameraCoordinator()
      ..addListener(_handleCameraStateChanged);
    _locationService = LocationService(settings: widget.settings);
    _watermarkBridge = WatermarkBridge();
    _galleryBridge = WatermarkGalleryBridge();
    widget.settings.addListener(_handleSettingsChanged);
    unawaited(_cameraCoordinator.initialize());
    unawaited(_refreshPendingMedia());
    _previewClock = Timer.periodic(const Duration(seconds: 15), (_) {
      if (!mounted) {
        return;
      }
      setState(_refreshPreviewSnapshot);
    });
  }

  @override
  void dispose() {
    _isShuttingDown = true;
    _previewClock.cancel();
    widget.settings.removeListener(_handleSettingsChanged);
    _cameraCoordinator.removeListener(_handleCameraStateChanged);
    unawaited(_cameraCoordinator.shutdown());
    super.dispose();
  }

  void _handleCameraStateChanged() {
    if (!mounted) {
      return;
    }
    setState(() {});
    final CameraSessionState state = _cameraCoordinator.state;
    final bool cameraAvailable =
        state == CameraSessionState.ready ||
        state == CameraSessionState.processing ||
        state == CameraSessionState.recording;
    if (cameraAvailable &&
        _lastLocationGeneration != _cameraCoordinator.generation) {
      _lastLocationGeneration = _cameraCoordinator.generation;
      _locationAttempted = false;
    }
    if (state == CameraSessionState.interrupted) {
      _locationAttempted = false;
    }
    if (!_locationAttempted &&
        (state == CameraSessionState.ready ||
            state == CameraSessionState.processing ||
            state == CameraSessionState.recording)) {
      _locationAttempted = true;
      unawaited(_resolveLocation());
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
    final String manualLocation = widget.settings.manualLocation.trim();
    if (manualLocation.isNotEmpty) {
      setState(() {
        _locationText = manualLocation;
        _locationFailure = null;
        _locationLoading = false;
        _locationAttempted = true;
        _refreshPreviewSnapshot();
      });
      return;
    }

    setState(() {
      _locationText = null;
      _locationFailure = null;
      _locationAttempted = false;
      _refreshPreviewSnapshot();
    });
    unawaited(_resolveLocation());
  }

  Future<void> _resolveLocation() async {
    if (_locationLoading || _isShuttingDown) {
      return;
    }
    setState(() => _locationLoading = true);
    try {
      final String location = await _locationService.resolveLocation();
      if (!mounted) {
        return;
      }
      setState(() {
        _locationText = location;
        _locationFailure = null;
        _locationAttempted = true;
        _refreshPreviewSnapshot();
      });
    } on LocationUnavailableException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _locationText = null;
        _locationFailure = error;
        _locationAttempted = true;
        _previewSnapshot = null;
      });
    } finally {
      if (mounted) {
        setState(() => _locationLoading = false);
      }
    }
  }

  void _refreshPreviewSnapshot() {
    final String? location = _locationText;
    if (location == null || location.isEmpty) {
      _previewSnapshot = null;
      return;
    }
    _previewSnapshot = WatermarkSnapshot.capture(
      capturedAt: DateTime.now(),
      locationText: location,
      customText: widget.settings.customText,
    );
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (BuildContext context) =>
            WatermarkSettingsPage(settings: widget.settings),
      ),
    );
  }

  Future<void> _retryCamera() async {
    await _cameraCoordinator.retry();
  }

  Future<String> _locationForCapture() async {
    try {
      final String location = await _locationService.resolveLocation();
      if (!mounted || _isShuttingDown) {
        throw StateError(
          'The camera screen closed before location resolution completed.',
        );
      }
      setState(() {
        _locationText = location;
        _locationFailure = null;
        _locationAttempted = true;
        _refreshPreviewSnapshot();
      });
      return location;
    } on LocationUnavailableException catch (error) {
      if (mounted) {
        setState(() {
          _locationText = null;
          _locationFailure = error;
          _locationAttempted = true;
          _previewSnapshot = null;
        });
      }
      rethrow;
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
    if (_cameraCoordinator.state != CameraSessionState.ready || _mediaBusy) {
      return;
    }
    try {
      final String location = await _locationForCapture();
      final WatermarkSnapshot snapshot = _snapshotAt(location, DateTime.now());
      final XFile source = await _cameraCoordinator.takePicture();
      await _processCapturedMedia(source, snapshot, 'photo');
    } on Object catch (error) {
      _showMediaError(error);
    } finally {
      await _finishCameraProcessingIfPossible();
    }
  }

  Future<void> _startVideoRecording() async {
    if (_cameraCoordinator.state != CameraSessionState.ready || _mediaBusy) {
      return;
    }
    try {
      final String location = await _locationForCapture();
      WatermarkSnapshot? snapshot;
      final bool started = await _cameraCoordinator.startVideoRecording(
        onRecordingStarting: () {
          snapshot = _snapshotAt(location, DateTime.now());
          _recordingSnapshot = snapshot;
        },
      );
      if (started) {
        _recordingSnapshot =
            snapshot ??
            (throw StateError(
              'The recording began without a frozen watermark snapshot.',
            ));
        if (mounted) {
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
        _mediaBusy) {
      return;
    }
    try {
      final WatermarkSnapshot? snapshot = _recordingSnapshot;
      final XFile source = await _cameraCoordinator.stopVideoRecording();
      _recordingSnapshot = null;
      if (snapshot == null) {
        throw StateError('The recording has no frozen watermark snapshot.');
      }
      await _processCapturedMedia(source, snapshot, 'video');
    } on Object catch (error) {
      _showMediaError(error);
    } finally {
      await _finishCameraProcessingIfPossible();
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
    if (_mediaBusy) {
      throw StateError('Another media operation is already active.');
    }
    if (mounted) {
      setState(() {
        _mediaBusy = true;
        _mediaMessage = kind == 'video' ? '正在合成并保存视频…' : '正在合成并保存照片…';
      });
    }
    try {
      final String taskId = await _galleryBridge.prepareMedia(
        sourcePath: source.path,
        kind: kind,
        snapshot: snapshot,
      );
      final String renderedPath = kind == 'photo'
          ? await _watermarkBridge.renderPhoto(
              sourcePath: source.path,
              snapshot: snapshot,
            )
          : await _watermarkBridge.renderVideo(
              sourcePath: source.path,
              snapshot: snapshot,
            );
      await _galleryBridge.markRendered(
        taskId: taskId,
        renderedPath: renderedPath,
      );
      await _galleryBridge.saveToPhotos(taskId: taskId);
      if (mounted) {
        setState(() => _mediaMessage = '已保存到系统照片和“我的水印”。');
        unawaited(_refreshPendingMedia());
      }
    } on Object catch (error) {
      _showMediaError(error);
      unawaited(_refreshPendingMedia());
    } finally {
      if (mounted) {
        setState(() => _mediaBusy = false);
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

    setState(() {
      _mediaBusy = true;
      _mediaMessage = '正在恢复上次未完成的媒体…';
    });
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
        setState(() => _mediaMessage = '恢复完成，成品已保存到系统照片。');
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
            _mediaMessage?.startsWith('检测到未完成') == true) {
          _mediaMessage = null;
        } else if (pending.isEmpty &&
            (_mediaMessage?.contains('saved_but_index_failed') == true ||
                _mediaMessage?.contains('saved_but_cleanup_failed') == true)) {
          _mediaMessage = '已修复媒体登记状态，成品仍保存在系统照片中。';
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

  Future<void> _openGallery() async {
    try {
      await _galleryBridge.openGallery();
    } on Object catch (error) {
      _showMediaError(error);
    }
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
    setState(() => _mediaMessage = '媒体处理失败：$details');
  }

  void _showMediaMessage(String message) {
    if (!mounted) {
      return;
    }
    setState(() => _mediaMessage = message);
  }

  String get _statusText => switch (_cameraCoordinator.state) {
    CameraSessionState.idle => '准备相机…',
    CameraSessionState.requestingPermission => '请求相机权限…',
    CameraSessionState.initializing => '正在启动相机…',
    CameraSessionState.ready => '相机已就绪',
    CameraSessionState.recording => '录像中',
    CameraSessionState.processing => '正在处理媒体…',
    CameraSessionState.interrupted => '相机已暂停，返回后正在恢复',
    CameraSessionState.error => '相机暂不可用',
    CameraSessionState.disposed => '相机已关闭',
  };

  String? get _visibleError {
    final String? cameraError = _cameraCoordinator.cameraErrorText;
    if (cameraError != null) {
      return cameraError;
    }
    return _locationFailure?.userMessage;
  }

  String _flashLabel(FlashMode mode) {
    if (_cameraCoordinator.captureMode == CameraCaptureMode.video) {
      return switch (mode) {
        FlashMode.off => '补光关',
        FlashMode.torch => '补光开',
        FlashMode.always || FlashMode.auto => throw StateError(
          'Photo flash mode is invalid for video capture.',
        ),
      };
    }
    return switch (mode) {
      FlashMode.off => '闪光关',
      FlashMode.always => '闪光开',
      FlashMode.auto => '闪光自动',
      FlashMode.torch => throw StateError(
        'Torch mode is invalid for photo capture.',
      ),
    };
  }

  Widget _buildFlashControl(bool controlsEnabled) {
    final String? unavailableReason = _cameraCoordinator.flashUnavailableReason;
    if (unavailableReason != null) {
      return IconButton(
        onPressed: null,
        tooltip: unavailableReason,
        color: Colors.white38,
        icon: const Icon(Icons.flash_off),
      );
    }

    return PopupMenuButton<FlashMode>(
      enabled: controlsEnabled,
      tooltip: '闪光和补光设置',
      onSelected: (FlashMode mode) {
        unawaited(_cameraCoordinator.setFlashMode(mode));
      },
      itemBuilder: (BuildContext context) => _cameraCoordinator
          .supportedFlashModes
          .map(
            (FlashMode mode) => PopupMenuItem<FlashMode>(
              value: mode,
              child: Text(_flashLabel(mode)),
            ),
          )
          .toList(growable: false),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            _cameraCoordinator.flashMode == FlashMode.off
                ? Icons.flash_off
                : Icons.flash_on,
            color: controlsEnabled ? Colors.white : Colors.white38,
          ),
          const SizedBox(width: 4),
          Text(
            _flashLabel(_cameraCoordinator.flashMode),
            style: TextStyle(
              color: controlsEnabled ? Colors.white : Colors.white38,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCaptureButton(CameraSessionState cameraState) {
    final bool isRecording = cameraState == CameraSessionState.recording;
    final bool isReady = cameraState == CameraSessionState.ready;
    final bool canCapture = isReady && _locationText != null && !_mediaBusy;
    final VoidCallback? onPressed = isRecording
        ? () => unawaited(_stopVideoRecording())
        : !canCapture
        ? null
        : _cameraCoordinator.captureMode == CameraCaptureMode.photo
        ? () => unawaited(_capturePhoto())
        : () => unawaited(_startVideoRecording());
    final IconData icon = isRecording
        ? Icons.stop_rounded
        : _cameraCoordinator.captureMode == CameraCaptureMode.photo
        ? Icons.camera_alt_rounded
        : Icons.fiber_manual_record_rounded;
    return SizedBox(
      width: 72,
      height: 72,
      child: IconButton.filled(
        tooltip: isRecording
            ? '停止录像'
            : _cameraCoordinator.captureMode == CameraCaptureMode.photo
            ? '拍摄照片'
            : '开始录像',
        onPressed: onPressed,
        style: IconButton.styleFrom(
          backgroundColor: isRecording ? Colors.red : Colors.white,
          foregroundColor: isRecording ? Colors.white : Colors.black,
          disabledBackgroundColor: Colors.white24,
          disabledForegroundColor: Colors.white38,
        ),
        icon: _mediaBusy
            ? const SizedBox.square(
                dimension: 30,
                child: CircularProgressIndicator(strokeWidth: 3),
              )
            : Icon(icon, size: 34),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final CameraController? controller = _cameraCoordinator.controller;
    final CameraSessionState cameraState = _cameraCoordinator.state;
    final bool canChangeMode = cameraState == CameraSessionState.ready;

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            if (controller != null && controller.value.isInitialized)
              Center(
                child: CameraPreview(
                  controller,
                  child: _previewSnapshot == null
                      ? const SizedBox.expand()
                      : WatermarkOverlay(snapshot: _previewSnapshot!),
                ),
              )
            else
              const ColoredBox(color: Colors.black),
            Positioned(
              top: 0,
              left: 12,
              right: 12,
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      _statusText,
                      style: const TextStyle(color: Colors.white),
                    ),
                  ),
                  IconButton(
                    tooltip: '我的水印',
                    color: Colors.white,
                    onPressed:
                        _mediaBusy ||
                            cameraState == CameraSessionState.recording ||
                            cameraState == CameraSessionState.processing
                        ? null
                        : _openGallery,
                    icon: const Icon(Icons.photo_library_outlined),
                  ),
                  IconButton(
                    tooltip: '水印设置',
                    color: Colors.white,
                    onPressed: _openSettings,
                    icon: const Icon(Icons.tune),
                  ),
                ],
              ),
            ),
            if (_visibleError case final String errorText)
              Positioned(
                top: 54,
                left: 16,
                right: 16,
                child: _StatusCard(
                  message: errorText,
                  actionLabel: cameraState == CameraSessionState.error
                      ? '重试相机'
                      : '填写地点',
                  onAction: cameraState == CameraSessionState.error
                      ? _retryCamera
                      : _openSettings,
                ),
              ),
            Positioned(
              left: 12,
              right: 12,
              bottom: 20,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  if (_locationText == null && _locationFailure == null)
                    Text(
                      _locationLoading ? '正在获取地点…' : '请填写地点后拍摄',
                      style: const TextStyle(color: Colors.white),
                    ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: <Widget>[
                      IconButton(
                        tooltip: _cameraCoordinator.canSwitchCamera
                            ? '切换前后摄像头'
                            : '当前设备没有可切换的镜头',
                        color: Colors.white,
                        onPressed:
                            canChangeMode && _cameraCoordinator.canSwitchCamera
                            ? () => unawaited(_cameraCoordinator.switchCamera())
                            : null,
                        icon: const Icon(Icons.cameraswitch_outlined),
                      ),
                      _buildFlashControl(canChangeMode),
                    ],
                  ),
                  SegmentedButton<CameraCaptureMode>(
                    segments: const <ButtonSegment<CameraCaptureMode>>[
                      ButtonSegment<CameraCaptureMode>(
                        value: CameraCaptureMode.photo,
                        label: Text('照片'),
                        icon: Icon(Icons.photo_camera_outlined),
                      ),
                      ButtonSegment<CameraCaptureMode>(
                        value: CameraCaptureMode.video,
                        label: Text('视频'),
                        icon: Icon(Icons.videocam_outlined),
                      ),
                    ],
                    selected: <CameraCaptureMode>{
                      _cameraCoordinator.captureMode,
                    },
                    onSelectionChanged: canChangeMode
                        ? (Set<CameraCaptureMode> selected) {
                            if (selected.length != 1) {
                              throw StateError(
                                'Exactly one camera capture mode must be selected.',
                              );
                            }
                            unawaited(
                              _cameraCoordinator.setCaptureMode(
                                selected.single,
                              ),
                            );
                          }
                        : null,
                  ),
                  const SizedBox(height: 12),
                  if (_mediaMessage case final String mediaMessage)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Text(
                            mediaMessage,
                            textAlign: TextAlign.center,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white),
                          ),
                          if (_pendingMedia.any(
                            (PendingWatermarkMedia item) =>
                                item.status != 'saving',
                          ))
                            TextButton.icon(
                              onPressed: _mediaBusy
                                  ? null
                                  : () => unawaited(_restorePendingMedia()),
                              icon: const Icon(Icons.restore),
                              label: const Text('恢复未完成媒体'),
                            ),
                          if (_pendingMedia.isEmpty &&
                              _mediaMessage?.startsWith('媒体处理失败：') == true &&
                              !_mediaMessage!.contains(
                                'photo_save_result_uncertain',
                              ))
                            TextButton.icon(
                              onPressed: _mediaBusy
                                  ? null
                                  : () => unawaited(_refreshPendingMedia()),
                              icon: const Icon(Icons.refresh),
                              label: const Text('重新检查恢复状态'),
                            ),
                          if (_mediaMessage!.contains('permission_denied'))
                            TextButton.icon(
                              onPressed: _openSystemSettings,
                              icon: const Icon(Icons.settings_outlined),
                              label: const Text('打开系统设置'),
                            ),
                        ],
                      ),
                    ),
                  _buildCaptureButton(cameraState),
                  const SizedBox(height: 8),
                  Text(
                    _locationText ?? '地点不可用',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white70),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
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
      color: Colors.black.withValues(alpha: 0.72),
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(message, style: const TextStyle(color: Colors.white)),
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
