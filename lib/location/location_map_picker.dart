import 'package:flutter/services.dart';

class SelectedMapCoordinate {
  const SelectedMapCoordinate({
    required this.latitude,
    required this.longitude,
  });

  final double latitude;
  final double longitude;
}

class LocationMapPicker {
  static const MethodChannel _channel = MethodChannel(
    'proofshot/location_picker',
  );

  Future<SelectedMapCoordinate?> open() async {
    final Map<String, Object?>? response = await _channel
        .invokeMapMethod<String, Object?>('openPicker');
    if (response == null) {
      return null;
    }
    if (response.length != 2 ||
        response['latitude'] is! num ||
        response['longitude'] is! num) {
      throw const FormatException('Map picker returned invalid coordinates.');
    }
    final double latitude = (response['latitude']! as num).toDouble();
    final double longitude = (response['longitude']! as num).toDouble();
    if (!latitude.isFinite ||
        !longitude.isFinite ||
        latitude < -90 ||
        latitude > 90 ||
        longitude < -180 ||
        longitude > 180) {
      throw const FormatException(
        'Map picker returned out-of-range coordinates.',
      );
    }
    return SelectedMapCoordinate(latitude: latitude, longitude: longitude);
  }
}
