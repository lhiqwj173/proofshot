import 'package:flutter/widgets.dart';

/// Immutable watermark values captured when a photo is taken or recording starts.
@immutable
class WatermarkSnapshot {
  const WatermarkSnapshot._({
    required this.capturedAt,
    required this.timeText,
    required this.dateText,
    required this.weekdayText,
    required this.locationText,
    required this.customText,
    required this.brandText,
  });

  static const String brand = '水印相机';
  static const int maximumLocationGraphemes = 40;
  static const int maximumCustomGraphemes = 30;

  static const List<String> _weekdays = <String>[
    '星期一',
    '星期二',
    '星期三',
    '星期四',
    '星期五',
    '星期六',
    '星期日',
  ];

  factory WatermarkSnapshot.fromMap(Map<String, Object?> value) {
    const Set<String> expectedKeys = <String>{
      'capturedAt',
      'timeText',
      'dateText',
      'weekdayText',
      'locationText',
      'customText',
      'brandText',
    };
    if (value.keys.toSet().difference(expectedKeys).isNotEmpty ||
        expectedKeys.difference(value.keys.toSet()).isNotEmpty) {
      throw const FormatException(
        'Snapshot fields do not match the required schema.',
      );
    }
    final Map<String, String> fields = <String, String>{};
    for (final String key in expectedKeys) {
      final Object? field = value[key];
      if (field is! String) {
        throw FormatException('Snapshot field $key must be a string.');
      }
      fields[key] = field;
    }

    final String capturedAt = fields['capturedAt']!;
    final RegExpMatch? timestampMatch = RegExp(
      r'^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})(?:\.[0-9]+)?([+-][0-9]{2}:[0-9]{2})$',
    ).firstMatch(capturedAt);
    if (timestampMatch == null) {
      throw const FormatException(
        'capturedAt must be an ISO 8601 timestamp with a numeric UTC offset.',
      );
    }
    if (!DateTime.parse(capturedAt).isUtc) {
      throw const FormatException('capturedAt must include a UTC offset.');
    }
    final int year = int.parse(timestampMatch.group(1)!);
    final int month = int.parse(timestampMatch.group(2)!);
    final int day = int.parse(timestampMatch.group(3)!);
    final int hour = int.parse(timestampMatch.group(4)!);
    final int minute = int.parse(timestampMatch.group(5)!);
    final int second = int.parse(timestampMatch.group(6)!);
    final DateTime localComponents = DateTime.utc(
      year,
      month,
      day,
      hour,
      minute,
      second,
    );
    if (localComponents.year != year ||
        localComponents.month != month ||
        localComponents.day != day ||
        hour > 23 ||
        minute > 59 ||
        second > 59) {
      throw const FormatException(
        'capturedAt contains an invalid date or time.',
      );
    }
    final String expectedDate =
        '${year.toString().padLeft(4, '0')}.${_twoDigits(month)}.${_twoDigits(day)}';
    if (fields['timeText'] != '${_twoDigits(hour)}:${_twoDigits(minute)}' ||
        fields['dateText'] != expectedDate ||
        fields['weekdayText'] != _weekdays[localComponents.weekday - 1]) {
      throw const FormatException(
        'Snapshot date and time fields are inconsistent.',
      );
    }
    final String locationText = fields['locationText']!;
    final String customText = fields['customText']!;
    if (locationText.trim() != locationText ||
        locationText.isEmpty ||
        locationText.characters.length > maximumLocationGraphemes) {
      throw const FormatException(
        'locationText must contain 1 to 40 graphemes.',
      );
    }
    if (customText.trim() != customText ||
        customText.characters.length > maximumCustomGraphemes) {
      throw const FormatException(
        'customText must contain at most 30 graphemes.',
      );
    }
    if (fields['brandText'] != brand) {
      throw const FormatException('brandText must be 水印相机.');
    }
    return WatermarkSnapshot._(
      capturedAt: capturedAt,
      timeText: fields['timeText']!,
      dateText: fields['dateText']!,
      weekdayText: fields['weekdayText']!,
      locationText: locationText,
      customText: customText,
      brandText: brand,
    );
  }

  /// Local capture time encoded as ISO 8601 with an explicit UTC offset.
  final String capturedAt;
  final String timeText;
  final String dateText;
  final String weekdayText;
  final String locationText;
  final String customText;
  final String brandText;

  factory WatermarkSnapshot.capture({
    required DateTime capturedAt,
    required String locationText,
    required String customText,
  }) {
    final DateTime localCaptureTime = capturedAt.toLocal();
    final String normalizedLocation = locationText.trim();
    final String normalizedCustomText = customText.trim();

    if (normalizedLocation.isEmpty) {
      throw ArgumentError.value(
        locationText,
        'locationText',
        'A non-empty location is required for a watermark.',
      );
    }
    if (normalizedLocation.characters.length > maximumLocationGraphemes) {
      throw ArgumentError.value(
        locationText,
        'locationText',
        'Location must contain at most $maximumLocationGraphemes graphemes.',
      );
    }
    if (normalizedCustomText.characters.length > maximumCustomGraphemes) {
      throw ArgumentError.value(
        customText,
        'customText',
        'Custom text must contain at most $maximumCustomGraphemes graphemes.',
      );
    }

    final int weekdayIndex = localCaptureTime.weekday - 1;
    return WatermarkSnapshot._(
      capturedAt: _formatLocalIso8601(localCaptureTime),
      timeText:
          '${_twoDigits(localCaptureTime.hour)}:${_twoDigits(localCaptureTime.minute)}',
      dateText:
          '${localCaptureTime.year.toString().padLeft(4, '0')}.${_twoDigits(localCaptureTime.month)}.${_twoDigits(localCaptureTime.day)}',
      weekdayText: _weekdays[weekdayIndex],
      locationText: normalizedLocation,
      customText: normalizedCustomText,
      brandText: brand,
    );
  }

  Map<String, String> toMap() => <String, String>{
    'capturedAt': capturedAt,
    'timeText': timeText,
    'dateText': dateText,
    'weekdayText': weekdayText,
    'locationText': locationText,
    'customText': customText,
    'brandText': brandText,
  };

  static String _twoDigits(int value) => value.toString().padLeft(2, '0');

  static String _formatLocalIso8601(DateTime localDateTime) {
    final Duration offset = localDateTime.timeZoneOffset;
    final int offsetMinutes = offset.inMinutes.abs();
    final String sign = offset.isNegative ? '-' : '+';
    final String offsetHours = _twoDigits(offsetMinutes ~/ 60);
    final String offsetRemainder = _twoDigits(offsetMinutes % 60);
    return '${localDateTime.toIso8601String()}$sign$offsetHours:$offsetRemainder';
  }
}
