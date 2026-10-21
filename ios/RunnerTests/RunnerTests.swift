import Flutter
import AVFoundation
import UIKit
import XCTest
import camera_avfoundation
@testable import Runner

class RunnerTests: XCTestCase {

  func testRealtimeFrameTimingAcceptsVariableFrameRate() throws {
    try WatermarkBridge.verifyVideoFrameTiming(
      nominalFrameRate: 29.6, minFrameDuration: CMTime(value: 1, timescale: 30),
      requiresConstantFrameRate: false)
    try WatermarkBridge.verifyVideoFrameTiming(
      nominalFrameRate: 28, minFrameDuration: CMTime(value: 1, timescale: 30),
      requiresConstantFrameRate: false)
  }

  func testConstantFrameRateExportStillRequires30fps() throws {
    XCTAssertThrowsError(try WatermarkBridge.verifyVideoFrameTiming(
      nominalFrameRate: 29.6, minFrameDuration: CMTime(value: 1, timescale: 30),
      requiresConstantFrameRate: true))
    try WatermarkBridge.verifyVideoFrameTiming(
      nominalFrameRate: 30, minFrameDuration: CMTime(value: 1, timescale: 30),
      requiresConstantFrameRate: true)
  }

  func testRealtimeFrameTimingRejectsInvalidTracks() {
    let rates: [Float] = [0, -1, .nan, .infinity]
    for rate in rates {
      XCTAssertThrowsError(try WatermarkBridge.verifyVideoFrameTiming(
        nominalFrameRate: rate, minFrameDuration: CMTime(value: 1, timescale: 30),
        requiresConstantFrameRate: false))
    }
    for duration in [CMTime.zero, .invalid, .indefinite, CMTime(value: -1, timescale: 30)] {
      XCTAssertThrowsError(try WatermarkBridge.verifyVideoFrameTiming(
        nominalFrameRate: 30, minFrameDuration: duration,
        requiresConstantFrameRate: false))
    }
  }

  func testMP4WatermarkReceiptSurvivesWriting() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("receipt-test-\(UUID().uuidString).mp4")
    addTeardownBlock {
      if FileManager.default.fileExists(atPath: url.path) {
        try FileManager.default.removeItem(at: url)
      }
    }
    let token = "proofshot.realtime.v1:" + String(repeating: "a", count: 64)
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    writer.metadata = [ProofshotRealtimeWatermark.receiptMetadata(token: token)]
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
      AVVideoCodecKey: AVVideoCodecType.h264,
      AVVideoWidthKey: 64, AVVideoHeightKey: 64,
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
      sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: 64,
        kCVPixelBufferHeightKey as String: 64,
      ])
    XCTAssertTrue(writer.canAdd(input))
    writer.add(input)
    XCTAssertTrue(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    let pool = try XCTUnwrap(adaptor.pixelBufferPool)
    var buffer: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer), kCVReturnSuccess)
    let frame = try XCTUnwrap(buffer)
    XCTAssertEqual(CVPixelBufferLockBaseAddress(frame, []), kCVReturnSuccess)
    let address = try XCTUnwrap(CVPixelBufferGetBaseAddress(frame))
    memset(address, 0, CVPixelBufferGetBytesPerRow(frame) * CVPixelBufferGetHeight(frame))
    XCTAssertEqual(CVPixelBufferUnlockBaseAddress(frame, []), kCVReturnSuccess)
    XCTAssertTrue(adaptor.append(frame, withPresentationTime: .zero))
    writer.endSession(atSourceTime: CMTime(value: 1, timescale: 30))
    input.markAsFinished()
    let finished = expectation(description: "MP4 写入完成")
    writer.finishWriting { finished.fulfill() }
    wait(for: [finished], timeout: 10)
    XCTAssertEqual(writer.status, .completed, "\(String(describing: writer.error))")
    let asset = AVURLAsset(url: url)
    let receipts = AVMetadataItem.metadataItems(from: asset.commonMetadata,
      filteredByIdentifier: .commonIdentifierDescription)
    XCTAssertEqual(receipts.count, 1)
    XCTAssertEqual(receipts.first?.stringValue, token)
  }

}
