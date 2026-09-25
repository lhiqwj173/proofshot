import AVKit
import Flutter
import Photos
import UIKit

private enum WatermarkGalleryError: Error, LocalizedError {
  case invalidArguments(String)
  case invalidRecord(String)
  case missingRecord
  case missingPhotoPermission
  case missingGalleryPermission
  case assetNotFound
  case uncertainSaveResult
  case savedButIndexFailed(String)
  case savedButCleanupFailed(String)
  case galleryPresentationUnavailable

  var code: String {
    switch self {
    case .invalidArguments:
      return "invalid_arguments"
    case .invalidRecord:
      return "invalid_media_record"
    case .missingRecord:
      return "media_record_not_found"
    case .missingPhotoPermission:
      return "photo_add_permission_denied"
    case .missingGalleryPermission:
      return "photo_read_permission_denied"
    case .assetNotFound:
      return "photo_asset_not_found"
    case .uncertainSaveResult:
      return "photo_save_result_uncertain"
    case .savedButIndexFailed:
      return "saved_but_index_failed"
    case .savedButCleanupFailed:
      return "saved_but_cleanup_failed"
    case .galleryPresentationUnavailable:
      return "gallery_presentation_unavailable"
    }
  }

  var errorDescription: String? {
    switch self {
    case let .invalidArguments(message), let .invalidRecord(message),
         let .savedButIndexFailed(message), let .savedButCleanupFailed(message):
      return message
    case .missingRecord:
      return "The pending media operation no longer exists."
    case .missingPhotoPermission:
      return "请允许水印相机添加照片和视频后重试。"
    case .missingGalleryPermission:
      return "请在系统设置中允许水印相机访问照片图库。"
    case .assetNotFound:
      return "The selected photo library asset no longer exists."
    case .uncertainSaveResult:
      return "保存结果不确定，请先检查系统照片，再决定是否重试。"
    case .galleryPresentationUnavailable:
      return "当前无法打开图库，请返回相机页后重试。"
    }
  }
}

private struct WatermarkMediaRecord {
  var id: String
  var kind: String
  var capturedAt: String
  var snapshot: [String: String]
  var sourcePath: String
  var renderedPath: String?
  var status: String
  var localIdentifier: String?
  var errorMessage: String?

  var transactionURLName: String { "\(id).json" }

  var flutterValue: [String: Any] {
    var value: [String: Any] = [
      "id": id,
      "kind": kind,
      "capturedAt": capturedAt,
      "snapshot": snapshot,
      "sourcePath": sourcePath,
      "status": status,
    ]
    value["renderedPath"] = renderedPath.map { $0 as Any } ?? NSNull()
    value["localIdentifier"] = localIdentifier.map { $0 as Any } ?? NSNull()
    value["errorMessage"] = errorMessage.map { $0 as Any } ?? NSNull()
    return value
  }

  var jsonValue: [String: Any] {
    var value = flutterValue
    value["version"] = 1
    return value
  }

  init(
    id: String,
    kind: String,
    capturedAt: String,
    snapshot: [String: String],
    sourcePath: String,
    renderedPath: String?,
    status: String,
    localIdentifier: String?,
    errorMessage: String?
  ) {
    self.id = id
    self.kind = kind
    self.capturedAt = capturedAt
    self.snapshot = snapshot
    self.sourcePath = sourcePath
    self.renderedPath = renderedPath
    self.status = status
    self.localIdentifier = localIdentifier
    self.errorMessage = errorMessage
  }

  init(jsonValue: Any) throws {
    guard let value = jsonValue as? [String: Any],
          Set(value.keys) == Set([
            "version", "id", "kind", "capturedAt", "snapshot", "sourcePath",
            "renderedPath", "status", "localIdentifier", "errorMessage",
          ]),
          (value["version"] as? NSNumber)?.intValue == 1,
          let id = value["id"] as? String,
          UUID(uuidString: id) != nil,
          let kind = value["kind"] as? String,
          ["photo", "video"].contains(kind),
          let capturedAt = value["capturedAt"] as? String,
          Self.isValidTimestamp(capturedAt),
          let rawSnapshot = value["snapshot"] as? [String: Any],
          let sourcePath = value["sourcePath"] as? String,
          sourcePath.hasPrefix("/"),
          let status = value["status"] as? String,
          ["prepared", "rendered", "retryable", "saving", "savedNeedsIndex"]
            .contains(status)
    else {
      throw WatermarkGalleryError.invalidRecord("A pending media record is malformed.")
    }

    let expectedSnapshotKeys: Set<String> = [
      "capturedAt", "timeText", "dateText", "weekdayText",
      "locationText", "customText", "brandText",
    ]
    guard Set(rawSnapshot.keys) == expectedSnapshotKeys else {
      throw WatermarkGalleryError.invalidRecord("A pending snapshot has an invalid schema.")
    }
    var snapshot: [String: String] = [:]
    for key in expectedSnapshotKeys {
      guard let field = rawSnapshot[key] as? String else {
        throw WatermarkGalleryError.invalidRecord("Snapshot field \(key) must be a string.")
      }
      snapshot[key] = field
    }
    guard snapshot["capturedAt"] == capturedAt else {
      throw WatermarkGalleryError.invalidRecord("Snapshot and task timestamps do not match.")
    }

    let renderedValue = value["renderedPath"]
    let renderedPath: String?
    if renderedValue is NSNull {
      renderedPath = nil
    } else if let path = renderedValue as? String, path.hasPrefix("/") {
      renderedPath = path
    } else {
      throw WatermarkGalleryError.invalidRecord("renderedPath must be a path or null.")
    }
    let identifierValue = value["localIdentifier"]
    let localIdentifier: String?
    if identifierValue is NSNull {
      localIdentifier = nil
    } else if let identifier = identifierValue as? String, !identifier.isEmpty {
      localIdentifier = identifier
    } else {
      throw WatermarkGalleryError.invalidRecord("localIdentifier must be a string or null.")
    }
    let messageValue = value["errorMessage"]
    let errorMessage: String?
    if messageValue is NSNull {
      errorMessage = nil
    } else if let message = messageValue as? String {
      errorMessage = message
    } else {
      throw WatermarkGalleryError.invalidRecord("errorMessage must be a string or null.")
    }

    self.id = id
    self.kind = kind
    self.capturedAt = capturedAt
    self.snapshot = snapshot
    self.sourcePath = sourcePath
    self.renderedPath = renderedPath
    self.status = status
    self.localIdentifier = localIdentifier
    self.errorMessage = errorMessage
  }

  static func isValidTimestamp(_ value: String) -> Bool {
    guard value.range(
      of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?[+-][0-9]{2}:[0-9]{2}$"#,
      options: .regularExpression
    ) != nil else {
      return false
    }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if formatter.date(from: value) != nil {
      return true
    }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value) != nil
  }
}

private struct WatermarkMediaIndexItem {
  let id: String
  let kind: String
  let capturedAt: String

  var jsonValue: [String: String] {
    ["id": id, "kind": kind, "capturedAt": capturedAt]
  }
}

private final class WatermarkMediaJournal {
  static let shared = WatermarkMediaJournal()

  private let lock = NSRecursiveLock()
  private let fileManager = FileManager.default

  func prepare(sourcePath: String, kind: String, snapshot: [String: String]) throws -> String {
    lock.lock()
    defer { lock.unlock() }
    guard ["photo", "video"].contains(kind),
          sourcePath.hasPrefix("/"),
          let capturedAt = snapshot["capturedAt"],
          WatermarkMediaRecord.isValidTimestamp(capturedAt),
          snapshot["brandText"] == "水印相机",
          let location = snapshot["locationText"],
          !location.isEmpty,
          location.count <= 40,
          let customText = snapshot["customText"],
          customText.count <= 30
    else {
      throw WatermarkGalleryError.invalidArguments("prepareMedia received invalid media fields.")
    }
    guard Set(snapshot.keys) == Set([
      "capturedAt", "timeText", "dateText", "weekdayText",
      "locationText", "customText", "brandText",
    ]) else {
      throw WatermarkGalleryError.invalidArguments("prepareMedia received an invalid snapshot.")
    }
    try validateTemporaryFile(URL(fileURLWithPath: sourcePath))
    let id = UUID().uuidString.lowercased()
    let record = WatermarkMediaRecord(
      id: id,
      kind: kind,
      capturedAt: capturedAt,
      snapshot: snapshot,
      sourcePath: URL(fileURLWithPath: sourcePath).standardizedFileURL.path,
      renderedPath: nil,
      status: "prepared",
      localIdentifier: nil,
      errorMessage: nil
    )
    try writeRecord(record)
    return id
  }

  func updateRendered(id: String, renderedPath: String) throws {
    lock.lock()
    defer { lock.unlock() }
    var record = try readRecord(id: id)
    guard record.status == "prepared" || record.status == "retryable" else {
      throw WatermarkGalleryError.invalidRecord("Only prepared media can record a rendered file.")
    }
    guard renderedPath.hasPrefix("/") else {
      throw WatermarkGalleryError.invalidArguments("renderedPath must be an absolute path.")
    }
    let url = URL(fileURLWithPath: renderedPath).standardizedFileURL
    try validateTemporaryFile(url)
    guard url.path != URL(fileURLWithPath: record.sourcePath).standardizedFileURL.path else {
      throw WatermarkGalleryError.invalidArguments("The rendered file must differ from its source.")
    }
    let expectedExtension = record.kind == "photo" ? "jpg" : "mp4"
    guard url.pathExtension.lowercased() == expectedExtension else {
      throw WatermarkGalleryError.invalidArguments("The rendered file extension does not match its media type.")
    }
    record.renderedPath = url.path
    record.status = "rendered"
    record.errorMessage = nil
    try writeRecord(record)
  }

  func readRecord(id: String) throws -> WatermarkMediaRecord {
    lock.lock()
    defer { lock.unlock() }
    guard UUID(uuidString: id) != nil else {
      throw WatermarkGalleryError.invalidArguments("taskId must be a UUID.")
    }
    let url = try transactionDirectory().appendingPathComponent("\(id).json")
    guard fileManager.fileExists(atPath: url.path) else {
      throw WatermarkGalleryError.missingRecord
    }
    let text = try String(contentsOf: url, encoding: .utf8)
    guard let data = text.data(using: .utf8) else {
      throw WatermarkGalleryError.invalidRecord("A pending record is not valid UTF-8.")
    }
    return try WatermarkMediaRecord(jsonValue: JSONSerialization.jsonObject(with: data))
  }

  func markSaving(id: String) throws -> WatermarkMediaRecord {
    lock.lock()
    defer { lock.unlock() }
    var record = try readRecord(id: id)
    guard record.status == "rendered" || record.status == "retryable",
          let renderedPath = record.renderedPath
    else {
      throw WatermarkGalleryError.invalidRecord("This media operation is not ready to save.")
    }
    try validateTemporaryFile(URL(fileURLWithPath: renderedPath))
    record.status = "saving"
    record.errorMessage = nil
    try writeRecord(record)
    return record
  }

  func markRetryable(id: String, message: String) throws {
    lock.lock()
    defer { lock.unlock() }
    var record = try readRecord(id: id)
    guard record.status == "saving" || record.status == "rendered" else {
      throw WatermarkGalleryError.invalidRecord("This media operation cannot be marked retryable.")
    }
    record.status = "retryable"
    record.errorMessage = message
    try writeRecord(record)
  }

  func markSaved(id: String, localIdentifier: String) throws -> WatermarkMediaRecord {
    lock.lock()
    defer { lock.unlock() }
    var record = try readRecord(id: id)
    guard record.status == "saving", !localIdentifier.isEmpty else {
      throw WatermarkGalleryError.uncertainSaveResult
    }
    record.status = "savedNeedsIndex"
    record.localIdentifier = localIdentifier
    record.errorMessage = nil
    try writeRecord(record)
    return record
  }

  func addToIndex(_ record: WatermarkMediaRecord) throws {
    lock.lock()
    defer { lock.unlock() }
    var items = try readIndex()
    if let existing = items.first(where: { $0.id == record.localIdentifier }) {
      guard existing.kind == record.kind, existing.capturedAt == record.capturedAt else {
        throw WatermarkGalleryError.invalidRecord("An existing media index entry conflicts with this asset.")
      }
      return
    }
    guard let localIdentifier = record.localIdentifier else {
      throw WatermarkGalleryError.invalidRecord("A saved media record has no localIdentifier.")
    }
    items.append(WatermarkMediaIndexItem(
      id: localIdentifier,
      kind: record.kind,
      capturedAt: record.capturedAt
    ))
    try writeIndex(items)
  }

  func finishAndClean(_ record: WatermarkMediaRecord) throws {
    lock.lock()
    defer { lock.unlock() }
    guard record.status == "savedNeedsIndex" else {
      throw WatermarkGalleryError.invalidRecord("Only indexed media can be cleaned up.")
    }
    try removeTemporaryFileIfPresent(URL(fileURLWithPath: record.sourcePath))
    if let renderedPath = record.renderedPath {
      try removeTemporaryFileIfPresent(URL(fileURLWithPath: renderedPath))
    }
    let recordURL = try transactionDirectory()
      .appendingPathComponent(record.transactionURLName)
    try fileManager.removeItem(at: recordURL)
  }

  func pendingRecordsAndRepairIndex() throws -> [WatermarkMediaRecord] {
    lock.lock()
    defer { lock.unlock() }
    let directory = try transactionDirectory()
    let urls = try fileManager.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles]
    ).filter { $0.pathExtension == "json" }
    var pending: [WatermarkMediaRecord] = []
    for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
      let text = try String(contentsOf: url, encoding: .utf8)
      guard let data = text.data(using: .utf8) else {
        throw WatermarkGalleryError.invalidRecord("A pending record is not valid UTF-8.")
      }
      var record = try WatermarkMediaRecord(jsonValue: JSONSerialization.jsonObject(with: data))
      guard url.lastPathComponent == record.transactionURLName else {
        throw WatermarkGalleryError.invalidRecord("A pending record filename does not match its ID.")
      }
      if record.status == "savedNeedsIndex" {
        try addToIndex(record)
        try finishAndClean(record)
      } else {
        pending.append(record)
      }
    }
    return pending
  }

  func indexItems() throws -> [WatermarkMediaIndexItem] {
    lock.lock()
    defer { lock.unlock() }
    return try sortedIndexItems(readIndex())
  }

  func removeFromIndex(id: String) throws {
    lock.lock()
    defer { lock.unlock() }
    var items = try readIndex()
    guard items.contains(where: { $0.id == id }) else {
      throw WatermarkGalleryError.assetNotFound
    }
    items.removeAll(where: { $0.id == id })
    try writeIndex(items)
  }

  private func readIndex() throws -> [WatermarkMediaIndexItem] {
    let url = try indexURL()
    guard fileManager.fileExists(atPath: url.path) else {
      return []
    }
    let text = try String(contentsOf: url, encoding: .utf8)
    guard let data = text.data(using: .utf8),
          let document = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          Set(document.keys) == Set(["version", "items"]),
          (document["version"] as? NSNumber)?.intValue == 1,
          let rawItems = document["items"] as? [[String: Any]]
    else {
      throw WatermarkGalleryError.invalidRecord("The media index schema is invalid or unsupported.")
    }
    var items: [WatermarkMediaIndexItem] = []
    var seenIdentifiers = Set<String>()
    for value in rawItems {
      guard Set(value.keys) == Set(["id", "kind", "capturedAt"]),
            let id = value["id"] as? String, !id.isEmpty,
            !seenIdentifiers.contains(id),
            let kind = value["kind"] as? String, ["photo", "video"].contains(kind),
            let capturedAt = value["capturedAt"] as? String,
            WatermarkMediaRecord.isValidTimestamp(capturedAt)
      else {
        throw WatermarkGalleryError.invalidRecord("The media index contains an invalid item.")
      }
      seenIdentifiers.insert(id)
      items.append(WatermarkMediaIndexItem(id: id, kind: kind, capturedAt: capturedAt))
    }
    return items
  }

  private func writeIndex(_ items: [WatermarkMediaIndexItem]) throws {
    let ordered = try sortedIndexItems(items)
    try writeJSON([
      "version": 1,
      "items": ordered.map(\.jsonValue),
    ], to: try indexURL())
  }

  private func writeRecord(_ record: WatermarkMediaRecord) throws {
    let url = try transactionDirectory().appendingPathComponent(record.transactionURLName)
    try writeJSON(record.jsonValue, to: url)
  }

  private func sortedIndexItems(
    _ items: [WatermarkMediaIndexItem]
  ) throws -> [WatermarkMediaIndexItem] {
    let datedItems = try items.map { item -> (WatermarkMediaIndexItem, Date) in
      guard let date = WatermarkMediaRecord.date(from: item.capturedAt) else {
        throw WatermarkGalleryError.invalidRecord("The media index contains an invalid timestamp.")
      }
      return (item, date)
    }
    return datedItems.sorted { $0.1 > $1.1 }.map { $0.0 }
  }

  private func writeJSON(_ value: Any, to url: URL) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    guard let text = String(data: data, encoding: .utf8) else {
      throw WatermarkGalleryError.invalidRecord("JSON could not be encoded as UTF-8.")
    }
    try text.write(to: url, atomically: true, encoding: .utf8)
  }

  private func indexURL() throws -> URL {
    try storageDirectory().appendingPathComponent("media-index.json")
  }

  private func transactionDirectory() throws -> URL {
    let url = try storageDirectory().appendingPathComponent("pending", isDirectory: true)
    try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func storageDirectory() throws -> URL {
    guard let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    else {
      throw WatermarkGalleryError.invalidRecord("The application support directory is unavailable.")
    }
    let url = base.appendingPathComponent("proofshot", isDirectory: true)
    try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func validateTemporaryFile(_ url: URL) throws {
    let temporaryRoot = fileManager.temporaryDirectory
      .resolvingSymlinksInPath()
      .standardizedFileURL
    let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL
    let prefix = temporaryRoot.path.hasSuffix("/") ? temporaryRoot.path : temporaryRoot.path + "/"
    guard resolvedURL.path.hasPrefix(prefix) else {
      throw WatermarkGalleryError.invalidArguments("Media paths must stay inside the app temporary directory.")
    }
    let values = try resolvedURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard values.isRegularFile == true, (values.fileSize ?? 0) > 0 else {
      throw WatermarkGalleryError.invalidArguments("Media paths must name a non-empty regular file.")
    }
  }

  private func removeTemporaryFileIfPresent(_ url: URL) throws {
    let temporaryRoot = fileManager.temporaryDirectory
      .resolvingSymlinksInPath()
      .standardizedFileURL
    let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL
    let prefix = temporaryRoot.path.hasSuffix("/") ? temporaryRoot.path : temporaryRoot.path + "/"
    guard resolvedURL.path.hasPrefix(prefix) else {
      throw WatermarkGalleryError.invalidArguments("Cleanup path escaped the app temporary directory.")
    }
    if fileManager.fileExists(atPath: resolvedURL.path) {
      try fileManager.removeItem(at: resolvedURL)
    }
  }
}

private extension WatermarkMediaRecord {
  static func date(from value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) {
      return date
    }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)
  }
}

final class WatermarkGalleryBridge {
  private let channel: FlutterMethodChannel
  private let journal = WatermarkMediaJournal.shared

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: "proofshot/gallery",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(FlutterError(
          code: "gallery_bridge_unavailable",
          message: "The media gallery bridge is no longer available.",
          details: nil
        ))
        return
      }
      self.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "prepareMedia":
      do {
        guard let arguments = call.arguments as? [String: Any],
              Set(arguments.keys) == Set(["sourcePath", "kind", "snapshot"]),
              let sourcePath = arguments["sourcePath"] as? String,
              let kind = arguments["kind"] as? String,
              let rawSnapshot = arguments["snapshot"] as? [String: Any]
        else {
          throw WatermarkGalleryError.invalidArguments("prepareMedia expects sourcePath, kind, and snapshot.")
        }
        var snapshot: [String: String] = [:]
        for (key, value) in rawSnapshot {
          guard let field = value as? String else {
            throw WatermarkGalleryError.invalidArguments("Snapshot field \(key) must be a string.")
          }
          snapshot[key] = field
        }
        result(["taskId": try journal.prepare(
          sourcePath: sourcePath,
          kind: kind,
          snapshot: snapshot
        )])
      } catch {
        result(Self.flutterError(for: error))
      }
    case "markRendered":
      do {
        guard let arguments = call.arguments as? [String: Any],
              Set(arguments.keys) == Set(["taskId", "renderedPath"]),
              let taskId = arguments["taskId"] as? String,
              let renderedPath = arguments["renderedPath"] as? String
        else {
          throw WatermarkGalleryError.invalidArguments("markRendered expects taskId and renderedPath.")
        }
        try journal.updateRendered(id: taskId, renderedPath: renderedPath)
        result(nil)
      } catch {
        result(Self.flutterError(for: error))
      }
    case "saveToPhotos":
      do {
        guard let arguments = call.arguments as? [String: Any],
              Set(arguments.keys) == Set(["taskId"]),
              let taskId = arguments["taskId"] as? String
        else {
          throw WatermarkGalleryError.invalidArguments("saveToPhotos expects a taskId.")
        }
        authorizeAddOnly { [weak self] isAuthorized in
          guard let self else {
            result(Self.flutterError(for: WatermarkGalleryError.uncertainSaveResult))
            return
          }
          guard isAuthorized else {
            do {
              try self.journal.markRetryable(id: taskId, message: "Photo add permission was denied.")
              result(Self.flutterError(for: WatermarkGalleryError.missingPhotoPermission))
            } catch {
              result(Self.flutterError(for: error))
            }
            return
          }
          self.save(taskId: taskId, result: result)
        }
      } catch {
        result(Self.flutterError(for: error))
      }
    case "pendingMedia":
      do {
        let pending = try journal.pendingRecordsAndRepairIndex()
        result(["items": pending.map(\.flutterValue)])
      } catch {
        result(Self.flutterError(for: error))
      }
    case "openGallery":
      openGallery(result: result)
    case "openSettings":
      guard let url = URL(string: UIApplication.openSettingsURLString) else {
        result(Self.flutterError(for: WatermarkGalleryError.galleryPresentationUnavailable))
        return
      }
      DispatchQueue.main.async {
        UIApplication.shared.open(url)
        result(nil)
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func authorizeAddOnly(completion: @escaping (Bool) -> Void) {
    switch PHPhotoLibrary.authorizationStatus(for: .addOnly) {
    case .authorized:
      completion(true)
    case .notDetermined:
      PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
        completion(status == .authorized)
      }
    case .denied, .restricted, .limited:
      completion(false)
    @unknown default:
      completion(false)
    }
  }

  private func save(taskId: String, result: @escaping FlutterResult) {
    let record: WatermarkMediaRecord
    do {
      record = try journal.markSaving(id: taskId)
    } catch {
      result(Self.flutterError(for: error))
      return
    }
    guard let renderedPath = record.renderedPath else {
      result(Self.flutterError(for: WatermarkGalleryError.invalidRecord(
        "The rendered media file is missing from the pending record."
      )))
      return
    }

    var localIdentifier: String?
    let renderedURL = URL(fileURLWithPath: renderedPath)
    PHPhotoLibrary.shared().performChanges {
      let request = PHAssetCreationRequest.forAsset()
      request.addResource(
        with: record.kind == "photo" ? .photo : .video,
        fileURL: renderedURL,
        options: nil
      )
      localIdentifier = request.placeholderForCreatedAsset?.localIdentifier
    } completionHandler: { [weak self] succeeded, error in
      guard let self else {
        result(Self.flutterError(for: WatermarkGalleryError.uncertainSaveResult))
        return
      }
      guard succeeded else {
        do {
          try self.journal.markRetryable(
            id: taskId,
            message: error?.localizedDescription ?? "PhotoKit did not save the media."
          )
          result(FlutterError(
            code: "photo_save_failed",
            message: error?.localizedDescription ?? "PhotoKit did not save the media.",
            details: ["code": "photo_save_failed"]
          ))
        } catch {
          result(Self.flutterError(for: error))
        }
        return
      }
      guard let localIdentifier, !localIdentifier.isEmpty else {
        result(Self.flutterError(for: WatermarkGalleryError.uncertainSaveResult))
        return
      }

      let savedRecord: WatermarkMediaRecord
      do {
        savedRecord = try self.journal.markSaved(
          id: taskId,
          localIdentifier: localIdentifier
        )
      } catch {
        result(Self.flutterError(for: WatermarkGalleryError.uncertainSaveResult))
        return
      }
      do {
        try self.journal.addToIndex(savedRecord)
      } catch {
        result(Self.flutterError(for: WatermarkGalleryError.savedButIndexFailed(
          "已保存到相册，但应用内列表暂不可见。索引修复失败：\(error.localizedDescription)"
        )))
        return
      }
      do {
        try self.journal.finishAndClean(savedRecord)
      } catch {
        result(Self.flutterError(for: WatermarkGalleryError.savedButCleanupFailed(
          "已保存到相册并登记到应用图库，但临时文件清理失败：\(error.localizedDescription)"
        )))
        return
      }
      result(["localIdentifier": localIdentifier])
    }
  }

  private func openGallery(result: @escaping FlutterResult) {
    DispatchQueue.main.async { [weak self] in
      guard let self,
            let presenter = Self.topViewController()
      else {
        result(Self.flutterError(for: WatermarkGalleryError.galleryPresentationUnavailable))
        return
      }
      let gallery = WatermarkGalleryViewController(journal: self.journal) {
        result(nil)
      }
      let navigationController = UINavigationController(rootViewController: gallery)
      navigationController.overrideUserInterfaceStyle = .dark
      navigationController.modalPresentationStyle = .fullScreen
      presenter.present(navigationController, animated: true)
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

  private static func flutterError(for error: Error) -> FlutterError {
    if let galleryError = error as? WatermarkGalleryError {
      return FlutterError(
        code: galleryError.code,
        message: galleryError.localizedDescription,
        details: ["code": galleryError.code]
      )
    }
    return FlutterError(
      code: "native_gallery_error",
      message: error.localizedDescription,
      details: ["type": String(reflecting: type(of: error))]
    )
  }
}

private struct WatermarkGalleryEntry {
  let item: WatermarkMediaIndexItem
  let asset: PHAsset
}

private final class WatermarkMediaCell: UICollectionViewCell {
  static let reuseIdentifier = "WatermarkMediaCell"

  private let imageView = UIImageView()
  private let typeLabel = UILabel()
  private let errorLabel = UILabel()
  private let progressView = UIActivityIndicatorView(style: .medium)
  private let selectionMark = UIImageView()
  private var imageRequestID: PHImageRequestID?
  private var representedIdentifier: String?

  override init(frame: CGRect) {
    super.init(frame: frame)
    contentView.backgroundColor = UIColor(red: 0.11, green: 0.16, blue: 0.16, alpha: 1)
    contentView.layer.cornerRadius = 11
    contentView.clipsToBounds = true
    imageView.contentMode = .scaleAspectFill
    imageView.clipsToBounds = true
    imageView.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(imageView)
    typeLabel.font = .systemFont(ofSize: 11, weight: .semibold)
    typeLabel.textColor = .white
    typeLabel.backgroundColor = UIColor.black.withAlphaComponent(0.64)
    typeLabel.textAlignment = .center
    typeLabel.layer.cornerRadius = 4
    typeLabel.clipsToBounds = true
    typeLabel.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(typeLabel)
    errorLabel.text = "无法加载缩略图"
    errorLabel.textColor = .white
    errorLabel.font = .systemFont(ofSize: 12, weight: .medium)
    errorLabel.textAlignment = .center
    errorLabel.numberOfLines = 2
    errorLabel.backgroundColor = UIColor.black.withAlphaComponent(0.64)
    errorLabel.translatesAutoresizingMaskIntoConstraints = false
    errorLabel.isHidden = true
    contentView.addSubview(errorLabel)
    progressView.color = .white
    progressView.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(progressView)
    selectionMark.tintColor = UIColor(red: 0.78, green: 0.96, blue: 0.83, alpha: 1)
    selectionMark.backgroundColor = UIColor.black.withAlphaComponent(0.55)
    selectionMark.layer.cornerRadius = 15
    selectionMark.contentMode = .center
    selectionMark.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(selectionMark)
    NSLayoutConstraint.activate([
      imageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      imageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      imageView.topAnchor.constraint(equalTo: contentView.topAnchor),
      imageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
      typeLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -5),
      typeLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -5),
      typeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 34),
      errorLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
      errorLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
      errorLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
      progressView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
      progressView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
      selectionMark.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 7),
      selectionMark.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -7),
      selectionMark.widthAnchor.constraint(equalToConstant: 30),
      selectionMark.heightAnchor.constraint(equalToConstant: 30),
    ])
  }

  required init?(coder: NSCoder) {
    fatalError("WatermarkMediaCell does not support storyboard initialization.")
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    if let imageRequestID {
      PHImageManager.default().cancelImageRequest(imageRequestID)
    }
    imageRequestID = nil
    representedIdentifier = nil
    imageView.image = nil
    typeLabel.text = nil
    errorLabel.isHidden = true
    progressView.stopAnimating()
    selectionMark.isHidden = true
  }

  func setSelectionMode(_ enabled: Bool, selected: Bool) {
    selectionMark.isHidden = !enabled
    selectionMark.image = UIImage(systemName: selected ? "checkmark.circle.fill" : "circle")
    contentView.layer.borderWidth = selected ? 3 : 0
    contentView.layer.borderColor = UIColor(red: 0.78, green: 0.96, blue: 0.83, alpha: 1).cgColor
  }

  func configure(with asset: PHAsset) {
    representedIdentifier = asset.localIdentifier
    typeLabel.text = asset.mediaType == .video ? "视频" : "照片"
    progressView.startAnimating()
    let options = PHImageRequestOptions()
    options.deliveryMode = .opportunistic
    options.resizeMode = .fast
    options.isNetworkAccessAllowed = true
    options.progressHandler = { [weak self] _, error, _, _ in
      guard error != nil else { return }
      DispatchQueue.main.async {
        guard self?.representedIdentifier == asset.localIdentifier else { return }
        self?.showThumbnailError()
      }
    }
    imageRequestID = PHImageManager.default().requestImage(
      for: asset,
      targetSize: CGSize(width: 420, height: 420),
      contentMode: .aspectFill,
      options: options
    ) { [weak self] image, info in
      DispatchQueue.main.async {
        guard let self, self.representedIdentifier == asset.localIdentifier else { return }
        if let image {
          self.imageView.image = image
        }
        let isDegraded = (info?[PHImageResultIsDegradedKey] as? NSNumber)?.boolValue == true
        let hasError = info?[PHImageErrorKey] != nil
        if hasError || (!isDegraded && image == nil) {
          self.showThumbnailError()
        }
        if !isDegraded || hasError {
          self.progressView.stopAnimating()
        }
      }
    }
  }

  private func showThumbnailError() {
    progressView.stopAnimating()
    errorLabel.isHidden = false
  }
}

private final class WatermarkGalleryViewController: UIViewController,
  UICollectionViewDataSource,
  UICollectionViewDelegateFlowLayout
{
  private let journal: WatermarkMediaJournal
  private let onClose: () -> Void
  private let filterControl = UISegmentedControl(items: ["全部", "照片", "视频"])
  private let countLabel = UILabel()
  private let statusLabel = UILabel()
  private let settingsButton = UIButton(type: .system)
  private let selectionBar = UIView()
  private let selectAllButton = UIButton(type: .system)
  private let deleteButton = UIButton(type: .system)
  private var selectionBarHeight: NSLayoutConstraint!
  private let collectionView: UICollectionView
  private var entries: [WatermarkGalleryEntry] = []
  private var filteredEntries: [WatermarkGalleryEntry] = []
  private var authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
  private var hiddenLimitedItemCount = 0
  private var isSelecting = false
  private var selectedIdentifiers = Set<String>()
  private var isDeleting = false

  init(journal: WatermarkMediaJournal, onClose: @escaping () -> Void) {
    self.journal = journal
    self.onClose = onClose
    let layout = UICollectionViewFlowLayout()
    layout.scrollDirection = .vertical
    layout.minimumInteritemSpacing = 8
    layout.minimumLineSpacing = 8
    layout.sectionInset = UIEdgeInsets(top: 0, left: 16, bottom: 20, right: 16)
    collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) {
    fatalError("WatermarkGalleryViewController does not support storyboard initialization.")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = "我的水印"
    overrideUserInterfaceStyle = .dark
    view.backgroundColor = UIColor(red: 0.055, green: 0.075, blue: 0.085, alpha: 1)
    navigationController?.navigationBar.tintColor = UIColor(red: 0.78, green: 0.96, blue: 0.83, alpha: 1)
    navigationController?.navigationBar.titleTextAttributes = [.foregroundColor: UIColor.white]
    navigationController?.navigationBar.barTintColor = view.backgroundColor
    navigationItem.leftBarButtonItem = UIBarButtonItem(
      barButtonSystemItem: .close,
      target: self,
      action: #selector(closeGallery)
    )
    updateNavigationActions()

    filterControl.selectedSegmentIndex = 0
    filterControl.selectedSegmentTintColor = UIColor(red: 0.78, green: 0.96, blue: 0.83, alpha: 1)
    filterControl.backgroundColor = UIColor(white: 0.18, alpha: 1)
    filterControl.setTitleTextAttributes([.foregroundColor: UIColor(white: 0.08, alpha: 1)], for: .selected)
    filterControl.setTitleTextAttributes([.foregroundColor: UIColor.white], for: .normal)
    filterControl.addTarget(self, action: #selector(filterChanged), for: .valueChanged)
    filterControl.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(filterControl)

    countLabel.font = .systemFont(ofSize: 22, weight: .bold)
    countLabel.textColor = .white
    countLabel.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(countLabel)

    statusLabel.numberOfLines = 0
    statusLabel.textAlignment = .center
    statusLabel.textColor = .lightGray
    statusLabel.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(statusLabel)

    settingsButton.setTitle("打开系统设置", for: .normal)
    settingsButton.tintColor = UIColor(red: 0.78, green: 0.96, blue: 0.83, alpha: 1)
    settingsButton.addTarget(self, action: #selector(openSystemSettings), for: .touchUpInside)
    settingsButton.translatesAutoresizingMaskIntoConstraints = false
    settingsButton.isHidden = true
    view.addSubview(settingsButton)

    collectionView.backgroundColor = view.backgroundColor
    collectionView.isScrollEnabled = true
    collectionView.alwaysBounceVertical = true
    collectionView.alwaysBounceHorizontal = false
    collectionView.showsVerticalScrollIndicator = true
    collectionView.dataSource = self
    collectionView.delegate = self
    collectionView.register(
      WatermarkMediaCell.self,
      forCellWithReuseIdentifier: WatermarkMediaCell.reuseIdentifier
    )
    collectionView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(collectionView)
    view.bringSubviewToFront(statusLabel)
    view.bringSubviewToFront(settingsButton)
    let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
    collectionView.addGestureRecognizer(longPress)

    selectionBar.backgroundColor = UIColor(red: 0.09, green: 0.12, blue: 0.13, alpha: 1)
    selectionBar.translatesAutoresizingMaskIntoConstraints = false
    selectionBar.isHidden = true
    view.addSubview(selectionBar)
    selectAllButton.setTitle("全选", for: .normal)
    selectAllButton.setTitleColor(UIColor(red: 0.78, green: 0.96, blue: 0.83, alpha: 1), for: .normal)
    selectAllButton.addTarget(self, action: #selector(toggleSelectAll), for: .touchUpInside)
    selectAllButton.translatesAutoresizingMaskIntoConstraints = false
    selectionBar.addSubview(selectAllButton)
    deleteButton.setTitle("删除", for: .normal)
    deleteButton.setTitleColor(UIColor(red: 1, green: 0.55, blue: 0.53, alpha: 1), for: .normal)
    deleteButton.addTarget(self, action: #selector(confirmDeleteSelection), for: .touchUpInside)
    deleteButton.translatesAutoresizingMaskIntoConstraints = false
    selectionBar.addSubview(deleteButton)

    selectionBarHeight = selectionBar.heightAnchor.constraint(equalToConstant: 0)
    NSLayoutConstraint.activate([
      filterControl.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
      filterControl.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
      filterControl.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
      countLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 18),
      countLabel.topAnchor.constraint(equalTo: filterControl.bottomAnchor, constant: 20),
      statusLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
      statusLabel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
      statusLabel.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
      settingsButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      settingsButton.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 16),
      collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      collectionView.topAnchor.constraint(equalTo: countLabel.bottomAnchor, constant: 14),
      collectionView.bottomAnchor.constraint(equalTo: selectionBar.topAnchor),
      selectionBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      selectionBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      selectionBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
      selectionBarHeight,
      selectAllButton.leadingAnchor.constraint(equalTo: selectionBar.leadingAnchor, constant: 20),
      selectAllButton.centerYAnchor.constraint(equalTo: selectionBar.centerYAnchor),
      deleteButton.trailingAnchor.constraint(equalTo: selectionBar.trailingAnchor, constant: -20),
      deleteButton.centerYAnchor.constraint(equalTo: selectionBar.centerYAnchor),
    ])
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(applicationDidBecomeActive),
      name: UIApplication.didBecomeActiveNotification,
      object: nil
    )
    requestGalleryAccessIfNeeded()
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    refreshAuthorizationStatus()
  }

  deinit {
    NotificationCenter.default.removeObserver(
      self,
      name: UIApplication.didBecomeActiveNotification,
      object: nil
    )
  }

  @objc private func applicationDidBecomeActive() {
    refreshAuthorizationStatus()
  }

  private func refreshAuthorizationStatus() {
    authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    if authorizationStatus == .authorized || authorizationStatus == .limited {
      reloadFromIndex()
    } else if authorizationStatus != .notDetermined {
      showPermissionRequired()
    }
  }

  func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
    filteredEntries.count
  }

  func collectionView(
    _ collectionView: UICollectionView,
    cellForItemAt indexPath: IndexPath
  ) -> UICollectionViewCell {
    guard indexPath.item < filteredEntries.count,
          let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: WatermarkMediaCell.reuseIdentifier,
            for: indexPath
          ) as? WatermarkMediaCell
    else {
      preconditionFailure("The gallery requested an invalid collection item.")
    }
    let entry = filteredEntries[indexPath.item]
    cell.configure(with: entry.asset)
    cell.setSelectionMode(isSelecting, selected: selectedIdentifiers.contains(entry.item.id))
    return cell
  }

  func collectionView(
    _ collectionView: UICollectionView,
    didSelectItemAt indexPath: IndexPath
  ) {
    guard indexPath.item < filteredEntries.count else {
      preconditionFailure("The selected gallery item is out of range.")
    }
    if isSelecting {
      let identifier = filteredEntries[indexPath.item].item.id
      if !selectedIdentifiers.insert(identifier).inserted {
        selectedIdentifiers.remove(identifier)
      }
      collectionView.reloadItems(at: [indexPath])
      updateSelectionActions()
      return
    }
    let detail = WatermarkMediaPagerViewController(
      journal: journal,
      entries: filteredEntries,
      initialIndex: indexPath.item
    ) { [weak self] in
      self?.reloadFromIndex()
    }
    navigationController?.pushViewController(detail, animated: true)
  }

  func collectionView(
    _ collectionView: UICollectionView,
    layout collectionViewLayout: UICollectionViewLayout,
    sizeForItemAt indexPath: IndexPath
  ) -> CGSize {
    let width = (collectionView.bounds.width - 48) / 3
    return CGSize(width: width, height: width)
  }

  @objc private func closeGallery() {
    dismiss(animated: true, completion: onClose)
  }

  private func updateNavigationActions() {
    if isSelecting {
      navigationItem.leftBarButtonItem = UIBarButtonItem(
        title: "取消", style: .plain, target: self, action: #selector(endSelection)
      )
      navigationItem.rightBarButtonItems = nil
      updateSelectionActions()
    } else {
      navigationItem.leftBarButtonItem = UIBarButtonItem(
        barButtonSystemItem: .close, target: self, action: #selector(closeGallery)
      )
      navigationItem.rightBarButtonItems = [
        UIBarButtonItem(title: "选择", style: .plain, target: self, action: #selector(beginSelection)),
        UIBarButtonItem(barButtonSystemItem: .refresh, target: self, action: #selector(refreshGallery)),
      ]
      if hiddenLimitedItemCount > 0 {
        navigationItem.rightBarButtonItems?.append(
          UIBarButtonItem(title: "权限", style: .plain, target: self, action: #selector(openSystemSettings))
        )
      }
      title = "我的水印"
    }
  }

  private func updateSelectionActions() {
    title = "已选择 \(selectedIdentifiers.count) 项"
    let visibleIdentifiers = Set(filteredEntries.map { $0.item.id })
    selectAllButton.setTitle(
      !visibleIdentifiers.isEmpty && visibleIdentifiers.isSubset(of: selectedIdentifiers)
        ? "取消全选" : "全选", for: .normal
    )
    selectAllButton.isEnabled = !filteredEntries.isEmpty && !isDeleting
    deleteButton.isEnabled = !selectedIdentifiers.isEmpty && !isDeleting
    deleteButton.alpha = deleteButton.isEnabled ? 1 : 0.4
  }

  @objc private func beginSelection() {
    guard !isDeleting else { return }
    isSelecting = true
    selectionBar.isHidden = false
    selectionBarHeight.constant = 56
    updateNavigationActions()
    collectionView.reloadData()
  }

  @objc private func endSelection() {
    guard !isDeleting else { return }
    isSelecting = false
    selectedIdentifiers.removeAll()
    selectionBar.isHidden = true
    selectionBarHeight.constant = 0
    updateNavigationActions()
    collectionView.reloadData()
  }

  @objc private func toggleSelectAll() {
    let visibleIdentifiers = Set(filteredEntries.map { $0.item.id })
    if visibleIdentifiers.isSubset(of: selectedIdentifiers) {
      selectedIdentifiers.subtract(visibleIdentifiers)
    } else {
      selectedIdentifiers.formUnion(visibleIdentifiers)
    }
    collectionView.reloadData()
    updateSelectionActions()
  }

  @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
    guard gesture.state == .began, !isDeleting,
          let indexPath = collectionView.indexPathForItem(at: gesture.location(in: collectionView))
    else { return }
    if !isSelecting { beginSelection() }
    let identifier = filteredEntries[indexPath.item].item.id
    selectedIdentifiers.insert(identifier)
    collectionView.reloadItems(at: [indexPath])
    updateSelectionActions()
  }

  @objc private func confirmDeleteSelection() {
    guard !selectedIdentifiers.isEmpty, !isDeleting else { return }
    let count = selectedIdentifiers.count
    let confirmation = UIAlertController(
      title: "删除 \(count) 项水印成品？",
      message: "将从系统照片删除所选照片和视频；若启用了 iCloud 照片，删除也可能同步到其他设备。",
      preferredStyle: .alert
    )
    confirmation.addAction(UIAlertAction(title: "取消", style: .cancel))
    confirmation.addAction(UIAlertAction(title: "删除", style: .destructive) { [weak self] _ in
      self?.deleteSelection()
    })
    present(confirmation, animated: true)
  }

  private func deleteSelection() {
    let identifiers = Array(selectedIdentifiers)
    let fetched = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
    guard fetched.count == identifiers.count else {
      statusLabel.text = "所选项目有变化，请刷新图库后重试。"
      return
    }
    isDeleting = true
    updateSelectionActions()
    PHPhotoLibrary.shared().performChanges {
      PHAssetChangeRequest.deleteAssets(fetched)
    } completionHandler: { [weak self] succeeded, error in
      DispatchQueue.main.async {
        guard let self else { return }
        self.isDeleting = false
        guard succeeded else {
          self.statusLabel.text = "删除失败：\(error?.localizedDescription ?? "系统未完成删除。")"
          self.updateSelectionActions()
          return
        }
        let remaining = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        guard remaining.count == 0 else {
          self.statusLabel.text = "系统已处理删除请求，但无法确认所有项目均已删除；索引仍保留。"
          self.updateSelectionActions()
          return
        }
        do {
          for identifier in identifiers {
            try self.journal.removeFromIndex(id: identifier)
          }
          self.selectedIdentifiers.removeAll()
          self.reloadFromIndex()
          self.endSelection()
        } catch {
          self.reloadFromIndex()
          self.statusLabel.text = "系统照片已删除，索引更新失败：\(error.localizedDescription)"
          self.updateSelectionActions()
        }
      }
    }
  }

  @objc private func refreshGallery() {
    authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    if authorizationStatus == .authorized || authorizationStatus == .limited {
      reloadFromIndex()
    } else {
      requestGalleryAccessIfNeeded()
    }
  }

  @objc private func filterChanged() {
    applyFilter()
  }

  private func requestGalleryAccessIfNeeded() {
    authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    if authorizationStatus == .notDetermined {
      PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] status in
        DispatchQueue.main.async {
          guard let self else { return }
          self.authorizationStatus = status
          if status == .authorized || status == .limited {
            self.reloadFromIndex()
          } else {
            self.showPermissionRequired()
          }
        }
      }
      statusLabel.text = "正在请求照片图库权限…"
      return
    }
    if authorizationStatus == .authorized || authorizationStatus == .limited {
      reloadFromIndex()
    } else {
      showPermissionRequired()
    }
  }

  private func showPermissionRequired() {
    selectedIdentifiers.removeAll()
    if isSelecting { endSelection() }
    statusLabel.text = "需要允许水印相机读取照片，才能浏览已保存的水印成品。有限访问时，系统可能暂时隐藏部分项目。"
    collectionView.isHidden = true
    settingsButton.setTitle("打开系统设置", for: .normal)
    settingsButton.isHidden = false
  }

  @objc private func openSystemSettings() {
    guard let url = URL(string: UIApplication.openSettingsURLString) else {
      preconditionFailure("The iOS settings URL is invalid.")
    }
    UIApplication.shared.open(url)
  }

  private func reloadFromIndex() {
    do {
      let items = try journal.indexItems()
      settingsButton.isHidden = true
      let identifiers = items.map(\.id)
      let fetched = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
      var assetsByIdentifier: [String: PHAsset] = [:]
      fetched.enumerateObjects { asset, _, _ in
        assetsByIdentifier[asset.localIdentifier] = asset
      }
      if authorizationStatus == .authorized {
        for item in items where assetsByIdentifier[item.id] == nil {
          try journal.removeFromIndex(id: item.id)
        }
      }
      entries = items.compactMap { item in
        guard let asset = assetsByIdentifier[item.id] else { return nil }
        return WatermarkGalleryEntry(item: item, asset: asset)
      }
      hiddenLimitedItemCount = authorizationStatus == .limited
        ? max(0, items.count - entries.count)
        : 0
      if hiddenLimitedItemCount > 0 {
        settingsButton.setTitle("管理有限照片访问", for: .normal)
        settingsButton.isHidden = !entries.isEmpty
      }
      collectionView.isHidden = false
      applyFilter()
      if !isSelecting { updateNavigationActions() }
    } catch {
      collectionView.isHidden = true
      statusLabel.text = "图库读取失败：\(error.localizedDescription)"
    }
  }

  private func applyFilter() {
    switch filterControl.selectedSegmentIndex {
    case 0:
      filteredEntries = entries
    case 1:
      filteredEntries = entries.filter { $0.item.kind == "photo" }
    case 2:
      filteredEntries = entries.filter { $0.item.kind == "video" }
    default:
      preconditionFailure("The gallery filter index is invalid.")
    }
    collectionView.reloadData()
    countLabel.text = "作品  \(filteredEntries.count)"
    selectedIdentifiers.formIntersection(Set(entries.map { $0.item.id }))
    if isSelecting { updateSelectionActions() }
    if hiddenLimitedItemCount > 0 && filteredEntries.isEmpty {
      statusLabel.text = "有限照片访问隐藏了部分已登记项目。请在系统照片权限中扩大访问范围；索引已保留。"
    } else if filteredEntries.isEmpty {
      if authorizationStatus == .limited && entries.isEmpty {
        statusLabel.text = "当前没有可见项目。有限访问可能隐藏已登记内容，请在系统照片权限中扩大访问范围。"
      } else if entries.isEmpty {
        statusLabel.text = "这里还没有已保存的水印成品。"
      } else {
        statusLabel.text = "当前筛选没有水印成品。"
      }
    } else {
      statusLabel.text = nil
    }
  }
}

private final class WatermarkMediaPagerViewController: UIViewController,
  UIPageViewControllerDataSource,
  UIPageViewControllerDelegate
{
  private let journal: WatermarkMediaJournal
  private let onChange: () -> Void
  private let pageController: UIPageViewController
  private var entries: [WatermarkGalleryEntry]
  private var currentIndex: Int

  init(
    journal: WatermarkMediaJournal,
    entries: [WatermarkGalleryEntry],
    initialIndex: Int,
    onChange: @escaping () -> Void
  ) {
    precondition(!entries.isEmpty && entries.indices.contains(initialIndex))
    self.journal = journal
    self.entries = entries
    self.currentIndex = initialIndex
    self.onChange = onChange
    pageController = UIPageViewController(
      transitionStyle: .scroll,
      navigationOrientation: .horizontal
    )
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) {
    fatalError("WatermarkMediaPagerViewController does not support storyboard initialization.")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .black
    navigationItem.rightBarButtonItem = UIBarButtonItem(
      title: "删除",
      style: .plain,
      target: self,
      action: #selector(confirmDeleteCurrentItem)
    )
    navigationItem.rightBarButtonItem?.tintColor = .systemRed

    pageController.dataSource = self
    pageController.delegate = self
    pageController.view.backgroundColor = .black
    pageController.view.translatesAutoresizingMaskIntoConstraints = false
    addChild(pageController)
    view.addSubview(pageController.view)
    NSLayoutConstraint.activate([
      pageController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      pageController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      pageController.view.topAnchor.constraint(equalTo: view.topAnchor),
      pageController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    pageController.didMove(toParent: self)
    pageController.setViewControllers(
      [makeDetailPage(at: currentIndex)],
      direction: .forward,
      animated: false
    )
    updateNavigationTitle()
  }

  func pageViewController(
    _ pageViewController: UIPageViewController,
    viewControllerBefore viewController: UIViewController
  ) -> UIViewController? {
    let index = index(of: viewController)
    guard index > 0 else { return nil }
    return makeDetailPage(at: index - 1)
  }

  func pageViewController(
    _ pageViewController: UIPageViewController,
    viewControllerAfter viewController: UIViewController
  ) -> UIViewController? {
    let index = index(of: viewController)
    guard index + 1 < entries.count else { return nil }
    return makeDetailPage(at: index + 1)
  }

  func pageViewController(
    _ pageViewController: UIPageViewController,
    didFinishAnimating finished: Bool,
    previousViewControllers: [UIViewController],
    transitionCompleted completed: Bool
  ) {
    guard completed, let visiblePage = pageViewController.viewControllers?.first else {
      return
    }
    currentIndex = index(of: visiblePage)
    updateNavigationTitle()
  }

  @objc private func confirmDeleteCurrentItem() {
    guard let detail = pageController.viewControllers?.first
      as? WatermarkMediaDetailViewController
    else {
      preconditionFailure("The current gallery page is not a media detail page.")
    }
    detail.confirmDelete()
  }

  private func makeDetailPage(at index: Int) -> WatermarkMediaDetailViewController {
    guard entries.indices.contains(index) else {
      preconditionFailure("The requested gallery page is out of range.")
    }
    let entry = entries[index]
    return WatermarkMediaDetailViewController(
      journal: journal,
      item: entry.item,
      asset: entry.asset
    ) { [weak self] deletedIdentifier in
      self?.handleDeletedItem(identifier: deletedIdentifier)
    }
  }

  private func index(of viewController: UIViewController) -> Int {
    guard let detail = viewController as? WatermarkMediaDetailViewController,
          let index = entries.firstIndex(where: { $0.item.id == detail.mediaIdentifier })
    else {
      preconditionFailure("A gallery page is missing from the active media list.")
    }
    return index
  }

  private func updateNavigationTitle() {
    navigationItem.title = "\(currentIndex + 1) / \(entries.count)"
  }

  private func handleDeletedItem(identifier: String) {
    guard let deletedIndex = entries.firstIndex(where: { $0.item.id == identifier }),
          let currentPage = pageController.viewControllers?.first
            as? WatermarkMediaDetailViewController,
          currentPage.mediaIdentifier == identifier
    else {
      preconditionFailure("The deleted gallery item is not the active media page.")
    }
    entries.remove(at: deletedIndex)
    onChange()
    guard !entries.isEmpty else {
      navigationController?.popViewController(animated: true)
      return
    }

    currentIndex = min(deletedIndex, entries.count - 1)
    let direction: UIPageViewController.NavigationDirection =
      deletedIndex < entries.count ? .forward : .reverse
    pageController.setViewControllers(
      [makeDetailPage(at: currentIndex)],
      direction: direction,
      animated: false
    )
    updateNavigationTitle()
  }
}

private final class WatermarkMediaDetailViewController: UIViewController, UIScrollViewDelegate {
  private let journal: WatermarkMediaJournal
  private let item: WatermarkMediaIndexItem
  private let asset: PHAsset
  private let onChange: (String) -> Void
  private let scrollView = UIScrollView()
  private let imageView = UIImageView()
  private let statusLabel = UILabel()
  private var imageRequestID: PHImageRequestID?
  var mediaIdentifier: String { item.id }

  init(
    journal: WatermarkMediaJournal,
    item: WatermarkMediaIndexItem,
    asset: PHAsset,
    onChange: @escaping (String) -> Void
  ) {
    self.journal = journal
    self.item = item
    self.asset = asset
    self.onChange = onChange
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) {
    fatalError("WatermarkMediaDetailViewController does not support storyboard initialization.")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = item.kind == "video" ? "水印视频" : "水印照片"
    view.backgroundColor = .black
    statusLabel.textColor = .white
    statusLabel.textAlignment = .center
    statusLabel.numberOfLines = 0
    statusLabel.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(statusLabel)

    if item.kind == "photo" {
      scrollView.delegate = self
      scrollView.minimumZoomScale = 1
      scrollView.maximumZoomScale = 5
      scrollView.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview(scrollView)
      imageView.contentMode = .scaleAspectFit
      imageView.translatesAutoresizingMaskIntoConstraints = false
      scrollView.addSubview(imageView)
      NSLayoutConstraint.activate([
        scrollView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
        scrollView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
        scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
        scrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        imageView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
        imageView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
        imageView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
        imageView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
        imageView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
        imageView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
        statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        statusLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
        statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
      ])
      loadPhoto()
    } else {
      let playButton = UIButton(type: .system)
      playButton.setTitle("播放视频", for: .normal)
      playButton.titleLabel?.font = .systemFont(ofSize: 20, weight: .semibold)
      playButton.tintColor = .white
      playButton.addTarget(self, action: #selector(playVideo), for: .touchUpInside)
      playButton.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview(playButton)
      NSLayoutConstraint.activate([
        playButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        playButton.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        statusLabel.topAnchor.constraint(equalTo: playButton.bottomAnchor, constant: 20),
        statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
        statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
      ])
    }
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    if item.kind == "photo", let image = imageView.image {
      scrollView.contentSize = imageView.bounds.size
      let fitScale = min(
        scrollView.bounds.width / image.size.width,
        scrollView.bounds.height / image.size.height
      )
      scrollView.minimumZoomScale = max(0.1, fitScale)
      if scrollView.zoomScale < scrollView.minimumZoomScale {
        scrollView.zoomScale = scrollView.minimumZoomScale
      }
    }
  }

  func viewForZooming(in scrollView: UIScrollView) -> UIView? {
    imageView
  }

  @objc private func playVideo() {
    statusLabel.text = "正在读取视频…"
    let options = PHVideoRequestOptions()
    options.deliveryMode = .automatic
    options.isNetworkAccessAllowed = true
    options.progressHandler = { [weak self] _, error, _, _ in
      guard let error else { return }
      DispatchQueue.main.async {
        self?.statusLabel.text = "视频读取失败：\(error.localizedDescription)"
      }
    }
    PHImageManager.default().requestPlayerItem(forVideo: asset, options: options) {
      [weak self] playerItem, info in
      DispatchQueue.main.async {
        guard let self else { return }
        guard let playerItem else {
          let message = (info?[PHImageErrorKey] as? Error)?.localizedDescription
            ?? "视频暂时无法读取，请检查网络或 iCloud 状态。"
          self.statusLabel.text = message
          return
        }
        self.statusLabel.text = nil
        let playerController = AVPlayerViewController()
        playerController.player = AVPlayer(playerItem: playerItem)
        self.present(playerController, animated: true) {
          playerController.player?.play()
        }
      }
    }
  }

  func confirmDelete() {
    let confirmation = UIAlertController(
      title: "删除水印成品？",
      message: "将从系统照片删除此项目；若启用了 iCloud 照片，删除也可能同步到其他设备。",
      preferredStyle: .alert
    )
    confirmation.addAction(UIAlertAction(title: "取消", style: .cancel) { [weak self] _ in
      self?.statusLabel.text = "已取消删除。"
    })
    confirmation.addAction(UIAlertAction(title: "删除", style: .destructive) { [weak self] _ in
      self?.deleteAsset()
    })
    present(confirmation, animated: true)
  }

  private func deleteAsset() {
    let currentStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    guard currentStatus == .authorized || currentStatus == .limited else {
      statusLabel.text = "没有图库删除权限，项目仍保留在列表中。"
      return
    }
    let fetched = PHAsset.fetchAssets(withLocalIdentifiers: [item.id], options: nil)
    guard fetched.count == 1, let currentAsset = fetched.firstObject,
          currentAsset.localIdentifier == asset.localIdentifier
    else {
      statusLabel.text = "当前权限下无法确认此项目仍可见，索引已保留。"
      return
    }

    statusLabel.text = "正在请求系统确认删除…"
    PHPhotoLibrary.shared().performChanges {
      PHAssetChangeRequest.deleteAssets([currentAsset] as NSArray)
    } completionHandler: { [weak self] succeeded, error in
      DispatchQueue.main.async {
        guard let self else { return }
        guard succeeded else {
          self.statusLabel.text = "删除失败，项目仍保留：\(error?.localizedDescription ?? "系统未完成删除。")"
          return
        }
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        let remaining = PHAsset.fetchAssets(withLocalIdentifiers: [self.item.id], options: nil)
        guard (status == .authorized || status == .limited), remaining.count == 0 else {
          self.statusLabel.text = "系统已处理删除请求，但当前图库权限无法确认资产已不可见；应用索引已保留。"
          return
        }
        do {
          try self.journal.removeFromIndex(id: self.item.id)
          self.statusLabel.text = "已从系统照片和应用图库删除。"
          self.onChange(self.item.id)
        } catch {
          self.statusLabel.text = "系统照片已删除，应用索引将在下次刷新時清理：\(error.localizedDescription)"
        }
      }
    }
  }

  private func loadPhoto() {
    statusLabel.text = "正在读取照片…"
    let options = PHImageRequestOptions()
    options.deliveryMode = .highQualityFormat
    options.resizeMode = .exact
    options.isNetworkAccessAllowed = true
    options.progressHandler = { [weak self] _, error, _, _ in
      guard let error else { return }
      DispatchQueue.main.async {
        self?.statusLabel.text = "照片读取失败：\(error.localizedDescription)"
      }
    }
    imageRequestID = PHImageManager.default().requestImage(
      for: asset,
      targetSize: PHImageManagerMaximumSize,
      contentMode: .aspectFit,
      options: options
    ) { [weak self] image, info in
      DispatchQueue.main.async {
        guard let self else { return }
        if let image {
          self.imageView.image = image
          self.statusLabel.text = nil
          self.view.setNeedsLayout()
        } else if let error = info?[PHImageErrorKey] as? Error {
          self.statusLabel.text = "照片读取失败：\(error.localizedDescription)"
        } else {
          self.statusLabel.text = "照片暂时无法读取，请检查网络或 iCloud 状态。"
        }
      }
    }
  }
}
