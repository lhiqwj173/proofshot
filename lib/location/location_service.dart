import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';

enum LocationUnavailableReason {
  serviceDisabled,
  permissionDenied,
  permissionDeniedForever,
  permissionUnknown,
  timedOut,
  stalePosition,
  invalidCoordinates,
  invalidAccuracy,
  inaccuratePosition,
  reducedAccuracy,
  precisionUnknown,
  noPlacemark,
  locationTooLong,
  platformFailure,
}

class LocationUnavailableException implements Exception {
  LocationUnavailableException(
    this.reason, {
    this.platformCode,
    this.platformMessage,
    this.accuracyMeters,
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
    if (reason == LocationUnavailableReason.inaccuratePosition) {
      if (accuracyMeters == null ||
          !accuracyMeters!.isFinite ||
          accuracyMeters! < 0) {
        throw ArgumentError.value(
          accuracyMeters,
          'accuracyMeters',
          'An inaccurate position requires a finite horizontal accuracy.',
        );
      }
    } else if (accuracyMeters != null) {
      throw ArgumentError.value(
        accuracyMeters,
        'accuracyMeters',
        'Horizontal accuracy is only valid for an inaccurate position.',
      );
    }
  }

  final LocationUnavailableReason reason;
  final String? platformCode;
  final String? platformMessage;
  final double? accuracyMeters;

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
      LocationUnavailableReason.invalidAccuracy => '定位没有返回有效精度，请重试或手动填写地点。',
      LocationUnavailableReason.inaccuratePosition =>
        '当前定位误差约 ${accuracyMeters!.ceil()} 米，超过 100 米，请到开阔处刷新或手动填写地点。',
      LocationUnavailableReason.reducedAccuracy =>
        '系统只允许模糊位置，请在系统设置中开启“精确位置”后刷新。',
      LocationUnavailableReason.precisionUnknown => '无法确认系统定位精度，请检查定位权限后重试。',
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

class ResolvedLocation {
  const ResolvedLocation({required this.text, required this.accuracyMeters});

  final String text;
  final double accuracyMeters;
}

class LocationService {
  LocationService() : _geocoding = Geocoding(locale: const Locale('zh', 'CN'));

  static const Duration _maximumPositionAge = Duration(seconds: 60);
  static const Duration _operationTimeout = Duration(seconds: 20);
  static const double _maximumHorizontalAccuracyMeters = 100;

  final Geocoding _geocoding;

  Future<ResolvedLocation> refreshLocation() async {
    try {
      return await _refreshLocation();
    } on TimeoutException {
      throw LocationUnavailableException(LocationUnavailableReason.timedOut);
    } on PlatformException catch (error) {
      throw LocationUnavailableException(
        LocationUnavailableReason.platformFailure,
        platformCode: error.code,
        platformMessage: error.message,
      );
    }
  }

  Future<ResolvedLocation> _refreshLocation() async {
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

    final LocationAccuracyStatus accuracyStatus =
        await Geolocator.getLocationAccuracy();
    if (accuracyStatus == LocationAccuracyStatus.reduced) {
      throw LocationUnavailableException(
        LocationUnavailableReason.reducedAccuracy,
      );
    }
    if (accuracyStatus != LocationAccuracyStatus.precise) {
      throw LocationUnavailableException(
        LocationUnavailableReason.precisionUnknown,
      );
    }

    final Position position = await _withLocationTimeout<Position>(
      Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.best,
          timeLimit: _operationTimeout,
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
    final double horizontalAccuracy = position.accuracy;
    if (!horizontalAccuracy.isFinite || horizontalAccuracy < 0) {
      throw LocationUnavailableException(
        LocationUnavailableReason.invalidAccuracy,
      );
    }
    if (horizontalAccuracy > _maximumHorizontalAccuracyMeters) {
      throw LocationUnavailableException(
        LocationUnavailableReason.inaccuratePosition,
        accuracyMeters: horizontalAccuracy,
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

    return ResolvedLocation(text: location, accuracyMeters: horizontalAccuracy);
  }

  Future<T> _withLocationTimeout<T>(Future<T> operation) => operation.timeout(
    _operationTimeout,
    onTimeout: () =>
        throw LocationUnavailableException(LocationUnavailableReason.timedOut),
  );

  String _formatPlacemark(Placemark placemark) {
    final String? administrativeArea = _nonEmpty(placemark.administrativeArea);
    final String? locality = _nonEmpty(placemark.locality);
    final String? subAdministrativeArea = _nonEmpty(
      placemark.subAdministrativeArea,
    );
    final String? street =
        _nonEmpty(placemark.thoroughfare) ?? _nonEmpty(placemark.street);
    final List<String> parts = <String>[];
    for (final String? value in <String?>[
      administrativeArea,
      locality,
      subAdministrativeArea,
      _nonEmpty(placemark.subLocality),
      street,
      if (street != null) _nonEmpty(placemark.subThoroughfare),
    ]) {
      if (value == null) {
        continue;
      }
      String uniquePart = value;
      for (final String existing in parts) {
        if (existing.contains(uniquePart)) {
          uniquePart = '';
          break;
        }
        uniquePart = uniquePart.replaceAll(existing, '');
      }
      uniquePart = uniquePart.trim();
      if (uniquePart.isNotEmpty && !parts.contains(uniquePart)) {
        parts.add(uniquePart);
      }
    }
    return parts.join('');
  }

  String? _nonEmpty(String? value) {
    final String trimmed = value?.trim() ?? '';
    return trimmed.isEmpty ? null : trimmed;
  }
}
