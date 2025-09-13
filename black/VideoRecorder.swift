//
//  VideoRecorder.swift
//  black
//
//  Created by GPT on 2025/9/13.
//

import Foundation
import AVFoundation
import Photos
import UIKit

final class VideoRecorder: NSObject, ObservableObject {
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "video.recorder.session.queue")

    private var videoDevice: AVCaptureDevice?
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private let movieOutput = AVCaptureMovieFileOutput()
    private(set) var usedFallbackCodec: Bool = false

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

            // Preset 4K
            if self.session.canSetSessionPreset(.hd4K3840x2160) {
                self.session.sessionPreset = .hd4K3840x2160
            }

            // Video input (back wide camera)
            if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) {
                self.videoDevice = device
                do {
                    // Find best format: 4K + prefer 60fps + HDR if available
                    if let bestFormat = self.selectBestFormat(for: device) {
                        try device.lockForConfiguration()
                        device.activeFormat = bestFormat.format
                        if let frameRate = bestFormat.targetFrameRate {
                            let duration = CMTime(value: 1, timescale: CMTimeScale(frameRate))
                            device.activeVideoMinFrameDuration = duration
                            device.activeVideoMaxFrameDuration = duration
                        }
                        // HDR will be negotiated automatically by the active format and codec
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

            // Movie output
            if self.session.canAddOutput(self.movieOutput) {
                self.session.addOutput(self.movieOutput)
                if let connection = self.movieOutput.connection(with: .video) {
                    if connection.isVideoOrientationSupported {
                        connection.videoOrientation = .portrait
                    }
                    if connection.isVideoStabilizationSupported {
                        connection.preferredVideoStabilizationMode = .off
                    }
                    // HDR is negotiated by active format and codec; no explicit toggle here
                    // Prefer HEVC; if unavailable, fall back to H.264 automatically
                    if self.movieOutput.availableVideoCodecTypes.contains(.hevc) {
                        self.movieOutput.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.hevc], for: connection)
                        self.usedFallbackCodec = false
                    } else if self.movieOutput.availableVideoCodecTypes.contains(.h264) {
                        self.movieOutput.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.h264], for: connection)
                        self.usedFallbackCodec = true
                    } else {
                        // Leave default; system will choose
                        self.usedFallbackCodec = true
                    }
                }
                // Prefer longer fragments to reduce overhead
                self.movieOutput.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
                self.movieOutput.maxRecordedFileSize = 0 // unlimited
            }

            self.session.commitConfiguration()

            // Prepare session
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

            // Prefer 60fps; if supported higher, cap at 60 for DV compatibility
            let targetFPS: Int32? = maxSupportedFPS >= 60 ? 60 : Int32(maxSupportedFPS.rounded(.down))

            // Scoring: prioritize HDR and 120fps
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

    /// Checks whether the device supports 4K (3840x2160), >=120 fps, and HDR (HLG) capture.
    /// Returns nil if supported; otherwise an error message.
    func checkRequiredCapabilities() -> String? {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            return "未找到可用的后置摄像头"
        }

        var supportsHLG = false
        var hasDesiredFormat = false

        for format in device.formats {
            let desc = format.formatDescription
            let dims = CMVideoFormatDescriptionGetDimensions(desc)
            let is4K = (dims.width == 3840 && dims.height == 2160) || (dims.width == 2160 && dims.height == 3840)
            guard is4K else { continue }
            guard format.isVideoHDRSupported else { continue }
            supportsHLG = true

            var maxFPS: Float64 = 0
            for range in format.videoSupportedFrameRateRanges {
                maxFPS = max(maxFPS, range.maxFrameRate)
            }
            if maxFPS >= 120 { hasDesiredFormat = true; break }
        }

        guard hasDesiredFormat else {
            return "设备不支持 4K 120 帧 HDR 视频录制"
        }
        guard supportsHLG else { return "设备不支持 HDR 视频录制" }
        // Do not hard-fail on lack of HEVC; we'll fall back to H.264 automatically
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
        case .authorized:
            requestMic { ok in completion(ok) }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if !granted { completion(false); return }
                    requestMic { ok in completion(ok) }
                }
            }
        default:
            completion(false)
        }
    }

    func startRecording() {
        requestPermissionsIfNeeded { [weak self] granted in
            guard let self else { return }
            guard granted else {
                print("Permissions not granted")
                return
            }
            self.sessionQueue.async {
                guard !self.movieOutput.isRecording else { return }
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
                self.currentOutputURL = url

                // Begin background task to ensure saving completes if app backgrounds
                self.startBackgroundTask()

                self.movieOutput.startRecording(to: url, recordingDelegate: self)
                DispatchQueue.main.async { self.isRecording = true }
            }
        }
    }

    func stopAndSave(reason: String? = nil) {
        sessionQueue.async {
            if self.movieOutput.isRecording {
                self.movieOutput.stopRecording()
            } else if let url = self.currentOutputURL { // In case of early stop
                self.saveToPhotoLibrary(videoURL: url)
            }
        }
    }

    private func startBackgroundTask() {
        DispatchQueue.main.async {
            if self.backgroundTask == .invalid {
                self.backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "video.save") {
                    // Expired
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
}

extension VideoRecorder: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        // noop
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        DispatchQueue.main.async { self.isRecording = false }
        if let error { print("Recording error: \(error)") }
        saveToPhotoLibrary(videoURL: outputFileURL)
    }

    private func saveToPhotoLibrary(videoURL: URL) {
        let urlToSave = videoURL
        // Ensure Photos permission to add
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            let saveBlock = {
                PHPhotoLibrary.shared().performChanges({
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: urlToSave)
                }) { success, error in
                    if !success { print("Save to Photos failed: \(error?.localizedDescription ?? "unknown")") }
                    // Cleanup temp file
                    try? FileManager.default.removeItem(at: urlToSave)
                    self.endBackgroundTaskIfNeeded()
                }
            }

            if status == .authorized || status == .limited {
                saveBlock()
            } else {
                // Try saving anyway (may fail), then end background task
                saveBlock()
            }
        }
    }
}


