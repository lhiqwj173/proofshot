import 'package:flutter/services.dart';

import '../diagnostics/runtime_logs.dart';

class CaptureHaptics {
  static const MethodChannel _channel = MethodChannel(
    'proofshot/capture_haptics',
  );

  const CaptureHaptics();

  Future<void> captureImpact() async {
    final Map<String, Object?>? details = await _channel
        .invokeMapMethod<String, Object?>('captureImpact');
    final Object? route = details?['route'];
    if (route is! String) {
      throw StateError('The haptics bridge returned no feedback route.');
    }
    await RuntimeLogs.instance.event(
      'haptics.native',
      context: <String, Object?>{
        'route': route,
        'sound_id': details?['sound_id'],
        'audio_category': details?['audio_category'],
      },
    );
  }
}
