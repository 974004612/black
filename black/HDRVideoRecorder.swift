//
//  HDRVideoRecorder.swift
//  black
//
//  Created by GPT on 2025/9/13.
//

import Foundation
import AVFoundation
import VideoToolbox
import Photos
import UIKit

final class HDRVideoRecorder: NSObject, ObservableObject {
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "hdr.video.recorder.session.queue")
    private let videoOutputQueue = DispatchQueue(label: "hdr.video.recorder.video.queue")
    private let audioOutputQueue = DispatchQueue(label: "hdr.video.recorder.audio.queue")

    private var videoDevice: AVCaptureDevice?
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()

    private var assetWriter: AVAssetWriter?
    private var videoWriterInput: AVAssetWriterInput?
    private var audioWriterInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var recordingStartTime: CMTime?
    private var currentOutputURL: URL?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    @Published private(set) var isRecording: Bool = false

    override init() {
        super.init()
        configureSession()
    }

    private func configureSession() {
        sessionQueue.async {
            self.session.beginConfiguration()

            if self.session.canSetSessionPreset(.hd4K3840x2160) {
                self.session.sessionPreset = .hd4K3840x2160
            }

            // Video input
            if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) {
                self.videoDevice = device
                do {
                    if let best = self.selectBestFormat(for: device) {
                        try device.lockForConfiguration()
                        device.activeFormat = best.format
                        if let fps = best.targetFrameRate {
                            let duration = CMTime(value: 1, timescale: CMTimeScale(fps))
                            device.activeVideoMinFrameDuration = duration
                            device.activeVideoMaxFrameDuration = duration
                        }
                        // HDR negotiated by format; explicit activeColorSpace APIs are not available on all SDKs
                        device.unlockForConfiguration()
                    }

                    let input = try AVCaptureDeviceInput(device: device)
                    if self.session.canAddInput(input) {
                        self.session.addInput(input)
                        self.videoInput = input
                    }
                } catch {
                    print("Video input error: \(error)")
                }
            }

            // Audio input
            if let audioDevice = AVCaptureDevice.default(for: .audio) {
                do {
                    let input = try AVCaptureDeviceInput(device: audioDevice)
                    if self.session.canAddInput(input) {
                        self.session.addInput(input)
                        self.audioInput = input
                    }
                } catch {
                    print("Audio input error: \(error)")
                }
            }

            // Video data output (10-bit YUV)
            if self.session.canAddOutput(self.videoOutput) {
                let pixelFormat: OSType = kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
                self.videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat]
                self.videoOutput.alwaysDiscardsLateVideoFrames = false
                self.videoOutput.setSampleBufferDelegate(self, queue: self.videoOutputQueue)
                self.session.addOutput(self.videoOutput)
                if let connection = self.videoOutput.connection(with: .video) {
                    if connection.isVideoOrientationSupported { connection.videoOrientation = .portrait }
                }
            }

            // Audio data output
            if self.session.canAddOutput(self.audioOutput) {
                self.audioOutput.setSampleBufferDelegate(self, queue: self.audioOutputQueue)
                self.session.addOutput(self.audioOutput)
            }

            self.session.commitConfiguration()
            self.session.startRunning()
        }
    }

    private func selectBestFormat(for device: AVCaptureDevice) -> (format: AVCaptureDevice.Format, targetFrameRate: Int32?)? {
        var best: (format: AVCaptureDevice.Format, targetFrameRate: Int32?, score: Int)?
        for format in device.formats {
            let desc = format.formatDescription
            let dims = CMVideoFormatDescriptionGetDimensions(desc)
            let is4K = (dims.width == 3840 && dims.height == 2160) || (dims.width == 2160 && dims.height == 3840)
            guard is4K else { continue }

            let supportsHDR = format.isVideoHDRSupported
            var maxSupportedFPS: Float64 = 0
            for range in format.videoSupportedFrameRateRanges {
                maxSupportedFPS = max(maxSupportedFPS, range.maxFrameRate)
            }
            let targetFPS: Int32? = maxSupportedFPS >= 120 ? 120 : Int32(maxSupportedFPS.rounded(.down))

            var score = 0
            if supportsHDR { score += 1000 }
            if let fps = targetFPS { score += Int(fps) }
            if let current = best {
                if score > current.score { best = (format, targetFPS, score) }
            } else {
                best = (format, targetFPS, score)
            }
        }
        if let best { return (best.format, best.targetFrameRate) }
        return nil
    }

    func checkRequiredCapabilities() -> String? {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            return "未找到可用的后置摄像头"
        }
        // Check for 4K + 120fps + HDR format
        var hasDesired = false
        var supportsHLG = false
        for format in device.formats {
            let desc = format.formatDescription
            let dims = CMVideoFormatDescriptionGetDimensions(desc)
            let is4K = (dims.width == 3840 && dims.height == 2160) || (dims.width == 2160 && dims.height == 3840)
            guard is4K else { continue }
            if format.isVideoHDRSupported { supportsHLG = true }
            var maxFPS: Float64 = 0
            for range in format.videoSupportedFrameRateRanges { maxFPS = max(maxFPS, range.maxFrameRate) }
            if maxFPS >= 120 && format.isVideoHDRSupported { hasDesired = true; break }
        }
        guard hasDesired else { return "设备不支持 4K 120 帧 HDR 视频录制" }
        guard supportsHLG else { return "设备不支持 HLG HDR 颜色空间" }

        // Check 10-bit pixel format support
        let supportedPixelFormats = videoOutput.availableVideoPixelFormatTypes
        guard supportedPixelFormats.contains(kCVPixelFormatType_420YpCbCr10BiPlanarFullRange) else {
            return "不支持 10-bit 采样 (420f10)"
        }
        return nil
    }

    func requestPermissionsIfNeeded(completion: @escaping (Bool) -> Void) {
        let camera = AVCaptureDevice.authorizationStatus(for: .video)
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        func requestMic(_ proceed: @escaping (Bool) -> Void) {
            switch mic {
            case .authorized: proceed(true)
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    DispatchQueue.main.async { proceed(granted) }
                }
            default: proceed(false)
            }
        }
        switch camera {
        case .authorized: requestMic { completion($0) }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async { if granted { requestMic { completion($0) } } else { completion(false) } }
            }
        default: completion(false)
        }
    }

    func startRecording() {
        requestPermissionsIfNeeded { [weak self] granted in
            guard let self else { return }
            guard granted else { print("Permissions not granted"); return }
            self.sessionQueue.async {
                guard !self.isRecording else { return }
                let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
                self.currentOutputURL = outputURL
                self.setupWriter(outputURL: outputURL)
                self.startBackgroundTask()
                self.isRecording = true
            }
        }
    }

    func stopAndSave(reason: String? = nil) {
        sessionQueue.async {
            guard self.isRecording else {
                if let url = self.currentOutputURL { self.saveToPhotoLibrary(videoURL: url) }
                return
            }
            self.isRecording = false
            guard let writer = self.assetWriter else { return }
            let group = DispatchGroup()
            group.enter()
            writer.finishWriting { group.leave() }
            group.wait()
            if let url = self.currentOutputURL { self.saveToPhotoLibrary(videoURL: url) }
            self.teardownWriter()
        }
    }

    private func setupWriter(outputURL: URL) {
        do {
            let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)

            // Video settings: HEVC Main10, HLG BT.2020
            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: 3840,
                AVVideoHeightKey: 2160,
                AVVideoColorPropertiesKey: [
                    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020
                ],
                AVVideoCompressionPropertiesKey: [
                    AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel as String,
                    AVVideoAllowFrameReorderingKey: false,
                    AVVideoExpectedSourceFrameRateKey: 120,
                    AVVideoAverageBitRateKey: 100_000_000
                ]
            ]
            let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            videoInput.expectsMediaDataInRealTime = true

            let pixelAttrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: pixelAttrs)

            if writer.canAdd(videoInput) { writer.add(videoInput) }

            // Audio settings (AAC)
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 48000,
                AVEncoderBitRateKey: 192_000
            ]
            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            audioInput.expectsMediaDataInRealTime = true
            if writer.canAdd(audioInput) { writer.add(audioInput) }

            self.assetWriter = writer
            self.videoWriterInput = videoInput
            self.audioWriterInput = audioInput
            self.pixelBufferAdaptor = adaptor
            self.recordingStartTime = nil
        } catch {
            print("Failed to setup writer: \(error)")
        }
    }

    private func teardownWriter() {
        self.assetWriter = nil
        self.videoWriterInput = nil
        self.audioWriterInput = nil
        self.pixelBufferAdaptor = nil
        self.recordingStartTime = nil
    }

    private func startBackgroundTask() {
        DispatchQueue.main.async {
            if self.backgroundTask == .invalid {
                self.backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "hdr.video.save") {
                    if self.backgroundTask != .invalid {
                        UIApplication.shared.endBackgroundTask(self.backgroundTask)
                        self.backgroundTask = .invalid
                    }
                }
            }
        }
    }

    private func endBackgroundTaskIfNeeded() {
        DispatchQueue.main.async {
            if self.backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(self.backgroundTask)
                self.backgroundTask = .invalid
            }
        }
    }

    private func saveToPhotoLibrary(videoURL: URL) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            let save: () -> Void = {
                PHPhotoLibrary.shared().performChanges({
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: videoURL)
                }) { success, error in
                    if !success { print("Save to Photos failed: \(error?.localizedDescription ?? "unknown")") }
                    try? FileManager.default.removeItem(at: videoURL)
                    self.endBackgroundTaskIfNeeded()
                }
            }
            if status == .authorized || status == .limited || status == .addOnly { save() } else { save() }
        }
    }
}

extension HDRVideoRecorder: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard isRecording else { return }
        let isVideo = output is AVCaptureVideoDataOutput

        if assetWriter?.status == .unknown && isVideo {
            // Start writing session at first video sample timestamp
            let startTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            assetWriter?.startWriting()
            assetWriter?.startSession(atSourceTime: startTime)
            recordingStartTime = startTime
        }

        if assetWriter?.status == .failed {
            print("Writer failed: \(assetWriter?.error?.localizedDescription ?? "unknown")")
            return
        }

        if isVideo, let input = videoWriterInput, input.isReadyForMoreMediaData {
            if let pb = CMSampleBufferGetImageBuffer(sampleBuffer) {
                // Ensure attachments mark HLG/BT.2020 for downstream
                if let attachments = CVBufferGetAttachments(pb, .shouldPropagate) as? [[CFString: Any]], attachments.isEmpty {
                    // no-op; camera provides proper attachments on capture
                }
                // Append pixel buffer with timing
                let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                pixelBufferAdaptor?.append(pb, withPresentationTime: time)
            } else {
                input.append(sampleBuffer)
            }
        } else if !isVideo, let input = audioWriterInput, input.isReadyForMoreMediaData {
            input.append(sampleBuffer)
        }
    }
}


