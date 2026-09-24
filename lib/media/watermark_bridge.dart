import 'package:flutter/services.dart';

import '../watermark/watermark_snapshot.dart';

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
