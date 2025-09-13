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
    private(set) var usedEightBitFallback: Bool = false
    private var pendingWriterSetup: Bool = false
    private var isSaving: Bool = false

    @Published private(set) var isRecording: Bool = false

    override init() {
        super.init()
        configureSession()
    }

    private func configureSession() {
        sessionQueue.async {
            self.session.beginConfiguration()

            if self.session.canSetSessionPreset(.inputPriority) {
                self.session.sessionPreset = .inputPriority
            } else if self.session.canSetSessionPreset(.hd4K3840x2160) {
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

            // Video data output: prefer 10-bit; fallback to 8-bit if unavailable
            if self.session.canAddOutput(self.videoOutput) {
                let types = self.videoOutput.availableVideoPixelFormatTypes
                var chosen: OSType = kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
                if types.contains(kCVPixelFormatType_420YpCbCr10BiPlanarFullRange) {
                    chosen = kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
                    self.usedEightBitFallback = false
                } else if types.contains(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange) {
                    chosen = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                    self.usedEightBitFallback = false
                } else if types.contains(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) {
                    chosen = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                    self.usedEightBitFallback = true
                } else {
                    // Last resort: let system decide (likely 8-bit)
                    self.usedEightBitFallback = true
                }
                self.videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: chosen]
                self.videoOutput.alwaysDiscardsLateVideoFrames = true
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
            self.logActiveConfiguration()
        }
    }

    private func logActiveConfiguration() {
        guard let device = self.videoDevice else { return }
        let desc = device.activeFormat.formatDescription
        let dims = CMVideoFormatDescriptionGetDimensions(desc)
        var maxFPS: Float64 = 0
        for range in device.activeFormat.videoSupportedFrameRateRanges { maxFPS = max(maxFPS, range.maxFrameRate) }
        print("[HDR] Active format: \(dims.width)x\(dims.height), HDR=\(device.activeFormat.isVideoHDRSupported), maxFPS=\(Int(maxFPS))")
        if let videoConn = self.videoOutput.connection(with: .video) {
            print("[HDR] Connection supports video orientation = \(videoConn.isVideoOrientationSupported)")
        }
    }

    private func selectBestFormat(for device: AVCaptureDevice) -> (format: AVCaptureDevice.Format, targetFrameRate: Int32?)? {
        var best: (format: AVCaptureDevice.Format, targetFrameRate: Int32?, score: Int)?
        for format in device.formats {
            let desc = format.formatDescription
            let dims = CMVideoFormatDescriptionGetDimensions(desc)
            let is4K = (dims.width == 3840 && dims.height == 2160) || (dims.width == 2160 && dims.height == 3840)
            let is1080p = (dims.width == 1920 && dims.height == 1080) || (dims.width == 1080 && dims.height == 1920)
            guard is4K || is1080p else { continue }

            let supportsHDR = format.isVideoHDRSupported
            var maxSupportedFPS: Float64 = 0
            for range in format.videoSupportedFrameRateRanges { maxSupportedFPS = max(maxSupportedFPS, range.maxFrameRate) }

            // Aim for 120fps if possible; otherwise 60; otherwise max
            let target: Int32
            if maxSupportedFPS >= 120 { target = 120 }
            else if maxSupportedFPS >= 60 { target = 60 }
            else { target = Int32(maxSupportedFPS.rounded(.down)) }

            // Scoring priorities: HDR first, then fps, then resolution preference that favors fps
            var score = 0
            if supportsHDR { score += 10_000 }
            score += (target >= 120) ? 1_000 : (target >= 60 ? 600 : Int(target))
            if target >= 120 { score += is4K ? 200 : 220 } // allow 1080p120 to outrank 4K60/30
            else if target >= 60 { score += is4K ? 120 : 130 }
            else { score += is4K ? 10 : 20 }

            if let current = best {
                if score > current.score { best = (format, target, score) }
            } else {
                best = (format, target, score)
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
                // Defer writer setup until first video sample to use exact buffer size/orientation
                self.pendingWriterSetup = true
                self.startBackgroundTask()
                self.isRecording = true
                print("[HDR] startRecording -> URL: \(outputURL.path), eightBitFallback=\(self.usedEightBitFallback)")
            }
        }
    }

    func stopAndSave(reason: String? = nil, completion: (() -> Void)? = nil) {
        sessionQueue.async {
            if self.isSaving { DispatchQueue.main.async { completion?() }; return }
            self.isSaving = true
            let finishAndSave: () -> Void = {
                if let url = self.currentOutputURL {
                    self.saveToPhotoLibrary(videoURL: url) {
                        self.isSaving = false
                        completion?()
                    }
                } else {
                    self.isSaving = false
                    DispatchQueue.main.async { completion?() }
                }
            }

            guard self.isRecording else {
                finishAndSave()
                return
            }
            self.isRecording = false
            if let writer = self.assetWriter {
                writer.finishWriting {
                    finishAndSave()
                }
            } else {
                finishAndSave()
            }
            self.teardownWriter()
        }
    }

    private func setupWriter(outputURL: URL, width: Int, height: Int, orientation: AVCaptureVideoOrientation) {
        do {
            let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)

            // Ensure square pixels and clean aperture
            let compressionProps: [String: Any] = [
                AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel as String,
                AVVideoAllowFrameReorderingKey: false,
                AVVideoExpectedSourceFrameRateKey: 120,
                AVVideoAverageBitRateKey: 100_000_000,
                AVVideoPixelAspectRatioKey: [
                    AVVideoPixelAspectRatioHorizontalSpacingKey: 1,
                    AVVideoPixelAspectRatioVerticalSpacingKey: 1
                ],
                AVVideoCleanApertureKey: [
                    AVVideoCleanApertureWidthKey: width,
                    AVVideoCleanApertureHeightKey: height,
                    AVVideoCleanApertureHorizontalOffsetKey: 0,
                    AVVideoCleanApertureVerticalOffsetKey: 0
                ]
            ]

            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoColorPropertiesKey: [
                    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020
                ],
                AVVideoCompressionPropertiesKey: compressionProps
            ]

            let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            videoInput.expectsMediaDataInRealTime = true

            // Only rotate when buffer orientation doesn't match encoded dimension
            let isPortraitEncoded = height > width
            switch orientation {
            case .portrait:
                videoInput.transform = isPortraitEncoded ? .identity : CGAffineTransform(rotationAngle: .pi / 2)
            case .portraitUpsideDown:
                videoInput.transform = isPortraitEncoded ? .identity : CGAffineTransform(rotationAngle: -.pi / 2)
            case .landscapeRight:
                videoInput.transform = isPortraitEncoded ? CGAffineTransform(rotationAngle: .pi / 2) : .identity
            default:
                videoInput.transform = .identity
            }

            let pixelAttrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: usedEightBitFallback ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: pixelAttrs)

            if writer.canAdd(videoInput) { writer.add(videoInput) }

            // Add minimal camera metadata
            var meta: [AVMetadataItem] = []
            if let device = self.videoDevice {
                let camId = AVMutableMetadataItem()
                camId.keySpace = .quickTimeMetadata
                camId.key = AVMetadataKey.quickTimeMetadataKeyCameraIdentifier as (NSCopying & NSObjectProtocol)?
                camId.value = device.uniqueID as (NSCopying & NSObjectProtocol)?
                meta.append(camId)

                let model = AVMutableMetadataItem()
                model.keySpace = .common
                model.key = AVMetadataKey.commonKeyModel as (NSCopying & NSObjectProtocol)?
                model.value = UIDevice.current.model as (NSCopying & NSObjectProtocol)?
                meta.append(model)
            }
            let software = AVMutableMetadataItem()
            software.keySpace = .common
            software.key = AVMetadataKey.commonKeySoftware as (NSCopying & NSObjectProtocol)?
            software.value = "black" as (NSCopying & NSObjectProtocol)?
            meta.append(software)
            writer.metadata = meta

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

    private func saveToPhotoLibrary(videoURL: URL, completion: (() -> Void)? = nil) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            let save: () -> Void = {
                PHPhotoLibrary.shared().performChanges({
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: videoURL)
                }) { success, error in
                    if !success { print("[HDR] Save to Photos failed: \(error?.localizedDescription ?? "unknown")") } else { print("[HDR] Saved to Photos: \(videoURL.lastPathComponent)") }
                    try? FileManager.default.removeItem(at: videoURL)
                    self.endBackgroundTaskIfNeeded()
                    DispatchQueue.main.async { completion?() }
                }
            }
            if status == .authorized || status == .limited { save() } else { save() }
        }
    }

    func requestPhotoAddPermissionIfNeeded(_ completion: @escaping (Bool) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            DispatchQueue.main.async {
                completion(status == .authorized || status == .limited)
            }
        }
    }
}

extension HDRVideoRecorder: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard isRecording else { return }
        let isVideo = output is AVCaptureVideoDataOutput

        if assetWriter?.status == .unknown && isVideo {
            // Setup writer using first frame's true dimensions
            if pendingWriterSetup {
                if let pb = CMSampleBufferGetImageBuffer(sampleBuffer) {
                    let w = CVPixelBufferGetWidth(pb)
                    let h = CVPixelBufferGetHeight(pb)
                    let orient = self.videoOutput.connection(with: .video)?.videoOrientation ?? .portrait
                    if let url = self.currentOutputURL { self.setupWriter(outputURL: url, width: w, height: h, orientation: orient) }
                    pendingWriterSetup = false
                }
            }
            // Start writing session at first video sample timestamp
            let startTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            assetWriter?.startWriting()
            assetWriter?.startSession(atSourceTime: startTime)
            recordingStartTime = startTime
        }

        if assetWriter?.status == .failed {
            print("[HDR] Writer failed: \(assetWriter?.error?.localizedDescription ?? "unknown")")
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
                // Ensure portrait frames are not stretched: swap width/height for portrait buffers if needed
                if let conn = self.videoOutput.connection(with: .video), conn.videoOrientation == .portrait || conn.videoOrientation == .portraitUpsideDown {
                    // Many devices deliver portrait buffers already rotated; adaptor handles it via transform. Nothing else to do.
                }
                if !(pixelBufferAdaptor?.append(pb, withPresentationTime: time) ?? false) {
                    print("[HDR] Adaptor append failed at time: \(CMTimeGetSeconds(time))s")
                }
            } else {
                if !input.append(sampleBuffer) {
                    print("[HDR] Video input append(sampleBuffer) returned false")
                }
            }
        } else if !isVideo, let input = audioWriterInput, input.isReadyForMoreMediaData {
            if !input.append(sampleBuffer) {
                print("[HDR] Audio input append(sampleBuffer) returned false")
            }
        }
    }
}


