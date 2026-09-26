// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import AVFoundation
import XCTest

@testable import camera_avfoundation

final class CameraZoomTests: XCTestCase {
  private func createCamera() -> (Camera, MockCaptureDevice) {
    let mockDevice = MockCaptureDevice()

    let configuration = CameraTestUtils.createTestCameraConfiguration()
    configuration.videoCaptureDeviceFactory = { _ in mockDevice }
    let camera = CameraTestUtils.createTestCamera(configuration)

    return (camera, mockDevice)
  }

  func testSetZoomLevel_setVideoZoomFactor() {
    let (camera, mockDevice) = createCamera()

    mockDevice.maxAvailableVideoZoomFactor = 2.0
    mockDevice.minAvailableVideoZoomFactor = 0.0

    let targetZoom = CGFloat(1.0)

    var setVideoZoomFactorCalled = false
    mockDevice.setVideoZoomFactorStub = { zoom in
      XCTAssertEqual(zoom, targetZoom)
      setVideoZoomFactorCalled = true
    }

    let expectation = expectation(description: "Call completed")

    camera.setZoomLevel(targetZoom) {
      result in
      let _ = self.assertSuccess(result)
      expectation.fulfill()
    }

    waitForExpectations(timeout: 30)

    XCTAssertTrue(setVideoZoomFactorCalled)
  }

  func testSetZoomLevel_returnsError_forZoomLevelBlowMinimum() {
    let (camera, mockDevice) = createCamera()

    // Allowed zoom range between 2.0 and 3.0
    mockDevice.maxAvailableVideoZoomFactor = 2.0
    mockDevice.minAvailableVideoZoomFactor = 3.0

    let expectation = expectation(description: "Call completed")

    camera.setZoomLevel(CGFloat(1.0)) { result in
      switch result {
      case .failure(let error as PigeonError):
        XCTAssertEqual(error.code, "ZOOM_ERROR")
      default:
        XCTFail("Expected failure")
      }
      expectation.fulfill()
    }

    waitForExpectations(timeout: 30)
  }

  func testSetZoomLevel_returnsError_forZoomLevelAboveMaximum() {
    let (camera, mockDevice) = createCamera()

    // Allowed zoom range between 0.0 and 1.0
    mockDevice.maxAvailableVideoZoomFactor = 0.0
    mockDevice.minAvailableVideoZoomFactor = 1.0

    let expectation = expectation(description: "Call completed")

    camera.setZoomLevel(CGFloat(2.0)) { result in
      switch result {
      case .failure(let error as PigeonError):
        XCTAssertEqual(error.code, "ZOOM_ERROR")
      default:
        XCTFail("Expected failure")
      }
      expectation.fulfill()
    }

    waitForExpectations(timeout: 30)
  }

  func testMaximumAvailableZoomFactor_returnsDeviceMaxAvailableVideoZoomFactor() {
    let (camera, mockDevice) = createCamera()

    let targetZoom = CGFloat(1.0)

    mockDevice.maxAvailableVideoZoomFactor = CGFloat(targetZoom)

    XCTAssertEqual(camera.maximumAvailableZoomFactor, targetZoom)
  }

  func testMinimumAvailableZoomFactor_returnsDeviceMinAvailableVideoZoomFactor() {
    let (camera, mockDevice) = createCamera()

    let targetZoom = CGFloat(1.0)

    mockDevice.minAvailableVideoZoomFactor = CGFloat(targetZoom)

    XCTAssertEqual(camera.minimumAvailableZoomFactor, targetZoom)
  }

  /// Configures a mock as a dual wide virtual device whose widest constituent lens is the ultra
  /// wide angle, as on an iPhone 11 and later.
  private func makeDualWideVirtualDevice(_ mockDevice: MockCaptureDevice) {
    let ultraWideDevice = MockCaptureDevice()
    ultraWideDevice.deviceType = .builtInUltraWideCamera

    mockDevice.flutterConstituentDevices = [ultraWideDevice]
    mockDevice.flutterVirtualSwitchOverZoomFactors = [2]
    mockDevice.minAvailableVideoZoomFactor = 1.0
    mockDevice.maxAvailableVideoZoomFactor = 8.0
  }

  func testZoomFactors_areRelativeToTheWideAngleLensOfAVirtualDevice() {
    let (camera, mockDevice) = createCamera()
    makeDualWideVirtualDevice(mockDevice)

    // Raw zoom factor 1.0 is the ultra wide angle lens, the wide angle lens starts at 2.0.
    XCTAssertEqual(camera.minimumAvailableZoomFactor, 0.5)
    XCTAssertEqual(camera.maximumAvailableZoomFactor, 4.0)
  }

  func testSetZoomLevel_scalesTheVirtualDeviceZoomLevelToTheDeviceZoomFactor() {
    let (camera, mockDevice) = createCamera()
    makeDualWideVirtualDevice(mockDevice)

    var appliedZoom: CGFloat?
    mockDevice.setVideoZoomFactorStub = { appliedZoom = $0 }

    let expectation = expectation(description: "Call completed")

    camera.setZoomLevel(0.5) { result in
      let _ = self.assertSuccess(result)
      expectation.fulfill()
    }

    waitForExpectations(timeout: 30)

    XCTAssertEqual(appliedZoom, CGFloat(1.0))
  }

  func testSetZoomLevel_returnsError_forAZoomLevelBelowTheVirtualDeviceUltraWideAngleLens() {
    let (camera, mockDevice) = createCamera()
    makeDualWideVirtualDevice(mockDevice)

    let expectation = expectation(description: "Call completed")

    camera.setZoomLevel(0.25) { result in
      switch result {
      case .failure(let error as PigeonError):
        XCTAssertEqual(error.code, "ZOOM_ERROR")
      default:
        XCTFail("Expected failure")
      }
      expectation.fulfill()
    }

    waitForExpectations(timeout: 30)
  }
}
