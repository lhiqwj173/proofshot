import AVFoundation
import CoreImage
import Metal

/// 应用在启动录像前准备一次，采集队列在创建 writer 时取得独占实例。
public final class ProofshotRealtimeWatermark {
  public static let metadataKey = "com.proofshot.watermark.v1"
  public static let filePrefix = "PSRT_"
  public static let size = CGSize(width: 1080, height: 1440)
  private static let lock = NSLock()
  private static var prepared: ProofshotRealtimeWatermark?
  // CIContext 线程安全，跨录像复用 Metal 管线及编译缓存。
  private static let gpuContext: Result<CIContext, Error> = {
    guard let device = MTLCreateSystemDefaultDevice() else {
      return .failure(failure("设备不支持 Metal 实时水印。"))
    }
    return .success(CIContext(mtlDevice: device, options: [.cacheIntermediates: false]))
  }()

  public static func prepare(overlay: CGImage, token: String) throws {
    let pipeline = try ProofshotRealtimeWatermark(overlay: overlay, token: token)
    lock.lock()
    defer { lock.unlock() }
    guard prepared == nil else { throw failure("上一次录像水印尚未被采集队列接收。") }
    prepared = pipeline
  }

  public static func cancelPreparation() {
    lock.lock()
    defer { lock.unlock() }
    prepared = nil
  }

  static func takePrepared() -> ProofshotRealtimeWatermark? {
    lock.lock()
    defer { lock.unlock() }
    let pipeline = prepared
    prepared = nil
    return pipeline
  }

  private let context: CIContext
  private let overlay: CIImage
  private let pool: CVPixelBufferPool
  private let colorSpace = CGColorSpaceCreateDeviceRGB()
  private var sourceSize: CGSize?
  private var crop = CGRect.zero
  private var transform = CGAffineTransform.identity
  let token: String

  private init(overlay: CGImage, token: String) throws {
    guard overlay.width == 1080, overlay.height == 1440, !token.isEmpty else {
      throw Self.failure("实时水印尺寸或标识无效。")
    }
    self.token = token
    self.overlay = CIImage(cgImage: overlay)
    context = try Self.gpuContext.get()
    var createdPool: CVPixelBufferPool?
    let status = CVPixelBufferPoolCreate(kCFAllocatorDefault,
      [kCVPixelBufferPoolMinimumBufferCountKey as String: 3] as CFDictionary,
      [kCVPixelBufferWidthKey as String: 1080, kCVPixelBufferHeightKey as String: 1440,
       kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
       kCVPixelBufferMetalCompatibilityKey as String: true,
       kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &createdPool)
    guard status == kCVReturnSuccess, let createdPool else {
      throw Self.failure("无法创建录像像素缓冲池：\(status)。")
    }
    pool = createdPool
  }

  public static func receiptMetadata(token: String) -> AVMetadataItem {
    precondition(!token.isEmpty, "实时水印标识不能为空。")
    let metadata = AVMutableMetadataItem()
    // MP4 writer 不保证保留任意 QuickTime mdta 自定义键，使用可映射的标准描述字段。
    metadata.identifier = .commonIdentifierDescription
    metadata.value = token as NSString
    metadata.dataType = kCMMetadataBaseDataType_UTF8 as String
    return metadata
  }

  func configure(_ writer: AVAssetWriter) {
    writer.metadata = [Self.receiptMetadata(token: token)]
    writer.shouldOptimizeForNetworkUse = false
  }

  /// 仅采集队列调用；不修改相机预览持有的原始 pixel buffer。
  func render(_ source: CVPixelBuffer) throws -> CVPixelBuffer {
    let size = CGSize(width: CVPixelBufferGetWidth(source), height: CVPixelBufferGetHeight(source))
    if sourceSize == nil {
      // AVCaptureConnection 已旋转到锁定的竖屏方向，不再旋转或镜像一次。
      let unit = floor(min(size.width / 6, size.height / 8))
      let width = unit * 6
      let height = unit * 8
      guard width >= 1080, height >= 1440 else {
        throw Self.failure("录像原始帧裁切后不足 1080×1440：\(size)。")
      }
      crop = CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2,
                    width: width, height: height)
      let scale = Self.size.width / width
      transform = CGAffineTransform(translationX: -crop.minX, y: -crop.minY)
        .concatenating(CGAffineTransform(scaleX: scale, y: scale))
      sourceSize = size
    }
    guard sourceSize == size else {
      throw Self.failure("录像过程中采集帧尺寸发生变化。")
    }
    var target: CVPixelBuffer?
    let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool,
      [kCVPixelBufferPoolAllocationThresholdKey as String: 6] as CFDictionary, &target)
    guard status == kCVReturnSuccess, let target else {
      throw Self.failure("录像编码缓冲池耗尽：\(status)。")
    }
    let image = CIImage(cvPixelBuffer: source).cropped(to: crop).transformed(by: transform)
    context.render(overlay.composited(over: image), to: target,
                   bounds: CGRect(origin: .zero, size: Self.size), colorSpace: colorSpace)
    return target
  }

  static func failure(_ message: String) -> NSError {
    NSError(domain: "proofshot.realtime_watermark", code: 1,
            userInfo: [NSLocalizedDescriptionKey: message])
  }
}
