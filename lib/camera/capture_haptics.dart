import 'package:flutter/services.dart';

import '../diagnostics/runtime_logs.dart';

class CaptureHaptics {
  static const MethodChannel _channel = MethodChannel(
    'proofshot/capture_haptics',
  );

  const CaptureHaptics();

  Future<void> captureImpact() async {
    final details = await _channel.invokeMapMethod<String, String>(
      'captureImpact',
    );
    if (details == null || details['audio_category'] == null) {
      throw StateError('The haptics bridge returned no audio session state.');
    }
    await RuntimeLogs.instance.event(
      'haptics.native',
      context: <String, Object?>{'audio_category': details['audio_category']},
    );
  }
}
