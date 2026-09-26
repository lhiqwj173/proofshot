// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import AVFoundation
import XCTest

@testable import camera_avfoundation

final class AvailableCamerasTest: XCTestCase {
  private func createCameraPlugin(with deviceDiscoverer: MockCameraDeviceDiscoverer) -> CameraPlugin
  {
    return CameraPlugin(
      registry: MockFlutterTextureRegistry(),
      messenger: MockFlutterBinaryMessenger(),
      globalAPI: MockGlobalEventApi(),
      deviceDiscoverer: deviceDiscoverer,
      permissionManager: MockCameraPermissionManager(),
      deviceFactory: { _ in MockCaptureDevice() },
      captureSessionFactory: { MockCaptureSession() },
      captureDeviceInputFactory: MockCaptureDeviceInputFactory(),
      captureSessionQueue: DispatchQueue(label: "io.flutter.camera.captureSessionQueue")
    )
  }

  func testAvailableCamerasShouldReturnAllCamerasOnMultiCameraIPhone() {
    let mockDeviceDiscoverer = MockCameraDeviceDiscoverer()
    let cameraPlugin = createCameraPlugin(with: mockDeviceDiscoverer)
    let expectation = self.expectation(description: "Result finished")

    mockDeviceDiscoverer.discoverySessionStub = { deviceTypes, mediaType, position in
      // iPhone 13 Cameras:
      let wideAngleCamera = MockCaptureDevice()
      wideAngleCamera.uniqueID = "0"
      wideAngleCamera.position = .back

      let frontFacingCamera = MockCaptureDevice()
      frontFacingCamera.uniqueID = "1"
      frontFacingCamera.position = .front

      let ultraWideCamera = MockCaptureDevice()
      ultraWideCamera.uniqueID = "2"
      ultraWideCamera.position = .back

      let telephotoCamera = MockCaptureDevice()
      telephotoCamera.uniqueID = "3"
      telephotoCamera.position = .back

      var requiredTypes: [AVCaptureDevice.DeviceType] = [
        .builtInDualWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera,
        .builtInUltraWideCamera,
      ]
      var cameras = [wideAngleCamera, frontFacingCamera, telephotoCamera, ultraWideCamera]

      XCTAssertEqual(deviceTypes, requiredTypes)
      XCTAssertEqual(mediaType, .video)
      XCTAssertEqual(position, .unspecified)
      return cameras
    }

    var resultValue: [PlatformCameraDescription]?
    cameraPlugin.getAvailableCameras { result in
      resultValue = self.assertSuccess(result)
      expectation.fulfill()
    }
    waitForExpectations(timeout: 30, handler: nil)

    // Verify the result.
    XCTAssertEqual(resultValue?.count, 4)
  }

  func testAvailableCamerasShouldReturnTwoCamerasOnDualCameraIPhone() {
    let mockDeviceDiscoverer = MockCameraDeviceDiscoverer()
    let cameraPlugin = createCameraPlugin(with: mockDeviceDiscoverer)
    let expectation = self.expectation(description: "Result finished")

    mockDeviceDiscoverer.discoverySessionStub = { deviceTypes, mediaType, position in
      // iPhone 8 Cameras:
      let wideAngleCamera = MockCaptureDevice()
      wideAngleCamera.uniqueID = "0"
      wideAngleCamera.position = .back

      let frontFacingCamera = MockCaptureDevice()
      frontFacingCamera.uniqueID = "1"
      frontFacingCamera.position = .front

      var requiredTypes: [AVCaptureDevice.DeviceType] = [
        .builtInDualWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera,
        .builtInUltraWideCamera,
      ]
      let cameras = [wideAngleCamera, frontFacingCamera]

      XCTAssertEqual(deviceTypes, requiredTypes)
      XCTAssertEqual(mediaType, .video)
      XCTAssertEqual(position, .unspecified)
      return cameras
    }

    var resultValue: [PlatformCameraDescription]?
    cameraPlugin.getAvailableCameras { result in
      resultValue = self.assertSuccess(result)
      expectation.fulfill()
    }
    waitForExpectations(timeout: 30, handler: nil)

    // Verify the result.
    XCTAssertEqual(resultValue?.count, 2)
  }

  func testAvailableCamerasShouldReturnExternalLensDirectionForUnspecifiedCameraPosition() {
    let mockDeviceDiscoverer = MockCameraDeviceDiscoverer()
    let cameraPlugin = createCameraPlugin(with: mockDeviceDiscoverer)
    let expectation = self.expectation(description: "Result finished")

    mockDeviceDiscoverer.discoverySessionStub = { deviceTypes, mediaType, position in
      let unspecifiedCamera = MockCaptureDevice()
      unspecifiedCamera.uniqueID = "0"
      unspecifiedCamera.position = .unspecified

      var requiredTypes: [AVCaptureDevice.DeviceType] = [
        .builtInDualWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera,
        .builtInUltraWideCamera,
      ]
      let cameras = [unspecifiedCamera]

      XCTAssertEqual(deviceTypes, requiredTypes)
      XCTAssertEqual(mediaType, .video)
      XCTAssertEqual(position, .unspecified)
      return cameras
    }

    var resultValue: [PlatformCameraDescription]?
    cameraPlugin.getAvailableCameras { result in
      resultValue = self.assertSuccess(result)
      expectation.fulfill()
    }
    waitForExpectations(timeout: 30, handler: nil)

    XCTAssertEqual(resultValue?.first?.lensDirection, .external)
  }

  func testAvailableCamerasShouldReplacePhysicalBackLensesWithTheVirtualDualWideCamera() {
    let mockDeviceDiscoverer = MockCameraDeviceDiscoverer()
    let cameraPlugin = createCameraPlugin(with: mockDeviceDiscoverer)
    let expectation = self.expectation(description: "Result finished")

    mockDeviceDiscoverer.discoverySessionStub = { _, _, _ in
      // iPhone 11 Cameras:
      let wideAngleCamera = MockCaptureDevice()
      wideAngleCamera.uniqueID = "0"
      wideAngleCamera.position = .back
      wideAngleCamera.deviceType = .builtInWideAngleCamera

      let frontFacingCamera = MockCaptureDevice()
      frontFacingCamera.uniqueID = "1"
      frontFacingCamera.position = .front
      frontFacingCamera.deviceType = .builtInWideAngleCamera

      let ultraWideCamera = MockCaptureDevice()
      ultraWideCamera.uniqueID = "2"
      ultraWideCamera.position = .back
      ultraWideCamera.deviceType = .builtInUltraWideCamera

      let dualWideCamera = MockCaptureDevice()
      dualWideCamera.uniqueID = "3"
      dualWideCamera.position = .back
      dualWideCamera.deviceType = .builtInDualWideCamera

      return [wideAngleCamera, frontFacingCamera, ultraWideCamera, dualWideCamera]
    }

    var resultValue: [PlatformCameraDescription]?
    cameraPlugin.getAvailableCameras { result in
      resultValue = self.assertSuccess(result)
      expectation.fulfill()
    }
    waitForExpectations(timeout: 30, handler: nil)

    // The virtual device replaces the physical lenses it hands off between, while the front facing
    // camera and the telephoto camera are unaffected.
    XCTAssertEqual(resultValue?.map(\.name).sorted(), ["1", "3"])
    let virtualCamera = resultValue?.first { $0.name == "3" }
    XCTAssertEqual(virtualCamera?.lensDirection, .back)
    XCTAssertEqual(virtualCamera?.lensType, .wide)
  }
}
