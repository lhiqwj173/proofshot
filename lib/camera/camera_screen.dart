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
import 'hardware_capture_bridge.dart';

class CameraScreen extends StatefulWidget {
  const CameraScreen({required this.settings, super.key});

  final WatermarkSettings settings;

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  static const Color _accentColor = Color(0xFFC6F4D5);
  static const Color _recordingColor = Color(0xFFFF716B);

  late final CameraCoordinator _cameraCoordinator;
  late final LocationService _locationService;
  late final WatermarkBridge _watermarkBridge;
  late final WatermarkGalleryBridge _galleryBridge;
  late final HardwareCaptureBridge _hardwareCaptureBridge;
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
  bool _settingsOpen = false;
  bool _galleryOpen = false;
  bool? _hardwareCaptureEnabled;
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
    _hardwareCaptureBridge = HardwareCaptureBridge(_capturePhoto);
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
      _syncHardwareCapture();
      return;
    }

    setState(() {
      _locationText = null;
      _locationFailure = null;
      _locationAttempted = false;
      _refreshPreviewSnapshot();
    });
    unawaited(_resolveLocation());
    _syncHardwareCapture();
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
      _syncHardwareCapture();
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
        _syncHardwareCapture();
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
    if (_cameraCoordinator.state != CameraSessionState.ready ||
        _cameraCoordinator.captureMode != CameraCaptureMode.photo ||
        _locationText == null ||
        _mediaBusy ||
        _isShuttingDown ||
        _settingsOpen ||
        _galleryOpen) {
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
        _mediaMessage = null;
      });
      _syncHardwareCapture();
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
        unawaited(_refreshPendingMedia());
      }
    } on Object catch (error) {
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

  Widget _buildCameraSwitchControl(bool controlsEnabled) {
    final bool canSwitch =
        controlsEnabled && _cameraCoordinator.canSwitchCamera;
    return IconButton(
      tooltip: canSwitch ? '切换前后摄像头' : '当前设备没有可切换的镜头',
      onPressed: canSwitch
          ? () => unawaited(_cameraCoordinator.switchCamera())
          : null,
      style: IconButton.styleFrom(
        fixedSize: const Size(54, 54),
        backgroundColor: const Color(0xFF1E292A),
        foregroundColor: canSwitch ? Colors.white : Colors.white38,
        shape: const CircleBorder(),
      ),
      icon: const Icon(Icons.flip_camera_ios_outlined, size: 24),
    );
  }

  Widget _buildFlashControl(bool controlsEnabled) {
    final String? unavailableReason = _cameraCoordinator.flashUnavailableReason;
    final bool enabled = controlsEnabled && unavailableReason == null;
    final FlashMode mode = _cameraCoordinator.flashMode;
    return PopupMenuButton<FlashMode>(
      enabled: enabled,
      tooltip: unavailableReason ?? '闪光和补光设置',
      onSelected: (FlashMode selectedMode) {
        unawaited(_cameraCoordinator.setFlashMode(selectedMode));
      },
      itemBuilder: (BuildContext context) => _cameraCoordinator
          .supportedFlashModes
          .map(
            (FlashMode supportedMode) => PopupMenuItem<FlashMode>(
              value: supportedMode,
              child: Text(_flashLabel(supportedMode)),
            ),
          )
          .toList(growable: false),
      child: Container(
        height: 42,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: const Color(0xD9131A1B),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white24),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              mode == FlashMode.off
                  ? Icons.flash_off_outlined
                  : Icons.flash_on_outlined,
              color: enabled ? _accentColor : Colors.white38,
              size: 19,
            ),
            const SizedBox(width: 7),
            Text(
              unavailableReason == null ? _flashLabel(mode) : '不可用',
              style: TextStyle(
                color: enabled ? Colors.white : Colors.white38,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCaptureModeControl(bool canChangeMode) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        _buildCaptureModeOption(
          mode: CameraCaptureMode.photo,
          label: '拍照',
          canChangeMode: canChangeMode,
        ),
        const SizedBox(width: 32),
        _buildCaptureModeOption(
          mode: CameraCaptureMode.video,
          label: '录像',
          canChangeMode: canChangeMode,
        ),
      ],
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
        onTap: !canChangeMode || selected
            ? null
            : () => unawaited(_cameraCoordinator.setCaptureMode(mode)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 13),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                label,
                style: TextStyle(
                  color: selected ? _accentColor : Colors.white54,
                  fontSize: 15,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  letterSpacing: 1,
                ),
              ),
              const SizedBox(height: 6),
              AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                width: selected ? 18 : 0,
                height: 2,
                decoration: BoxDecoration(
                  color: _accentColor,
                  borderRadius: BorderRadius.circular(1),
                ),
              ),
            ],
          ),
        ),
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
    final String tooltip = isRecording
        ? '停止录像'
        : _cameraCoordinator.captureMode == CameraCaptureMode.photo
        ? '拍摄照片'
        : '开始录像';
    final Widget centerMark = _mediaBusy
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

  Widget _buildLocationIndicator() {
    final String location =
        _locationText ?? (_locationLoading ? '正在获取街道位置…' : '点击填写拍摄地点');
    return Material(
      color: const Color(0xE611191A),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: _openSettings,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
          child: Row(
            children: <Widget>[
              const Icon(
                Icons.location_on_outlined,
                color: _accentColor,
                size: 17,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  location,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                ),
              ),
              const Icon(
                Icons.chevron_right_rounded,
                color: Colors.white54,
                size: 18,
              ),
            ],
          ),
        ),
      ),
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
        color: const Color(0xEE141D1F),
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
              onPressed: _mediaBusy
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
        fixedSize: const Size(42, 42),
        backgroundColor: const Color(0xFF1D2829),
        foregroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      icon: Icon(icon, size: 20),
    );
  }

  Widget _buildTopBar(CameraSessionState cameraState) {
    final Color stateColor = switch (cameraState) {
      CameraSessionState.ready => _accentColor,
      CameraSessionState.recording => _recordingColor,
      CameraSessionState.error => const Color(0xFFFFC56E),
      _ => Colors.white54,
    };
    return Row(
      children: <Widget>[
        Container(
          width: 42,
          height: 42,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: _accentColor,
            borderRadius: BorderRadius.circular(12),
          ),
          child: const Icon(
            Icons.center_focus_strong,
            color: Color(0xFF12201A),
            size: 22,
          ),
        ),
        const SizedBox(width: 11),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Text(
                'PROOFSHOT',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 2,
                ),
              ),
              const SizedBox(height: 2),
              Row(
                children: <Widget>[
                  Container(
                    width: 5,
                    height: 5,
                    decoration: BoxDecoration(
                      color: stateColor,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      _statusText,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white60,
                        fontSize: 10,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        _buildFlashControl(cameraState == CameraSessionState.ready),
        const SizedBox(width: 8),
        _buildTopAction(
          tooltip: '水印设置',
          icon: Icons.tune_rounded,
          onPressed: _openSettings,
        ),
      ],
    );
  }

  Widget _buildGalleryControl(CameraSessionState cameraState) {
    final bool enabled =
        !_mediaBusy &&
        cameraState != CameraSessionState.recording &&
        cameraState != CameraSessionState.processing;
    return IconButton(
      tooltip: '我的水印',
      onPressed: enabled ? _openGallery : null,
      style: IconButton.styleFrom(
        fixedSize: const Size(54, 54),
        backgroundColor: const Color(0xFF1E292A),
        foregroundColor: Colors.white,
        shape: const CircleBorder(),
      ),
      icon: const Icon(Icons.grid_view_rounded, size: 23),
    );
  }

  @override
  Widget build(BuildContext context) {
    final CameraController? controller = _cameraCoordinator.controller;
    final CameraSessionState cameraState = _cameraCoordinator.state;
    final bool canChangeMode = cameraState == CameraSessionState.ready;

    return Scaffold(
      backgroundColor: const Color(0xFF0D1516),
      body: SafeArea(
        child: Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
              child: _buildTopBar(cameraState),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(20),
                  child: Stack(
                    fit: StackFit.expand,
                    children: <Widget>[
                      ColoredBox(
                        color: Colors.black,
                        child:
                            controller != null && controller.value.isInitialized
                            ? Center(
                                child: CameraPreview(
                                  controller,
                                  child: _previewSnapshot == null
                                      ? const SizedBox.expand()
                                      : WatermarkOverlay(
                                          snapshot: _previewSnapshot!,
                                        ),
                                ),
                              )
                            : const SizedBox.expand(),
                      ),
                      IgnorePointer(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: Colors.white12),
                          ),
                        ),
                      ),
                      if (_visibleError case final String errorText)
                        Positioned(
                          top: 16,
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
                      if (_mediaMessage case final String mediaMessage)
                        Positioned(
                          top: _visibleError == null ? 16 : 114,
                          left: 16,
                          right: 16,
                          child: _buildMediaMessage(mediaMessage),
                        ),
                      Positioned(
                        left: 14,
                        right: 14,
                        bottom: 14,
                        child: _buildLocationIndicator(),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 5, 24, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  _buildCaptureModeControl(canChangeMode),
                  const SizedBox(height: 14),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: <Widget>[
                      _buildGalleryControl(cameraState),
                      _buildCaptureButton(cameraState),
                      _buildCameraSwitchControl(canChangeMode),
                    ],
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
      color: const Color(0xF0192526),
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
