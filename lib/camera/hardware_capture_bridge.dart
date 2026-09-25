import 'package:flutter/services.dart';

/// Connects iOS capture events from volume and dedicated camera buttons.
class HardwareCaptureBridge {
  static const MethodChannel _channel = MethodChannel(
    'proofshot/hardware_capture',
  );

  HardwareCaptureBridge(Future<void> Function() onCapture) {
    _channel.setMethodCallHandler((MethodCall call) async {
      if (call.method != 'capture') {
        throw PlatformException(
          code: 'unknown_hardware_capture_event',
          message: 'Unexpected hardware capture event: ${call.method}',
        );
      }
      await onCapture();
    });
  }

  Future<bool> setEnabled(bool enabled) async {
    final bool? supported = await _channel.invokeMethod<bool>(
      'setEnabled',
      enabled,
    );
    if (supported == null) {
      throw const FormatException(
        'The hardware capture bridge returned no status.',
      );
    }
    return supported;
  }

  void dispose() {
    _channel.setMethodCallHandler(null);
  }
}
