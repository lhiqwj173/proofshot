// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import AVFoundation
import XCTest

@testable import camera_avfoundation

/// Includes test cases related to the `start` method of the Camera class.
final class CameraStartTests: XCTestCase {
  func testStart_setsMaxPhotoDimensionsToTheLargestSupportedByTheActiveFormat() throws {
    guard #available(iOS 16.0, *) else {
      throw XCTSkip("maxPhotoDimensions requires iOS 16.")
    }

    let activeFormatMock = MockCaptureDeviceFormat()
    activeFormatMock.supportedMaxPhotoDimensions = [
      CMVideoDimensions(width: 1920, height: 1080),
      CMVideoDimensions(width: 4032, height: 3024),
      CMVideoDimensions(width: 3264, height: 2448),
    ]
    let captureDeviceMock = MockCaptureDevice()
    captureDeviceMock.activeFormatStub = { activeFormatMock }

    let configuration = CameraTestUtils.createTestCameraConfiguration()
    configuration.videoCaptureDeviceFactory = { _ in captureDeviceMock }
    let cam = CameraTestUtils.createTestCamera(configuration)

    let mockOutput = MockCapturePhotoOutput()
    cam.capturePhotoOutput = mockOutput

    cam.start()

    XCTAssertEqual(mockOutput.maxPhotoDimensions.width, 4032)
    XCTAssertEqual(mockOutput.maxPhotoDimensions.height, 3024)
  }

  func testStart_selectsTheWideAngleLensOfAVirtualDevice() {
    let ultraWideDevice = MockCaptureDevice()
    ultraWideDevice.deviceType = .builtInUltraWideCamera

    let captureDeviceMock = MockCaptureDevice()
    captureDeviceMock.flutterConstituentDevices = [ultraWideDevice]
    captureDeviceMock.flutterVirtualSwitchOverZoomFactors = [2]
    captureDeviceMock.minAvailableVideoZoomFactor = 1.0
    captureDeviceMock.maxAvailableVideoZoomFactor = 8.0

    var appliedZoom: CGFloat?
    captureDeviceMock.setVideoZoomFactorStub = { appliedZoom = $0 }

    let configuration = CameraTestUtils.createTestCameraConfiguration()
    configuration.videoCaptureDeviceFactory = { _ in captureDeviceMock }
    let cam = CameraTestUtils.createTestCamera(configuration)

    cam.start()

    // The device starts at the ultra wide angle lens, so `start` has to move it to the wide angle
    // lens that the reported zoom level 1.0 refers to.
    XCTAssertEqual(appliedZoom, CGFloat(2.0))
  }
}
