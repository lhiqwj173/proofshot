// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import AVFoundation
import XCTest

@testable import camera_avfoundation

/// Includes test cases related to resolution presets setting operations for Camera class.
final class CameraSessionPresetsTests: XCTestCase {
  func testMaxWithoutAudioUsesPhotoPreset() throws {
    let videoSession = MockCaptureSession()
    let presetSet = expectation(description: "静态照片选择照片管线")
    videoSession.setSessionPresetStub = { preset in
      XCTAssertEqual(preset, .photo)
      presetSet.fulfill()
    }
    let configuration = CameraTestUtils.createTestCameraConfiguration()
    configuration.videoCaptureSession = videoSession
    configuration.mediaSettings = CameraTestUtils.createDefaultMediaSettings(
      resolutionPreset: .max)
    configuration.mediaSettings.enableAudio = false
    let camera = try DefaultCamera(configuration: configuration)
    XCTAssertEqual(camera.capturePhotoOutput.maxPhotoQualityPrioritization, .quality)
    waitForExpectations(timeout: 5, handler: nil)
  }

  func testMaxWithoutAudioRejectsUnsupportedPhotoPreset() {
    let videoSession = MockCaptureSession()
    videoSession.canSetSessionPresetStub = { $0 != .photo }
    let configuration = CameraTestUtils.createTestCameraConfiguration()
    configuration.videoCaptureSession = videoSession
    configuration.mediaSettings = CameraTestUtils.createDefaultMediaSettings(
      resolutionPreset: .max)
    configuration.mediaSettings.enableAudio = false
    XCTAssertThrowsError(try DefaultCamera(configuration: configuration))
  }

  func testResolutionPresetWithBestFormat_mustUpdateCaptureSessionPreset() {
    let expectedPreset = AVCaptureSession.Preset.inputPriority
    let presetExpectation = expectation(description: "Expected preset set")
    let lockForConfigurationExpectation = expectation(
      description: "Expected lockForConfiguration called")

    let videoSessionMock = MockCaptureSession()
    videoSessionMock.canSetSessionPresetStub = { _ in true }
    videoSessionMock.setSessionPresetStub = { preset in
      if preset == expectedPreset {
        presetExpectation.fulfill()
      }
    }
    let captureFormatMock = MockCaptureDeviceFormat()
    let captureDeviceMock = MockCaptureDevice()
    captureDeviceMock.flutterFormats = [captureFormatMock]
    var currentFormat: CaptureDeviceFormat = captureFormatMock
    captureDeviceMock.activeFormatStub = {
      return currentFormat
    }
    captureDeviceMock.lockForConfigurationStub = {
      lockForConfigurationExpectation.fulfill()
    }

    let configuration = CameraTestUtils.createTestCameraConfiguration()
    configuration.videoCaptureDeviceFactory = { _ in captureDeviceMock }
    configuration.videoDimensionsConverter = { _ in
      return CMVideoDimensions(width: 4, height: 3)
    }
    configuration.videoCaptureSession = videoSessionMock
    configuration.mediaSettings = CameraTestUtils.createDefaultMediaSettings(
      resolutionPreset: PlatformResolutionPreset.max)

    let _ = CameraTestUtils.createTestCamera(configuration)

    waitForExpectations(timeout: 30, handler: nil)
  }

  func testResolutionPresetWithCanSetSessionPresetMax_mustUpdateCaptureSessionPreset() {
    let expectedPreset = AVCaptureSession.Preset.hd4K3840x2160
    let expectation = self.expectation(description: "Expected preset set")

    let videoSessionMock = MockCaptureSession()
    // Make sure that setting resolution preset for session always succeeds.
    videoSessionMock.canSetSessionPresetStub = { _ in true }
    videoSessionMock.setSessionPresetStub = { preset in
      if preset == expectedPreset {
        expectation.fulfill()
      }
    }

    let configuration = CameraTestUtils.createTestCameraConfiguration()
    configuration.videoCaptureSession = videoSessionMock
    configuration.mediaSettings = CameraTestUtils.createDefaultMediaSettings(
      resolutionPreset: PlatformResolutionPreset.max)
    configuration.videoCaptureDeviceFactory = { _ in MockCaptureDevice() }

    let _ = CameraTestUtils.createTestCamera(configuration)

    waitForExpectations(timeout: 30, handler: nil)
  }

  func testResolutionPresetWithCanSetSessionPresetUltraHigh_mustUpdateCaptureSessionPreset() {
    let expectedPreset = AVCaptureSession.Preset.hd4K3840x2160
    let expectation = self.expectation(description: "Expected preset set")

    let videoSessionMock = MockCaptureSession()
    // Make sure that setting resolution preset for session always succeeds.
    videoSessionMock.canSetSessionPresetStub = { _ in true }
    // Expect that setting "ultraHigh" resolutionPreset correctly updates videoCaptureSession.
    videoSessionMock.setSessionPresetStub = { preset in
      if preset == expectedPreset {
        expectation.fulfill()
      }
    }

    let configuration = CameraTestUtils.createTestCameraConfiguration()
    configuration.videoCaptureSession = videoSessionMock
    configuration.mediaSettings = CameraTestUtils.createDefaultMediaSettings(
      resolutionPreset: PlatformResolutionPreset.ultraHigh)

    let _ = CameraTestUtils.createTestCamera(configuration)

    waitForExpectations(timeout: 30, handler: nil)
  }
}
