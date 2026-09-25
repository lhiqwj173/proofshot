import 'package:flutter/services.dart';

import '../watermark/watermark_snapshot.dart';

class RecentCaptureThumbnail {
  const RecentCaptureThumbnail({required this.path, required this.kind});

  final String path;
  final String kind;
}

class WatermarkBridge {
  static const MethodChannel _channel = MethodChannel('proofshot/watermark');

  Future<String> renderPhoto({
    required String sourcePath,
    required WatermarkSnapshot snapshot,
  }) async {
    return _render(
      method: 'renderPhoto',
      sourcePath: sourcePath,
      snapshot: snapshot,
    );
  }

  Future<String> renderVideo({
    required String sourcePath,
    required WatermarkSnapshot snapshot,
  }) {
    return _render(
      method: 'renderVideo',
      sourcePath: sourcePath,
      snapshot: snapshot,
    );
  }

  Future<RecentCaptureThumbnail?> recentThumbnail() async {
    final Map<String, Object?>? response = await _channel
        .invokeMapMethod<String, Object?>('recentThumbnail');
    if (response == null) {
      return null;
    }
    return _parseRecentThumbnail(response);
  }

  Future<RecentCaptureThumbnail> updateRecentThumbnail({
    required String sourcePath,
    required String kind,
  }) async {
    _validateSourcePath(sourcePath);
    if (kind != 'photo' && kind != 'video') {
      throw ArgumentError.value(
        kind,
        'kind',
        'Media kind must be photo or video.',
      );
    }
    final Map<String, Object?>? response = await _channel
        .invokeMapMethod<String, Object?>(
          'updateRecentThumbnail',
          <String, Object?>{'sourcePath': sourcePath, 'kind': kind},
        );
    if (response == null) {
      throw const FormatException(
        'The thumbnail renderer returned no thumbnail details.',
      );
    }
    final RecentCaptureThumbnail thumbnail = _parseRecentThumbnail(response);
    if (thumbnail.kind != kind) {
      throw const FormatException(
        'The thumbnail renderer returned the wrong media kind.',
      );
    }
    return thumbnail;
  }

  Future<String> _render({
    required String method,
    required String sourcePath,
    required WatermarkSnapshot snapshot,
  }) async {
    _validateSourcePath(sourcePath);
    final Map<String, Object?>? response = await _channel
        .invokeMapMethod<String, Object?>(method, <String, Object?>{
          'sourcePath': sourcePath,
          'snapshot': snapshot.toMap(),
        });
    if (response == null ||
        response.length != 1 ||
        !response.containsKey('renderedPath')) {
      throw const FormatException(
        'The native media renderer returned an invalid response map.',
      );
    }
    final Object? renderedPath = response['renderedPath'];
    if (renderedPath is! String ||
        !renderedPath.startsWith('/') ||
        !(renderedPath.endsWith('.jpg') || renderedPath.endsWith('.mp4'))) {
      throw const FormatException(
        'The native media renderer returned an invalid renderedPath.',
      );
    }
    if (method == 'renderPhoto' && !renderedPath.endsWith('.jpg')) {
      throw const FormatException(
        'The native photo renderer must return a JPEG file.',
      );
    }
    if (method == 'renderVideo' && !renderedPath.endsWith('.mp4')) {
      throw const FormatException(
        'The native video renderer must return an MP4 file.',
      );
    }
    return renderedPath;
  }

  RecentCaptureThumbnail _parseRecentThumbnail(Map<String, Object?> value) {
    if (value.length != 2 ||
        value['thumbnailPath'] is! String ||
        value['kind'] is! String) {
      throw const FormatException(
        'The native thumbnail renderer returned an invalid response map.',
      );
    }
    final String path = value['thumbnailPath']! as String;
    final String kind = value['kind']! as String;
    if (!path.startsWith('/') || !path.endsWith('.jpg')) {
      throw const FormatException(
        'The native thumbnail renderer returned an invalid thumbnail path.',
      );
    }
    if (kind != 'photo' && kind != 'video') {
      throw const FormatException(
        'The native thumbnail renderer returned an invalid media kind.',
      );
    }
    return RecentCaptureThumbnail(path: path, kind: kind);
  }

  void _validateSourcePath(String sourcePath) {
    if (sourcePath.isEmpty ||
        sourcePath.trim() != sourcePath ||
        !sourcePath.startsWith('/')) {
      throw ArgumentError.value(
        sourcePath,
        'sourcePath',
        'The source path must be an absolute iOS file path.',
      );
    }
  }
}
