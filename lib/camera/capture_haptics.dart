import 'package:flutter/services.dart';

class CaptureHaptics {
  static const MethodChannel _channel = MethodChannel(
    'proofshot/capture_haptics',
  );

  const CaptureHaptics();

  Future<void> lightImpact() async {
    await _channel.invokeMethod<void>('lightImpact');
  }
}
