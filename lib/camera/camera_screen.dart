import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../design/app_palette.dart';
import '../location/location_service.dart';
import '../location/location_map_picker.dart';
import '../media/watermark_bridge.dart';
import '../media/watermark_gallery_bridge.dart';
import '../settings/watermark_settings.dart';
import '../watermark/live_watermark_preview.dart';
import '../watermark/watermark_snapshot.dart';
import 'camera_coordinator.dart';
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
  WatermarkSnapshot? _recordingSnapshot;
  List<PendingWatermarkMedia> _pendingMedia = <PendingWatermarkMedia>[];
  RecentCaptureThumbnail? _recentThumbnail;
  Uint8List? _recentThumbnailBytes;
  String? _mediaMessage;

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
    _hardwareCaptureBridge = HardwareCaptureBridge(_capturePhoto);
    widget.settings.addListener(_handleSettingsChanged);
    unawaited(_cameraCoordinator.initialize());
    unawaited(_refreshPendingMedia());
    unawaited(_loadRecentThumbnail());
  }

  @override
  void dispose() {
    _isShuttingDown = true;
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
      final XFile source = await _cameraCoordinator.takePicture();
      await _updateRecentThumbnail(source.path, 'photo');
      await _processCapturedMedia(source, snapshot, 'photo');
    } on Object catch (error) {
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
      await _updateRecentThumbnail(source.path, 'video');
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
      await _updateRecentThumbnail(renderedPath, kind);
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
    setState(() => _mediaMessage = '媒体处理失败：$details');
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
        height: 44,
        width: 44,
        alignment: Alignment.center,
        child: Icon(
          mode == FlashMode.off
              ? Icons.flash_off_rounded
              : Icons.flash_on_rounded,
          color: enabled
              ? mode == FlashMode.off
                    ? Colors.white
                    : _cameraYellow
              : Colors.white38,
          size: 22,
        ),
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
        fixedSize: const Size(44, 44),
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        disabledForegroundColor: Colors.white38,
        shape: const CircleBorder(),
      ),
      icon: Icon(icon, size: 24),
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
        fixedSize: const Size(44, 44),
        foregroundColor: Colors.white,
        disabledForegroundColor: Colors.white38,
        shape: const CircleBorder(),
      ),
      icon: _locationLoading
          ? const SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            )
          : const Icon(Icons.gps_fixed_rounded, size: 22),
    );
  }

  Widget _buildTopBar(CameraSessionState cameraState) {
    return Row(
      children: <Widget>[
        const Spacer(),
        DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(32),
            boxShadow: const <BoxShadow>[
              BoxShadow(
                color: Color(0x66000000),
                blurRadius: 14,
                offset: Offset(0, 3),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(32),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
              child: Container(
                padding: const EdgeInsets.all(4),
                color: const Color(0xE6242426),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    _buildFlashControl(cameraState == CameraSessionState.ready),
                    _buildLocationControl(cameraState),
                    _buildTopAction(
                      tooltip: '设置',
                      icon: Icons.more_horiz_rounded,
                      onPressed: _locationLoading ? null : _openSettings,
                    ),
                  ],
                ),
              ),
            ),
          ),
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
          const SizedBox(height: 36),
          _buildCaptureModeControl(canChangeMode),
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
                  child: _buildCameraPreview(controller),
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
