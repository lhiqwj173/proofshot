import 'package:flutter/services.dart';

class SelectedMapCoordinate {
  const SelectedMapCoordinate({
    required this.latitude,
    required this.longitude,
    required this.candidates,
  });

  final double latitude;
  final double longitude;
  final List<NearbyMapPlace> candidates;
}

class NearbyMapPlace {
  const NearbyMapPlace({
    required this.name,
    required this.address,
    required this.distanceMeters,
  });

  final String name;
  final String address;
  final double distanceMeters;
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
    if (response.length != 3 ||
        response['latitude'] is! num ||
        response['longitude'] is! num ||
        response['candidates'] is! List<Object?>) {
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
    final List<Object?> rawCandidates =
        response['candidates']! as List<Object?>;
    final List<NearbyMapPlace> candidates = rawCandidates
        .map((Object? item) {
          if (item is! Map<Object?, Object?> ||
              item.length != 3 ||
              item['name'] is! String ||
              item['address'] is! String ||
              item['distanceMeters'] is! num) {
            throw const FormatException(
              'Map picker returned an invalid nearby place.',
            );
          }
          final String name = item['name']! as String;
          final String address = item['address']! as String;
          final double distance = (item['distanceMeters']! as num).toDouble();
          if (name.trim().isEmpty ||
              !distance.isFinite ||
              distance < 0 ||
              distance > 100) {
            throw const FormatException(
              'Map picker returned an out-of-range nearby place.',
            );
          }
          return NearbyMapPlace(
            name: name,
            address: address,
            distanceMeters: distance,
          );
        })
        .toList(growable: false);
    return SelectedMapCoordinate(
      latitude: latitude,
      longitude: longitude,
      candidates: candidates,
    );
  }
}
