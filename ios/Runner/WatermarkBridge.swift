import AVFoundation
import AudioToolbox
import CoreGraphics
import CoreMedia
import Flutter
import Foundation
import ImageIO
import UIKit

private enum WatermarkBridgeError: Error, LocalizedError {
  case invalidArguments(String)
  case invalidSnapshot(String)
  case sourceOutsideTemporaryDirectory
  case invalidSourceFile(String)
  case invalidImage
  case invalidVideoSource(String)
  case missingAudioTrack
  case unsupportedVideoExport
  case exportFailed(String)
  case invalidRenderedVideo(String)
  case resolutionTooLow(width: Int, height: Int)
  case watermarkLayoutDoesNotFit(String)
  case renderFailed
  case thumbnailFailed(String)

  var code: String {
    switch self {
    case .invalidArguments:
      return "invalid_arguments"
    case .invalidSnapshot:
      return "invalid_snapshot"
    case .sourceOutsideTemporaryDirectory:
      return "source_outside_temporary_directory"
    case .invalidSourceFile:
      return "invalid_source_file"
    case .invalidImage:
      return "invalid_image"
    case .invalidVideoSource:
      return "invalid_video_source"
    case .missingAudioTrack:
      return "missing_audio_track"
    case .unsupportedVideoExport:
      return "unsupported_video_export"
    case .exportFailed:
      return "video_export_failed"
    case .invalidRenderedVideo:
      return "invalid_rendered_video"
    case .resolutionTooLow:
      return "resolution_too_low"
    case .watermarkLayoutDoesNotFit:
      return "watermark_layout_does_not_fit"
    case .renderFailed:
      return "render_failed"
    case .thumbnailFailed:
      return "thumbnail_failed"
    }
  }

  var errorDescription: String? {
    switch self {
    case let .invalidArguments(message), let .invalidSnapshot(message),
         let .invalidSourceFile(message), let .invalidVideoSource(message),
         let .exportFailed(message), let .invalidRenderedVideo(message):
      return message
    case .sourceOutsideTemporaryDirectory:
      return "The source file must be inside the app temporary directory."
    case .invalidImage:
      return "The source file is not a decodable image."
    case .missingAudioTrack:
      return "The video has no usable audio track, so an audio video cannot be produced."
    case .unsupportedVideoExport:
      return "The device cannot export this video as a 1080p H.264/AAC MP4."
    case let .resolutionTooLow(width, height):
      return "The oriented media resolution is below 1080 pixels on its short side: \(width)x\(height)."
    case let .watermarkLayoutDoesNotFit(message):
      return message
    case .renderFailed:
      return "The watermarked JPEG could not be rendered."
    case let .thumbnailFailed(message):
      return message
    }
  }
}

private struct WatermarkSnapshotData {
  let capturedAt: String
  let timeText: String
  let dateText: String
  let weekdayText: String
  let locationText: String
  let customText: String
  let brandText: String

  init(value: Any?) throws {
    guard let fields = value as? [String: Any] else {
      throw WatermarkBridgeError.invalidSnapshot("Snapshot must be a string-keyed map.")
    }

    let expectedKeys: Set<String> = [
      "capturedAt", "timeText", "dateText", "weekdayText",
      "locationText", "customText", "brandText",
    ]
    guard Set(fields.keys) == expectedKeys else {
      throw WatermarkBridgeError.invalidSnapshot("Snapshot fields do not match the required schema.")
    }

    func requiredString(_ key: String) throws -> String {
      guard let value = fields[key] as? String else {
        throw WatermarkBridgeError.invalidSnapshot("Snapshot field \(key) must be a string.")
      }
      return value
    }

    capturedAt = try requiredString("capturedAt")
    timeText = try requiredString("timeText")
    dateText = try requiredString("dateText")
    weekdayText = try requiredString("weekdayText")
    locationText = try requiredString("locationText")
    customText = try requiredString("customText")
    brandText = try requiredString("brandText")

    let timestampFormatter = ISO8601DateFormatter()
    timestampFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    guard timestampFormatter.date(from: capturedAt) != nil,
          capturedAt.range(of: #"[+-]\d{2}:\d{2}$"#, options: .regularExpression) != nil
    else {
      throw WatermarkBridgeError.invalidSnapshot(
        "capturedAt must be an ISO 8601 timestamp with a numeric UTC offset."
      )
    }
    guard timeText.range(of: #"^\d{2}:\d{2}$"#, options: .regularExpression) != nil else {
      throw WatermarkBridgeError.invalidSnapshot("timeText must use HH:mm format.")
    }
    let dateParts = dateText.split(separator: ".")
    guard dateParts.count == 3,
          dateParts[0].count == 4,
          dateParts[1].count == 2,
          dateParts[2].count == 2,
          dateParts.allSatisfy({ $0.allSatisfy(\.isNumber) })
    else {
      throw WatermarkBridgeError.invalidSnapshot("dateText must use yyyy.MM.dd format.")
    }
    guard ["星期一", "星期二", "星期三", "星期四", "星期五", "星期六", "星期日"]
      .contains(weekdayText)
    else {
      throw WatermarkBridgeError.invalidSnapshot("weekdayText must be a Chinese weekday.")
    }
    guard !locationText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          locationText == locationText.trimmingCharacters(in: .whitespacesAndNewlines),
          locationText.count <= 40
    else {
      throw WatermarkBridgeError.invalidSnapshot("locationText must contain 1 to 40 graphemes.")
    }
    guard customText == customText.trimmingCharacters(in: .whitespacesAndNewlines),
          customText.count <= 30
    else {
      throw WatermarkBridgeError.invalidSnapshot("customText must contain at most 30 graphemes.")
    }
    guard brandText == "水印相机" else {
      throw WatermarkBridgeError.invalidSnapshot("brandText must be 水印相机.")
    }
  }
}

private struct PhotoRenderRequest {
  let sourceURL: URL
  let snapshot: WatermarkSnapshotData

  init(arguments: Any?) throws {
    guard let parameters = arguments as? [String: Any],
          Set(parameters.keys) == Set(["sourcePath", "snapshot"]),
          let sourcePath = parameters["sourcePath"] as? String,
          sourcePath.hasPrefix("/")
    else {
      throw WatermarkBridgeError.invalidArguments(
        "renderPhoto expects absolute sourcePath and snapshot fields."
      )
    }

    let sourceURL = URL(fileURLWithPath: sourcePath).standardizedFileURL
    guard sourceURL.isFileURL else {
      throw WatermarkBridgeError.invalidArguments("sourcePath must be a local file URL.")
    }
    self.sourceURL = sourceURL
    snapshot = try WatermarkSnapshotData(value: parameters["snapshot"])
  }
}

private struct VideoRenderRequest {
  let sourceURL: URL
  let snapshot: WatermarkSnapshotData

  init(arguments: Any?) throws {
    guard let parameters = arguments as? [String: Any],
          Set(parameters.keys) == Set(["sourcePath", "snapshot"]),
          let sourcePath = parameters["sourcePath"] as? String,
          sourcePath.hasPrefix("/")
    else {
      throw WatermarkBridgeError.invalidArguments(
        "renderVideo expects absolute sourcePath and snapshot fields."
      )
    }

    let sourceURL = URL(fileURLWithPath: sourcePath).standardizedFileURL
    guard sourceURL.isFileURL else {
      throw WatermarkBridgeError.invalidArguments("sourcePath must be a local file URL.")
    }
    self.sourceURL = sourceURL
    snapshot = try WatermarkSnapshotData(value: parameters["snapshot"])
  }
}

private struct RecentThumbnailRequest {
  let sourceURL: URL
  let kind: String

  init(arguments: Any?) throws {
    guard let parameters = arguments as? [String: Any],
          Set(parameters.keys) == Set(["sourcePath", "kind"]),
          let sourcePath = parameters["sourcePath"] as? String,
          sourcePath.hasPrefix("/"),
          let kind = parameters["kind"] as? String,
          ["photo", "video"].contains(kind)
    else {
      throw WatermarkBridgeError.invalidArguments(
        "updateRecentThumbnail expects an absolute sourcePath and a photo or video kind."
      )
    }
    sourceURL = URL(fileURLWithPath: sourcePath).standardizedFileURL
    self.kind = kind
  }
}

final class WatermarkBridge {
  private let channel: FlutterMethodChannel

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: "proofshot/watermark",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(
          FlutterError(
            code: "bridge_unavailable",
            message: "The watermark bridge is no longer available.",
            details: nil
          )
        )
        return
      }
      self.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "renderPhoto":
      handlePhotoRender(call.arguments, result: result)
    case "renderVideo":
      handleVideoRender(call.arguments, result: result)
    case "updateRecentThumbnail":
      handleRecentThumbnailUpdate(call.arguments, result: result)
    case "recentThumbnail":
      handleRecentThumbnailLookup(result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func handleRecentThumbnailUpdate(
    _ arguments: Any?,
    result: @escaping FlutterResult
  ) {
    let request: RecentThumbnailRequest
    do {
      request = try RecentThumbnailRequest(arguments: arguments)
    } catch {
      result(Self.flutterError(for: error))
      return
    }

    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let thumbnailURL = try Self.updateRecentThumbnail(request)
        DispatchQueue.main.async {
          result([
            "thumbnailPath": thumbnailURL.path,
            "kind": request.kind,
          ])
        }
      } catch {
        let flutterError = Self.flutterError(for: error)
        DispatchQueue.main.async {
          result(flutterError)
        }
      }
    }
  }

  private func handleRecentThumbnailLookup(result: @escaping FlutterResult) {
    do {
      guard let thumbnail = try Self.latestRecentThumbnail() else {
        result(nil)
        return
      }
      result([
        "thumbnailPath": thumbnail.url.path,
        "kind": thumbnail.kind,
      ])
    } catch {
      result(Self.flutterError(for: error))
    }
  }

  private static func updateRecentThumbnail(
    _ request: RecentThumbnailRequest
  ) throws -> URL {
    try validateTemporaryFile(request.sourceURL)

    let image: CGImage
    if request.kind == "photo" {
      let thumbnailOptions: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: 480,
        kCGImageSourceShouldCacheImmediately: true,
      ]
      guard let imageSource = CGImageSourceCreateWithURL(request.sourceURL as CFURL, nil),
            let thumbnail = CGImageSourceCreateThumbnailAtIndex(
              imageSource,
              0,
              thumbnailOptions as CFDictionary
            )
      else {
        throw WatermarkBridgeError.thumbnailFailed(
          "拍摄已完成，但无法读取照片缩略图。"
        )
      }
      image = thumbnail
    } else {
      let generator = AVAssetImageGenerator(asset: AVURLAsset(url: request.sourceURL))
      generator.appliesPreferredTrackTransform = true
      generator.maximumSize = CGSize(width: 480, height: 480)
      do {
        image = try generator.copyCGImage(at: .zero, actualTime: nil)
      } catch {
        throw WatermarkBridgeError.thumbnailFailed(
          "录像已完成，但无法读取视频缩略图：\(error.localizedDescription)"
        )
      }
    }

    guard let jpegData = UIImage(cgImage: image).jpegData(compressionQuality: 0.78),
          !jpegData.isEmpty
    else {
      throw WatermarkBridgeError.thumbnailFailed("拍摄已完成，但无法生成缩略图文件。")
    }

    guard let applicationSupport = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first else {
      throw WatermarkBridgeError.thumbnailFailed("无法访问应用缩略图目录。")
    }
    let directory = applicationSupport.appendingPathComponent("proofshot", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    let thumbnailURL = directory.appendingPathComponent(
      "recent-capture-\(request.kind).jpg"
    )
    try jpegData.write(to: thumbnailURL, options: .atomic)
    let values = try thumbnailURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard values.isRegularFile == true, (values.fileSize ?? 0) > 0 else {
      throw WatermarkBridgeError.thumbnailFailed("缩略图文件写入失败。")
    }
    return thumbnailURL
  }

  private static func latestRecentThumbnail() throws -> (url: URL, kind: String)? {
    guard let applicationSupport = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first else {
      throw WatermarkBridgeError.thumbnailFailed("无法访问应用缩略图目录。")
    }
    let directory = applicationSupport.appendingPathComponent("proofshot", isDirectory: true)
    let fileManager = FileManager.default
    var available: [(url: URL, kind: String, modifiedAt: Date)] = []
    for kind in ["photo", "video"] {
      let url = directory.appendingPathComponent("recent-capture-\(kind).jpg")
      guard fileManager.fileExists(atPath: url.path) else {
        continue
      }
      let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
      guard values.isRegularFile == true,
            (values.fileSize ?? 0) > 0,
            let modifiedAt = values.contentModificationDate
      else {
        throw WatermarkBridgeError.thumbnailFailed("最近拍摄的缩略图文件无效。")
      }
      available.append((url, kind, modifiedAt))
    }
    return available.max { $0.modifiedAt < $1.modifiedAt }.map {
      (url: $0.url, kind: $0.kind)
    }
  }

  private func handlePhotoRender(_ arguments: Any?, result: @escaping FlutterResult) {
    let request: PhotoRenderRequest
    do {
      request = try PhotoRenderRequest(arguments: arguments)
    } catch {
      result(Self.flutterError(for: error))
      return
    }

    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let renderedURL = try Self.renderPhoto(request)
        DispatchQueue.main.async {
          result(["renderedPath": renderedURL.path])
        }
      } catch {
        let flutterError = Self.flutterError(for: error)
        DispatchQueue.main.async {
          result(flutterError)
        }
      }
    }
  }

  private func handleVideoRender(_ arguments: Any?, result: @escaping FlutterResult) {
    let request: VideoRenderRequest
    do {
      request = try VideoRenderRequest(arguments: arguments)
    } catch {
      result(Self.flutterError(for: error))
      return
    }

    DispatchQueue.global(qos: .userInitiated).async {
      Self.renderVideo(request) { outcome in
        DispatchQueue.main.async {
          switch outcome {
          case let .success(renderedURL):
            result(["renderedPath": renderedURL.path])
          case let .failure(error):
            result(Self.flutterError(for: error))
          }
        }
      }
    }
  }

  private static func renderPhoto(_ request: PhotoRenderRequest) throws -> URL {
    try validateTemporaryFile(request.sourceURL)
    guard let imageSource = CGImageSourceCreateWithURL(request.sourceURL as CFURL, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
          let widthNumber = properties[kCGImagePropertyPixelWidth] as? NSNumber,
          let heightNumber = properties[kCGImagePropertyPixelHeight] as? NSNumber
    else {
      throw WatermarkBridgeError.invalidImage
    }

    let sourceWidth = widthNumber.intValue
    let sourceHeight = heightNumber.intValue
    guard sourceWidth > 0, sourceHeight > 0 else {
      throw WatermarkBridgeError.invalidImage
    }

    let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
    guard (1...8).contains(orientation) else {
      throw WatermarkBridgeError.invalidImage
    }
    let swapsDimensions = [5, 6, 7, 8].contains(orientation)
    let orientedWidth = swapsDimensions ? sourceHeight : sourceWidth
    let orientedHeight = swapsDimensions ? sourceWidth : sourceHeight
    guard min(orientedWidth, orientedHeight) >= 1080 else {
      throw WatermarkBridgeError.resolutionTooLow(width: orientedWidth, height: orientedHeight)
    }

    let maximumPixelSize = max(sourceWidth, sourceHeight)
    let imageOptions: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
      kCGImageSourceShouldCacheImmediately: true,
    ]
    guard let orientedImage = CGImageSourceCreateThumbnailAtIndex(
      imageSource,
      0,
      imageOptions as CFDictionary
    ), min(orientedImage.width, orientedImage.height) >= 1080 else {
      throw WatermarkBridgeError.invalidImage
    }

    let imageSize = CGSize(width: orientedImage.width, height: orientedImage.height)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    format.preferredRange = .standard
    let renderer = UIGraphicsImageRenderer(size: imageSize, format: format)
    var watermarkRenderError: Error?
    let renderedImage = renderer.image { context in
      UIImage(cgImage: orientedImage, scale: 1, orientation: .up)
        .draw(in: CGRect(origin: .zero, size: imageSize))
      do {
        try drawWatermark(request.snapshot, in: context.cgContext, size: imageSize)
      } catch {
        watermarkRenderError = error
      }
    }
    if let watermarkRenderError {
      throw watermarkRenderError
    }
    guard let jpegData = renderedImage.jpegData(compressionQuality: 0.95),
          !jpegData.isEmpty
    else {
      throw WatermarkBridgeError.renderFailed
    }

    let outputURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("proofshot-watermark-\(UUID().uuidString).jpg")
    try jpegData.write(to: outputURL, options: .atomic)
    let outputValues = try outputURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard outputValues.isRegularFile == true, (outputValues.fileSize ?? 0) > 0 else {
      throw WatermarkBridgeError.renderFailed
    }
    return outputURL
  }

  private static func renderVideo(
    _ request: VideoRenderRequest,
    completion: @escaping (Result<URL, Error>) -> Void
  ) {
    do {
      try validateTemporaryFile(request.sourceURL)
      let asset = AVURLAsset(
        url: request.sourceURL,
        options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
      )
      guard CMTIME_IS_NUMERIC(asset.duration), CMTimeGetSeconds(asset.duration) > 0 else {
        throw WatermarkBridgeError.invalidVideoSource("The source video has no valid duration.")
      }
      guard let videoTrack = asset.tracks(withMediaType: .video).first else {
        throw WatermarkBridgeError.invalidVideoSource("The source video has no video track.")
      }
      guard asset.tracks(withMediaType: .audio).first != nil else {
        throw WatermarkBridgeError.missingAudioTrack
      }

      let naturalSize = videoTrack.naturalSize
      guard naturalSize.width.isFinite, naturalSize.height.isFinite,
            naturalSize.width > 0, naturalSize.height > 0
      else {
        throw WatermarkBridgeError.invalidVideoSource("The source video dimensions are invalid.")
      }

      let sourceTransform = videoTrack.preferredTransform
      let orientedBounds = CGRect(origin: .zero, size: naturalSize)
        .applying(sourceTransform)
        .standardized
      guard orientedBounds.width.isFinite, orientedBounds.height.isFinite,
            orientedBounds.width > 0, orientedBounds.height > 0
      else {
        throw WatermarkBridgeError.invalidVideoSource("The source video orientation is invalid.")
      }
      let renderSize = CGSize(
        width: ceil(orientedBounds.width),
        height: ceil(orientedBounds.height)
      )
      guard min(renderSize.width, renderSize.height) >= 1080 else {
        throw WatermarkBridgeError.resolutionTooLow(
          width: Int(renderSize.width),
          height: Int(renderSize.height)
        )
      }

      var normalizedTransform = sourceTransform
      normalizedTransform.tx -= orientedBounds.minX
      normalizedTransform.ty -= orientedBounds.minY
      let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
      layerInstruction.setTransform(normalizedTransform, at: .zero)
      let instruction = AVMutableVideoCompositionInstruction()
      instruction.timeRange = CMTimeRange(start: .zero, duration: asset.duration)
      instruction.layerInstructions = [layerInstruction]

      let videoComposition = AVMutableVideoComposition()
      videoComposition.renderSize = renderSize
      videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
      videoComposition.renderScale = 1
      videoComposition.instructions = [instruction]

      let overlayImage = try makeWatermarkOverlay(request.snapshot, size: renderSize)
      let parentLayer = CALayer()
      parentLayer.frame = CGRect(origin: .zero, size: renderSize)
      parentLayer.isGeometryFlipped = true
      parentLayer.masksToBounds = true

      let videoLayer = CALayer()
      videoLayer.frame = parentLayer.bounds
      videoLayer.masksToBounds = true
      parentLayer.addSublayer(videoLayer)

      let watermarkLayer = CALayer()
      watermarkLayer.frame = parentLayer.bounds
      watermarkLayer.contents = overlayImage
      watermarkLayer.contentsGravity = .resize
      watermarkLayer.contentsScale = 1
      watermarkLayer.masksToBounds = true
      parentLayer.addSublayer(watermarkLayer)
      videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
        postProcessingAsVideoLayer: videoLayer,
        in: parentLayer
      )

      guard AVAssetExportSession.allExportPresets().contains(AVAssetExportPreset1920x1080),
            let exportSession = AVAssetExportSession(
              asset: asset,
              presetName: AVAssetExportPreset1920x1080
            )
      else {
        throw WatermarkBridgeError.unsupportedVideoExport
      }
      let outputURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("proofshot-watermark-\(UUID().uuidString).mp4")

      AVAssetExportSession.determineCompatibility(
        ofExportPreset: AVAssetExportPreset1920x1080,
        with: asset,
        outputFileType: .mp4
      ) { isCompatible in
        guard isCompatible else {
          completion(.failure(WatermarkBridgeError.unsupportedVideoExport))
          return
        }

        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mp4
        exportSession.videoComposition = videoComposition
        exportSession.shouldOptimizeForNetworkUse = true
        exportSession.exportAsynchronously {
          guard exportSession.status == .completed else {
            if let exportError = exportSession.error {
              completion(.failure(
                WatermarkBridgeError.exportFailed(exportError.localizedDescription)
              ))
            } else {
              completion(.failure(WatermarkBridgeError.exportFailed(
                "Video export ended with status \(exportSession.status.rawValue)."
              )))
            }
            return
          }

          do {
            try verifyRenderedVideo(
              outputURL,
              expectedDuration: CMTimeGetSeconds(asset.duration)
            )
            completion(.success(outputURL))
          } catch {
            completion(.failure(error))
          }
        }
      }
    } catch {
      completion(.failure(error))
    }
  }

  private static func makeWatermarkOverlay(
    _ snapshot: WatermarkSnapshotData,
    size: CGSize
  ) throws -> CGImage {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = false
    format.preferredRange = .standard
    let renderer = UIGraphicsImageRenderer(size: size, format: format)
    var watermarkRenderError: Error?
    let overlay = renderer.image { context in
      do {
        try drawWatermark(snapshot, in: context.cgContext, size: size)
      } catch {
        watermarkRenderError = error
      }
    }
    if let watermarkRenderError {
      throw watermarkRenderError
    }
    guard let image = overlay.cgImage else {
      throw WatermarkBridgeError.renderFailed
    }
    return image
  }

  private static func verifyRenderedVideo(
    _ outputURL: URL,
    expectedDuration: Double
  ) throws {
    let values = try outputURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard values.isRegularFile == true, (values.fileSize ?? 0) > 0 else {
      throw WatermarkBridgeError.invalidRenderedVideo(
        "The exported MP4 is missing or empty."
      )
    }

    let outputAsset = AVURLAsset(url: outputURL)
    let videoTracks = outputAsset.tracks(withMediaType: .video)
    guard let videoTrack = videoTracks.first else {
      throw WatermarkBridgeError.invalidRenderedVideo("The exported MP4 has no video track.")
    }
    guard outputAsset.tracks(withMediaType: .audio).first != nil else {
      throw WatermarkBridgeError.invalidRenderedVideo("The exported MP4 has no audio track.")
    }

    let outputBounds = CGRect(origin: .zero, size: videoTrack.naturalSize)
      .applying(videoTrack.preferredTransform)
      .standardized
    guard outputBounds.width.isFinite, outputBounds.height.isFinite,
          min(outputBounds.width, outputBounds.height) >= 1080,
          videoTrack.nominalFrameRate >= 29.9
    else {
      throw WatermarkBridgeError.invalidRenderedVideo(
        "The exported MP4 is below 1080p or 30 frames per second."
      )
    }

    let videoCodecs: [FourCharCode] = videoTrack.formatDescriptions.map { value in
      let description: CMFormatDescription = value as! CMFormatDescription
      return CMFormatDescriptionGetMediaSubType(description)
    }
    guard videoCodecs.contains(kCMVideoCodecType_H264) else {
      throw WatermarkBridgeError.invalidRenderedVideo("The exported video codec is not H.264.")
    }

    let audioTracks = outputAsset.tracks(withMediaType: .audio)
    let audioCodecs: [FourCharCode] = audioTracks.flatMap { track in
      track.formatDescriptions.map { value in
        let description: CMFormatDescription = value as! CMFormatDescription
        return CMFormatDescriptionGetMediaSubType(description)
      }
    }
    guard audioCodecs.contains(kAudioFormatMPEG4AAC) else {
      throw WatermarkBridgeError.invalidRenderedVideo("The exported audio codec is not AAC.")
    }

    let outputDuration = CMTimeGetSeconds(outputAsset.duration)
    guard CMTIME_IS_NUMERIC(outputAsset.duration), outputDuration.isFinite,
          abs(outputDuration - expectedDuration) <= 0.5
    else {
      throw WatermarkBridgeError.invalidRenderedVideo(
        "The exported MP4 duration does not match the recorded source."
      )
    }
  }

  private static func validateTemporaryFile(_ url: URL) throws {
    let temporaryRoot = FileManager.default.temporaryDirectory
      .resolvingSymlinksInPath()
      .standardizedFileURL
    let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL
    let requiredPrefix = temporaryRoot.path.hasSuffix("/")
      ? temporaryRoot.path
      : temporaryRoot.path + "/"
    guard resolvedURL.path.hasPrefix(requiredPrefix) else {
      throw WatermarkBridgeError.sourceOutsideTemporaryDirectory
    }

    let values = try resolvedURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard values.isRegularFile == true, (values.fileSize ?? 0) > 0 else {
      throw WatermarkBridgeError.invalidSourceFile("sourcePath must name a non-empty regular file.")
    }
  }

  private static func drawWatermark(
    _ snapshot: WatermarkSnapshotData,
    in context: CGContext,
    size: CGSize
  ) throws {
    let shortSide = min(size.width, size.height)
    let horizontalInset = size.width * 0.03
    let maximumWidth = size.width - (horizontalInset * 2)

    if !snapshot.customText.isEmpty {
      try drawCenteredText(
        snapshot.customText,
        in: context,
        canvasSize: size,
        centerY: 0.71,
        baseFontSize: shortSide * 0.032,
        maximumWidth: maximumWidth,
        weight: .medium,
        maximumLines: 2
      )
    }
    try drawCenteredText(
      snapshot.timeText,
      in: context,
      canvasSize: size,
      centerY: 0.80,
      baseFontSize: shortSide * 0.14,
      maximumWidth: maximumWidth,
      weight: .semibold,
      maximumLines: 1
    )
    try drawMetadata(
      snapshot,
      in: context,
      canvasSize: size,
      centerY: 0.91,
      baseFontSize: shortSide * 0.035,
      maximumWidth: maximumWidth
    )
    drawBrand(snapshot.brandText, in: context, canvasSize: size, shortSide: shortSide)
  }

  private static func drawCenteredText(
    _ value: String,
    in context: CGContext,
    canvasSize: CGSize,
    centerY: CGFloat,
    baseFontSize: CGFloat,
    maximumWidth: CGFloat,
    weight: UIFont.Weight,
    maximumLines: Int
  ) throws {
    let baseFont = UIFont.systemFont(ofSize: baseFontSize, weight: weight)
    let measuredWidth = (value as NSString).size(withAttributes: [.font: baseFont]).width
    let fontSize = fittedFontSize(
      baseFontSize: baseFontSize,
      measuredWidth: measuredWidth,
      maximumWidth: maximumWidth
    )
    let font = UIFont.systemFont(ofSize: fontSize, weight: weight)
    let attributedText = NSMutableAttributedString(
      string: value,
      attributes: textAttributes(font: font, alignment: .center)
    )
    let bounds = attributedText.boundingRect(
      with: CGSize(width: maximumWidth, height: CGFloat.greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading],
      context: nil
    )
    let lineCount = Int(ceil(bounds.height / font.lineHeight))
    guard lineCount <= maximumLines else {
      throw WatermarkBridgeError.watermarkLayoutDoesNotFit(
        "Watermark text exceeds its two-line layout limit."
      )
    }
    let drawingRect = CGRect(
      x: (canvasSize.width - maximumWidth) / 2,
      y: canvasSize.height * centerY - bounds.height / 2,
      width: maximumWidth,
      height: bounds.height
    )
    attributedText.draw(in: drawingRect)
  }

  private static func drawMetadata(
    _ snapshot: WatermarkSnapshotData,
    in context: CGContext,
    canvasSize: CGSize,
    centerY: CGFloat,
    baseFontSize: CGFloat,
    maximumWidth: CGFloat
  ) throws {
    let baseFont = UIFont.systemFont(ofSize: baseFontSize, weight: .medium)
    let measurementText = "\(snapshot.dateText)  \(snapshot.weekdayText)  \(snapshot.locationText)"
    let measuredWidth = (measurementText as NSString)
      .size(withAttributes: [.font: baseFont]).width
    let fontSize = fittedFontSize(
      baseFontSize: baseFontSize,
      measuredWidth: measuredWidth,
      maximumWidth: maximumWidth
    )
    let font = UIFont.systemFont(ofSize: fontSize, weight: .medium)
    let attributedText = NSMutableAttributedString(
      string: "\(snapshot.dateText)  \(snapshot.weekdayText)  ",
      attributes: textAttributes(font: font, alignment: .center)
    )
    let marker = NSTextAttachment()
    marker.image = locationPinImage(fontSize: fontSize)
    marker.bounds = CGRect(
      x: 0,
      y: -fontSize * 0.08,
      width: fontSize * 0.58,
      height: fontSize * 0.86
    )
    attributedText.append(NSAttributedString(attachment: marker))
    attributedText.append(
      NSAttributedString(
        string: snapshot.locationText,
        attributes: textAttributes(font: font, alignment: .center)
      )
    )

    let bounds = attributedText.boundingRect(
      with: CGSize(width: maximumWidth, height: CGFloat.greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading],
      context: nil
    )
    let lineCount = Int(ceil(bounds.height / font.lineHeight))
    guard lineCount <= 2 else {
      throw WatermarkBridgeError.watermarkLayoutDoesNotFit(
        "Watermark metadata exceeds its two-line layout limit."
      )
    }
    attributedText.draw(
      in: CGRect(
        x: (canvasSize.width - maximumWidth) / 2,
        y: canvasSize.height * centerY - bounds.height / 2,
        width: maximumWidth,
        height: bounds.height
      )
    )
  }

  private static func drawBrand(
    _ value: String,
    in context: CGContext,
    canvasSize: CGSize,
    shortSide: CGFloat
  ) {
    let font = UIFont.systemFont(ofSize: shortSide * 0.019, weight: .medium)
    var attributes = textAttributes(font: font, alignment: .right)
    attributes[.kern] = 0.4
    let measuredSize = (value as NSString).size(withAttributes: attributes)
    let rightInset = canvasSize.width * 0.03
    let bottomInset = canvasSize.height * 0.03
    let drawingRect = CGRect(
      x: canvasSize.width - rightInset - measuredSize.width,
      y: canvasSize.height - bottomInset - measuredSize.height,
      width: measuredSize.width,
      height: measuredSize.height
    )
    (value as NSString).draw(in: drawingRect, withAttributes: attributes)
  }

  private static func fittedFontSize(
    baseFontSize: CGFloat,
    measuredWidth: CGFloat,
    maximumWidth: CGFloat
  ) -> CGFloat {
    guard measuredWidth > maximumWidth else {
      return baseFontSize
    }
    let requiredScale = maximumWidth / measuredWidth
    return baseFontSize * max(0.70, requiredScale)
  }

  private static func textAttributes(
    font: UIFont,
    alignment: NSTextAlignment
  ) -> [NSAttributedString.Key: Any] {
    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.alignment = alignment
    paragraphStyle.lineBreakMode = .byCharWrapping
    let shadow = NSShadow()
    shadow.shadowColor = UIColor.black.withAlphaComponent(0.70)
    shadow.shadowOffset = CGSize(width: 0, height: 1)
    shadow.shadowBlurRadius = 2
    return [
      .font: font,
      .foregroundColor: UIColor.white,
      .paragraphStyle: paragraphStyle,
      .shadow: shadow,
    ]
  }

  private static func locationPinImage(fontSize: CGFloat) -> UIImage {
    let size = CGSize(width: fontSize * 0.58, height: fontSize * 0.86)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = false
    let renderer = UIGraphicsImageRenderer(size: size, format: format)
    return renderer.image { _ in
      let centerX = size.width / 2
      let pin = UIBezierPath()
      pin.move(to: CGPoint(x: centerX, y: 0))
      pin.addCurve(
        to: CGPoint(x: centerX, y: size.height),
        controlPoint1: CGPoint(x: size.width * 0.92, y: 0),
        controlPoint2: CGPoint(x: size.width, y: size.height * 0.18)
      )
      pin.addCurve(
        to: CGPoint(x: centerX, y: 0),
        controlPoint1: CGPoint(x: 0, y: size.height * 0.18),
        controlPoint2: CGPoint(x: size.width * 0.08, y: 0)
      )
      UIColor(red: 0.90, green: 0.22, blue: 0.21, alpha: 1).setFill()
      pin.fill()
      UIColor.white.setFill()
      UIBezierPath(
        ovalIn: CGRect(
          x: centerX - size.width * 0.14,
          y: size.height * 0.28 - size.width * 0.14,
          width: size.width * 0.28,
          height: size.width * 0.28
        )
      ).fill()
    }
  }

  private static func flutterError(for error: Error) -> FlutterError {
    if let bridgeError = error as? WatermarkBridgeError {
      return FlutterError(
        code: bridgeError.code,
        message: bridgeError.localizedDescription,
        details: ["code": bridgeError.code]
      )
    }
    return FlutterError(
      code: "native_error",
      message: error.localizedDescription,
      details: ["type": String(reflecting: type(of: error))]
    )
  }
}
