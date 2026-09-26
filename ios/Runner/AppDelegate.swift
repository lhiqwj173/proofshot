import AVKit
import Flutter
import MapKit
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var watermarkBridge: WatermarkBridge?
  private var watermarkGalleryBridge: WatermarkGalleryBridge?
  private var hardwareCaptureBridge: HardwareCaptureBridge?
  private var locationPickerBridge: WatermarkLocationPickerBridge?

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
    locationPickerBridge = WatermarkLocationPickerBridge(
      messenger: engineBridge.applicationRegistrar.messenger()
    )
  }
}

private final class WatermarkLocationPickerBridge {
  private let channel: FlutterMethodChannel

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "proofshot/location_picker", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      guard call.method == "openPicker", call.arguments == nil else {
        result(FlutterError(code: "invalid_location_picker_request", message: "地图选点请求无效。", details: nil))
        return
      }
      DispatchQueue.main.async {
        guard let presenter = Self.topViewController() else {
          result(FlutterError(code: "location_picker_host_missing", message: "无法打开地图选点。", details: nil))
          return
        }
        let picker = WatermarkLocationPickerViewController { selected in
          result(selected)
        }
        let navigation = UINavigationController(rootViewController: picker)
        navigation.modalPresentationStyle = .fullScreen
        navigation.overrideUserInterfaceStyle = .light
        presenter.present(navigation, animated: true)
      }
    }
  }

  private static func topViewController() -> UIViewController? {
    guard let scene = UIApplication.shared.connectedScenes
      .compactMap({ $0 as? UIWindowScene })
      .first(where: { $0.activationState == .foregroundActive }),
      let root = scene.windows.first(where: \.isKeyWindow)?.rootViewController
    else {
      return nil
    }
    var top = root
    while let presented = top.presentedViewController {
      top = presented
    }
    return top
  }
}

private final class WatermarkLocationPickerViewController: UIViewController, MKMapViewDelegate {
  private let onSelection: ([String: Double]?) -> Void
  private let mapView = MKMapView()
  private let statusLabel = UILabel()
  private let confirmButton = UIButton(type: .system)
  private var hasLocatedUser = false
  private var didFinish = false

  init(onSelection: @escaping ([String: Double]?) -> Void) {
    self.onSelection = onSelection
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) {
    fatalError("WatermarkLocationPickerViewController does not support storyboard initialization.")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = "地图选点"
    view.backgroundColor = .systemBackground
    navigationItem.leftBarButtonItem = UIBarButtonItem(
      barButtonSystemItem: .cancel,
      target: self,
      action: #selector(cancel)
    )
    navigationItem.rightBarButtonItem = UIBarButtonItem(
      image: UIImage(systemName: "location.fill"),
      style: .plain,
      target: self,
      action: #selector(centerOnUser)
    )

    mapView.delegate = self
    mapView.showsUserLocation = true
    mapView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(mapView)

    let pin = UIImageView(image: UIImage(systemName: "mappin.circle.fill"))
    pin.tintColor = .systemRed
    pin.contentMode = .scaleAspectFit
    pin.translatesAutoresizingMaskIntoConstraints = false
    pin.isUserInteractionEnabled = false
    view.addSubview(pin)

    let panel = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
    panel.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(panel)
    statusLabel.text = "正在获取当前位置…"
    statusLabel.textAlignment = .center
    statusLabel.numberOfLines = 2
    statusLabel.font = .systemFont(ofSize: 14)
    statusLabel.translatesAutoresizingMaskIntoConstraints = false
    panel.contentView.addSubview(statusLabel)
    confirmButton.setTitle("下一步：核对水印地址", for: .normal)
    confirmButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
    confirmButton.backgroundColor = .systemBlue
    confirmButton.tintColor = .white
    confirmButton.layer.cornerRadius = 12
    confirmButton.isEnabled = false
    confirmButton.alpha = 0.45
    confirmButton.addTarget(self, action: #selector(confirm), for: .touchUpInside)
    confirmButton.translatesAutoresizingMaskIntoConstraints = false
    panel.contentView.addSubview(confirmButton)

    NSLayoutConstraint.activate([
      mapView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      mapView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      mapView.topAnchor.constraint(equalTo: view.topAnchor),
      mapView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      pin.centerXAnchor.constraint(equalTo: mapView.centerXAnchor),
      pin.centerYAnchor.constraint(equalTo: mapView.centerYAnchor),
      pin.widthAnchor.constraint(equalToConstant: 44),
      pin.heightAnchor.constraint(equalToConstant: 44),
      panel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      panel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      panel.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      statusLabel.leadingAnchor.constraint(equalTo: panel.contentView.leadingAnchor, constant: 20),
      statusLabel.trailingAnchor.constraint(equalTo: panel.contentView.trailingAnchor, constant: -20),
      statusLabel.topAnchor.constraint(equalTo: panel.contentView.topAnchor, constant: 16),
      confirmButton.leadingAnchor.constraint(equalTo: panel.contentView.leadingAnchor, constant: 20),
      confirmButton.trailingAnchor.constraint(equalTo: panel.contentView.trailingAnchor, constant: -20),
      confirmButton.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 12),
      confirmButton.heightAnchor.constraint(equalToConstant: 50),
      confirmButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
    ])
  }

  func mapView(_ mapView: MKMapView, didUpdate userLocation: MKUserLocation) {
    guard let location = userLocation.location,
          location.horizontalAccuracy >= 0
    else { return }
    if !hasLocatedUser {
      hasLocatedUser = true
      centerOnUser()
      confirmButton.isEnabled = true
      confirmButton.alpha = 1
    }
    statusLabel.text = "蓝点是当前位置；拖动地图，把红色图钉放到要写入水印的位置。"
  }

  func mapView(_ mapView: MKMapView, didFailToLocateUserWithError error: Error) {
    statusLabel.text = "当前位置获取失败：\(error.localizedDescription)"
  }

  @objc private func centerOnUser() {
    guard let location = mapView.userLocation.location else {
      statusLabel.text = "仍在获取当前位置，请稍后重试。"
      return
    }
    let region = MKCoordinateRegion(
      center: location.coordinate,
      latitudinalMeters: 350,
      longitudinalMeters: 350
    )
    mapView.setRegion(region, animated: true)
  }

  @objc private func confirm() {
    guard hasLocatedUser else {
      statusLabel.text = "请等待当前位置出现后再选点。"
      return
    }
    let coordinate = mapView.centerCoordinate
    guard CLLocationCoordinate2DIsValid(coordinate) else {
      statusLabel.text = "选点坐标无效，请重新选择。"
      return
    }
    finish(["latitude": coordinate.latitude, "longitude": coordinate.longitude])
  }

  @objc private func cancel() {
    finish(nil)
  }

  private func finish(_ selected: [String: Double]?) {
    guard !didFinish else { return }
    didFinish = true
    let callback = onSelection
    dismiss(animated: true) {
      callback(selected)
    }
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
