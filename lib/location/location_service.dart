import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';

import '../settings/watermark_settings.dart';

enum LocationUnavailableReason {
  serviceDisabled,
  permissionDenied,
  permissionDeniedForever,
  permissionUnknown,
  timedOut,
  stalePosition,
  invalidCoordinates,
  noPlacemark,
  locationTooLong,
  platformFailure,
}

class LocationUnavailableException implements Exception {
  LocationUnavailableException(
    this.reason, {
    this.platformCode,
    this.platformMessage,
  }) {
    final bool isPlatformFailure =
        reason == LocationUnavailableReason.platformFailure;
    final String? errorCode = platformCode;
    if (isPlatformFailure && (errorCode == null || errorCode.isEmpty)) {
      throw ArgumentError.value(
        errorCode,
        'platformCode',
        'A platform error code is required for a platform failure.',
      );
    }
    if (!isPlatformFailure &&
        (platformCode != null || platformMessage != null)) {
      throw ArgumentError(
        'Platform error details are only valid for a platform failure.',
      );
    }
  }

  final LocationUnavailableReason reason;
  final String? platformCode;
  final String? platformMessage;

  String get userMessage {
    if (reason == LocationUnavailableReason.platformFailure) {
      final String code = platformCode!;
      final String? message = platformMessage;
      return message == null || message.isEmpty
          ? '定位服务失败（$code），请重试或手动填写地点。'
          : '定位服务失败（$code）：$message';
    }
    return switch (reason) {
      LocationUnavailableReason.serviceDisabled => '系统定位服务已关闭，请开启定位或手动填写地点。',
      LocationUnavailableReason.permissionDenied => '未获得定位权限，请允许使用定位或手动填写地点。',
      LocationUnavailableReason.permissionDeniedForever =>
        '定位权限已被拒绝，请到系统设置中允许定位或手动填写地点。',
      LocationUnavailableReason.permissionUnknown =>
        '无法确定定位权限状态，请检查系统设置或手动填写地点。',
      LocationUnavailableReason.timedOut => '定位超时，请重试或手动填写地点。',
      LocationUnavailableReason.stalePosition => '定位结果已过期，请重试或手动填写地点。',
      LocationUnavailableReason.invalidCoordinates => '定位返回了无效坐标，请重试或手动填写地点。',
      LocationUnavailableReason.noPlacemark => '无法解析当前位置的地名，请手动填写地点。',
      LocationUnavailableReason.locationTooLong =>
        '当前位置名称超过 40 个字符，请在设置中填写较短地点。',
      LocationUnavailableReason.platformFailure => throw StateError(
        'Platform failure details are required.',
      ),
    };
  }

  @override
  String toString() => 'LocationUnavailableException: $userMessage';
}

class LocationService {
  LocationService({required this.settings})
    : _geocoding = Geocoding(locale: const Locale('zh', 'CN'));

  static const Duration _maximumPositionAge = Duration(seconds: 60);
  static const Duration _operationTimeout = Duration(seconds: 20);

  final WatermarkSettings settings;
  final Geocoding _geocoding;
  String? _cachedAutomaticLocation;
  DateTime? _cachedPositionTime;

  Future<String> resolveLocation() async {
    try {
      return await _resolveLocation();
    } on PlatformException catch (error) {
      throw LocationUnavailableException(
        LocationUnavailableReason.platformFailure,
        platformCode: error.code,
        platformMessage: error.message,
      );
    }
  }

  Future<String> _resolveLocation() async {
    final String manualLocation = settings.manualLocation.trim();
    if (manualLocation.isNotEmpty) {
      return manualLocation;
    }

    final String? cachedLocation = _cachedAutomaticLocation;
    final DateTime? cachedPositionTime = _cachedPositionTime;
    if (cachedLocation != null && cachedPositionTime != null) {
      final Duration cachedAge = DateTime.now().difference(
        cachedPositionTime.toLocal(),
      );
      if (!cachedAge.isNegative && cachedAge <= _maximumPositionAge) {
        return cachedLocation;
      }
    }

    if (!await Geolocator.isLocationServiceEnabled()) {
      throw LocationUnavailableException(
        LocationUnavailableReason.serviceDisabled,
      );
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    switch (permission) {
      case LocationPermission.denied:
        throw LocationUnavailableException(
          LocationUnavailableReason.permissionDenied,
        );
      case LocationPermission.deniedForever:
        throw LocationUnavailableException(
          LocationUnavailableReason.permissionDeniedForever,
        );
      case LocationPermission.unableToDetermine:
        throw LocationUnavailableException(
          LocationUnavailableReason.permissionUnknown,
        );
      case LocationPermission.whileInUse:
      case LocationPermission.always:
        break;
    }

    final Position position = await _withLocationTimeout<Position>(
      Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      ),
    );
    final DateTime positionTime = position.timestamp.toLocal();
    final Duration positionAge = DateTime.now().difference(positionTime);
    if (positionAge.isNegative || positionAge > _maximumPositionAge) {
      throw LocationUnavailableException(
        LocationUnavailableReason.stalePosition,
      );
    }
    if (!position.latitude.isFinite ||
        !position.longitude.isFinite ||
        position.latitude < -90 ||
        position.latitude > 90 ||
        position.longitude < -180 ||
        position.longitude > 180) {
      throw LocationUnavailableException(
        LocationUnavailableReason.invalidCoordinates,
      );
    }

    final List<Placemark> placemarks =
        await _withLocationTimeout<List<Placemark>>(
          _geocoding.placemarkFromCoordinates(
            position.latitude,
            position.longitude,
          ),
        );
    if (placemarks.isEmpty) {
      throw LocationUnavailableException(LocationUnavailableReason.noPlacemark);
    }

    final String location = _formatPlacemark(placemarks.first);
    if (location.isEmpty) {
      throw LocationUnavailableException(LocationUnavailableReason.noPlacemark);
    }
    if (location.characters.length > 40) {
      throw LocationUnavailableException(
        LocationUnavailableReason.locationTooLong,
      );
    }

    _cachedAutomaticLocation = location;
    _cachedPositionTime = positionTime;
    return location;
  }

  Future<T> _withLocationTimeout<T>(Future<T> operation) => operation.timeout(
    _operationTimeout,
    onTimeout: () =>
        throw LocationUnavailableException(LocationUnavailableReason.timedOut),
  );

  String _formatPlacemark(Placemark placemark) {
    final String? locality = _nonEmpty(placemark.locality);
    final String? secondary =
        _nonEmpty(placemark.subLocality) ?? _nonEmpty(placemark.name);
    final List<String> parts = <String>[];
    if (locality != null) {
      parts.add(locality);
    }
    if (secondary != null && secondary != locality) {
      parts.add(secondary);
    }
    return parts.join('');
  }

  String? _nonEmpty(String? value) {
    final String trimmed = value?.trim() ?? '';
    return trimmed.isEmpty ? null : trimmed;
  }
}
