import AVKit
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var watermarkBridge: WatermarkBridge?
  private var watermarkGalleryBridge: WatermarkGalleryBridge?
  private var hardwareCaptureBridge: HardwareCaptureBridge?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    watermarkBridge = WatermarkBridge(
      messenger: engineBridge.applicationRegistrar.messenger()
    )
    watermarkGalleryBridge = WatermarkGalleryBridge(
      messenger: engineBridge.applicationRegistrar.messenger()
    )
    hardwareCaptureBridge = HardwareCaptureBridge(
      messenger: engineBridge.applicationRegistrar.messenger()
    )
  }
}

private final class HardwareCaptureBridge {
  private let channel: FlutterMethodChannel
  private weak var host: FlutterViewController?
  private var interaction: AnyObject?

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "proofshot/hardware_capture", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(FlutterError(code: "hardware_bridge_unavailable", message: "硬件快门已关闭。", details: nil))
        return
      }
      guard call.method == "setEnabled", let enabled = call.arguments as? Bool else {
        result(FlutterError(code: "invalid_hardware_capture_request", message: "硬件快门请求无效。", details: nil))
        return
      }
      self.setEnabled(enabled, result: result)
    }
  }

  private func setEnabled(_ enabled: Bool, result: FlutterResult) {
    guard #available(iOS 17.2, *) else {
      result(false)
      return
    }
    if !enabled {
      (interaction as? AVCaptureEventInteraction)?.isEnabled = false
      result(true)
      return
    }
    guard let scene = UIApplication.shared.connectedScenes
      .compactMap({ $0 as? UIWindowScene })
      .first(where: { $0.activationState == .foregroundActive }),
      let root = scene.windows.first(where: \.isKeyWindow)?.rootViewController as? FlutterViewController
    else {
      result(FlutterError(code: "hardware_capture_host_missing", message: "无法绑定硬件快门。", details: nil))
      return
    }
    if host !== root {
      if let oldHost = host, let oldInteraction = interaction as? AVCaptureEventInteraction {
        oldHost.view.removeInteraction(oldInteraction)
      }
      host = root
      interaction = nil
    }
    if interaction == nil {
      let captureInteraction = AVCaptureEventInteraction { [weak self] event in
        guard event.phase == .ended,
              let self,
              let host = self.host,
              host.view.window != nil,
              host.presentedViewController == nil,
              UIApplication.shared.applicationState == .active
        else { return }
        self.channel.invokeMethod("capture", arguments: nil)
      }
      captureInteraction.isEnabled = false
      root.view.addInteraction(captureInteraction)
      interaction = captureInteraction
    }
    if #available(iOS 26.0, *) {
      AVCaptureEventInteraction.defaultCaptureSoundDisabled = true
    }
    (interaction as? AVCaptureEventInteraction)?.isEnabled = enabled
    result(true)
  }
}
