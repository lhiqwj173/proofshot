import 'package:flutter/services.dart';

import '../watermark/watermark_snapshot.dart';

class PendingWatermarkMedia {
  const PendingWatermarkMedia({
    required this.id,
    required this.kind,
    required this.capturedAt,
    required this.snapshot,
    required this.sourcePath,
    required this.status,
    required this.renderedPath,
    required this.localIdentifier,
    required this.errorMessage,
  });

  final String id;
  final String kind;
  final String capturedAt;
  final WatermarkSnapshot snapshot;
  final String sourcePath;
  final String status;
  final String? renderedPath;
  final String? localIdentifier;
  final String? errorMessage;
}

class WatermarkGalleryBridge {
  static const MethodChannel _channel = MethodChannel('proofshot/gallery');

  Future<String> prepareMedia({
    required String sourcePath,
    required String kind,
    required WatermarkSnapshot snapshot,
  }) async {
    _validateTemporaryPath(sourcePath, 'sourcePath');
    if (kind != 'photo' && kind != 'video') {
      throw ArgumentError.value(
        kind,
        'kind',
        'Media kind must be photo or video.',
      );
    }
    final Map<String, Object?>? response = await _channel
        .invokeMapMethod<String, Object?>('prepareMedia', <String, Object?>{
          'sourcePath': sourcePath,
          'kind': kind,
          'snapshot': snapshot.toMap(),
        });
    if (response == null ||
        response.length != 1 ||
        response['taskId'] is! String ||
        (response['taskId']! as String).isEmpty) {
      throw const FormatException(
        'The native media journal returned an invalid taskId.',
      );
    }
    return response['taskId']! as String;
  }

  Future<void> markRendered({
    required String taskId,
    required String renderedPath,
  }) async {
    if (taskId.isEmpty) {
      throw ArgumentError.value(
        taskId,
        'taskId',
        'A media task ID is required.',
      );
    }
    _validateTemporaryPath(renderedPath, 'renderedPath');
    await _channel.invokeMethod<void>('markRendered', <String, Object?>{
      'taskId': taskId,
      'renderedPath': renderedPath,
    });
  }

  Future<String> saveToPhotos({required String taskId}) async {
    if (taskId.isEmpty) {
      throw ArgumentError.value(
        taskId,
        'taskId',
        'A media task ID is required.',
      );
    }
    final Map<String, Object?>? response = await _channel
        .invokeMapMethod<String, Object?>('saveToPhotos', <String, Object?>{
          'taskId': taskId,
        });
    if (response == null ||
        response.length != 1 ||
        response['localIdentifier'] is! String ||
        (response['localIdentifier']! as String).isEmpty) {
      throw const FormatException(
        'The native photo saver returned an invalid localIdentifier.',
      );
    }
    return response['localIdentifier']! as String;
  }

  Future<List<PendingWatermarkMedia>> pendingMedia() async {
    final Map<String, Object?>? response = await _channel
        .invokeMapMethod<String, Object?>('pendingMedia');
    if (response == null ||
        response.length != 1 ||
        response['items'] is! List<Object?>) {
      throw const FormatException(
        'The native media journal returned an invalid item list.',
      );
    }
    final List<Object?> rawItems = response['items']! as List<Object?>;
    return rawItems.map(_parsePendingMedia).toList(growable: false);
  }

  Future<void> openGallery() async {
    await _channel.invokeMethod<void>('openGallery');
  }

  Future<void> openSystemSettings() async {
    await _channel.invokeMethod<void>('openSettings');
  }

  PendingWatermarkMedia _parsePendingMedia(Object? value) {
    if (value is! Map<Object?, Object?>) {
      throw const FormatException('A pending media item must be a map.');
    }
    final Map<String, Object?> fields = <String, Object?>{};
    for (final MapEntry<Object?, Object?> entry in value.entries) {
      if (entry.key is! String) {
        throw const FormatException('Pending media keys must be strings.');
      }
      fields[entry.key! as String] = entry.value;
    }
    const Set<String> expectedKeys = <String>{
      'id',
      'kind',
      'capturedAt',
      'snapshot',
      'sourcePath',
      'status',
      'renderedPath',
      'localIdentifier',
      'errorMessage',
    };
    if (fields.keys.toSet().difference(expectedKeys).isNotEmpty ||
        expectedKeys.difference(fields.keys.toSet()).isNotEmpty) {
      throw const FormatException(
        'A pending media item has an invalid schema.',
      );
    }
    final Object? rawSnapshot = fields['snapshot'];
    if (rawSnapshot is! Map<Object?, Object?>) {
      throw const FormatException('A pending snapshot must be a map.');
    }
    final Map<String, Object?> snapshotMap = <String, Object?>{};
    for (final MapEntry<Object?, Object?> entry in rawSnapshot.entries) {
      if (entry.key is! String) {
        throw const FormatException('Snapshot keys must be strings.');
      }
      snapshotMap[entry.key! as String] = entry.value;
    }

    String requiredString(String key) {
      final Object? result = fields[key];
      if (result is! String || result.isEmpty) {
        throw FormatException(
          'Pending media field $key must be a non-empty string.',
        );
      }
      return result;
    }

    String? optionalString(String key) {
      final Object? result = fields[key];
      if (result == null) {
        return null;
      }
      if (result is! String) {
        throw FormatException(
          'Pending media field $key must be a string or null.',
        );
      }
      return result;
    }

    final String kind = requiredString('kind');
    if (kind != 'photo' && kind != 'video') {
      throw const FormatException('Pending media kind must be photo or video.');
    }
    final String sourcePath = requiredString('sourcePath');
    _validateTemporaryPath(sourcePath, 'sourcePath');
    final String? renderedPath = optionalString('renderedPath');
    if (renderedPath != null) {
      _validateTemporaryPath(renderedPath, 'renderedPath');
    }
    final String status = requiredString('status');
    if (!const <String>{
      'prepared',
      'rendered',
      'retryable',
      'saving',
      'savedNeedsIndex',
    }.contains(status)) {
      throw const FormatException(
        'Pending media has an unknown processing status.',
      );
    }
    final WatermarkSnapshot snapshot = WatermarkSnapshot.fromMap(snapshotMap);
    final String capturedAt = requiredString('capturedAt');
    if (snapshot.capturedAt != capturedAt) {
      throw const FormatException('Pending media timestamps do not match.');
    }
    if ((status == 'rendered' || status == 'retryable' || status == 'saving') &&
        renderedPath == null) {
      throw const FormatException(
        'A rendered pending operation has no renderedPath.',
      );
    }
    final String? localIdentifier = optionalString('localIdentifier');
    if ((status == 'savedNeedsIndex') != (localIdentifier != null)) {
      throw const FormatException(
        'Only a saved pending operation may contain a localIdentifier.',
      );
    }
    return PendingWatermarkMedia(
      id: requiredString('id'),
      kind: kind,
      capturedAt: capturedAt,
      snapshot: snapshot,
      sourcePath: sourcePath,
      status: status,
      renderedPath: renderedPath,
      localIdentifier: localIdentifier,
      errorMessage: optionalString('errorMessage'),
    );
  }

  void _validateTemporaryPath(String path, String name) {
    if (path.isEmpty || path.trim() != path || !path.startsWith('/')) {
      throw ArgumentError.value(
        path,
        name,
        'The media path must be an absolute iOS file path.',
      );
    }
  }
}
