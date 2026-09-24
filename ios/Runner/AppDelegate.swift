import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var watermarkBridge: WatermarkBridge?
  private var watermarkGalleryBridge: WatermarkGalleryBridge?

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
  }
}
