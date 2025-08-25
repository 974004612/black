//
//  VideoRecordingManager.swift
//  black
//
//  Created by liukang on 2025/8/25.
//

import AVFoundation
import Photos
import UIKit

class VideoRecordingManager: NSObject, ObservableObject {
    
    // MARK: - Properties
    @Published var isRecording = false
    @Published var recordingDuration: TimeInterval = 0
    
    private var captureSession: AVCaptureSession?
    private var videoOutput: AVCaptureMovieFileOutput?
    private var audioOutput: AVCaptureAudioDataOutput?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    
    private var recordingTimer: Timer?
    private var recordingStartTime: Date?
    private var outputURL: URL?
    
    // MARK: - Setup
    override init() {
        super.init()
        setupCaptureSession()
    }
    
    private func setupCaptureSession() {
        captureSession = AVCaptureSession()
        
        guard let captureSession = captureSession else { return }
        
        // 设置高质量配置
        if captureSession.canSetSessionPreset(.hd4K3840x2160) {
            captureSession.sessionPreset = .hd4K3840x2160
        } else if captureSession.canSetSessionPreset(.high) {
            captureSession.sessionPreset = .high
        }
        
        // 配置视频输入
        setupVideoInput()
        
        // 配置音频输入
        setupAudioInput()
        
        // 配置视频输出
        setupVideoOutput()
    }
    
    private func setupVideoInput() {
        guard let captureSession = captureSession else { return }
        
        // 使用后置摄像头
        guard let backCamera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            print("无法获取后置摄像头")
            return
        }
        
        do {
            // 配置相机设置以支持高帧率和杜比视界
            try backCamera.lockForConfiguration()
            
            // 寻找支持 120fps 的格式
            if let format = findBestFormat(for: backCamera) {
                backCamera.activeFormat = format
                
                // 设置帧率为 120fps
                let desiredFrameRate = 120.0
                backCamera.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(desiredFrameRate))
                backCamera.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(desiredFrameRate))
            }
            
            // 启用杜比视界支持（如果可用）
            if backCamera.activeFormat.supportedColorSpaces.contains(.hlg_BT2020) {
                backCamera.activeColorSpace = .hlg_BT2020
            } else if backCamera.activeFormat.supportedColorSpaces.contains(.P3_D65) {
                backCamera.activeColorSpace = .P3_D65
            }
            
            backCamera.unlockForConfiguration()
            
            let videoInput = try AVCaptureDeviceInput(device: backCamera)
            if captureSession.canAddInput(videoInput) {
                captureSession.addInput(videoInput)
            }
        } catch {
            print("设置视频输入时出错: \(error)")
        }
    }
    
    private func setupAudioInput() {
        guard let captureSession = captureSession else { return }
        
        guard let audioDevice = AVCaptureDevice.default(for: .audio) else {
            print("无法获取音频设备")
            return
        }
        
        do {
            let audioInput = try AVCaptureDeviceInput(device: audioDevice)
            if captureSession.canAddInput(audioInput) {
                captureSession.addInput(audioInput)
            }
        } catch {
            print("设置音频输入时出错: \(error)")
        }
    }
    
    private func setupVideoOutput() {
        guard let captureSession = captureSession else { return }
        
        videoOutput = AVCaptureMovieFileOutput()
        
        guard let videoOutput = videoOutput else { return }
        
        if captureSession.canAddOutput(videoOutput) {
            captureSession.addOutput(videoOutput)
            
            // 配置视频编码设置以支持杜比视界
            if let connection = videoOutput.connection(with: .video) {
                if connection.isVideoStabilizationSupported {
                    connection.preferredVideoStabilizationMode = .cinematicExtended
                }
                
                // 设置视频方向
                if connection.isVideoOrientationSupported {
                    connection.videoOrientation = .portrait
                }
            }
            
            // 配置录制设置
            configureRecordingSettings()
        }
    }
    
    private func configureRecordingSettings() {
        guard let videoOutput = videoOutput else { return }
        
        // 设置最大录制时长（可选）
        videoOutput.maxRecordedDuration = CMTime.positiveInfinity
        
        // 设置文件大小限制（可选）
        videoOutput.maxRecordedFileSize = 0 // 无限制
    }
    
    private func findBestFormat(for device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        let formats = device.formats
        
        // 寻找支持 4K 和高帧率的格式
        for format in formats {
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let ranges = format.videoSupportedFrameRateRanges
            
            // 检查是否支持 4K 分辨率
            if dimensions.width >= 3840 && dimensions.height >= 2160 {
                // 检查是否支持 120fps
                for range in ranges {
                    if range.maxFrameRate >= 120.0 {
                        return format
                    }
                }
            }
        }
        
        // 如果没有找到 4K 120fps，寻找支持 120fps 的其他格式
        for format in formats {
            let ranges = format.videoSupportedFrameRateRanges
            for range in ranges {
                if range.maxFrameRate >= 120.0 {
                    return format
                }
            }
        }
        
        return nil
    }
    
    // MARK: - Recording Control
    func startRecording() {
        guard let captureSession = captureSession,
              let videoOutput = videoOutput,
              !isRecording else { return }
        
        // 检查权限
        checkPermissions { [weak self] granted in
            guard granted else {
                print("权限不足，无法开始录制")
                return
            }
            
            DispatchQueue.global(qos: .userInitiated).async {
                captureSession.startRunning()
                
                DispatchQueue.main.async {
                    // 生成输出文件URL
                    let outputURL = self?.generateOutputURL() ?? URL(fileURLWithPath: "")
                    self?.outputURL = outputURL
                    
                    // 开始录制
                    videoOutput.startRecording(to: outputURL, recordingDelegate: self!)
                    
                    self?.isRecording = true
                    self?.recordingStartTime = Date()
                    self?.startRecordingTimer()
                }
            }
        }
    }
    
    func stopRecording() {
        guard isRecording, let videoOutput = videoOutput else { return }
        
        videoOutput.stopRecording()
        captureSession?.stopRunning()
        
        isRecording = false
        stopRecordingTimer()
    }
    
    private func generateOutputURL() -> URL {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let fileName = "black_video_\(Date().timeIntervalSince1970).mov"
        return documentsPath.appendingPathComponent(fileName)
    }
    
    private func startRecordingTimer() {
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self, let startTime = self.recordingStartTime else { return }
            self.recordingDuration = Date().timeIntervalSince(startTime)
        }
    }
    
    private func stopRecordingTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
        recordingDuration = 0
    }
    
    // MARK: - Permissions
    private func checkPermissions(completion: @escaping (Bool) -> Void) {
        let cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
        let audioStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        
        switch cameraStatus {
        case .authorized:
            switch audioStatus {
            case .authorized:
                completion(true)
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    completion(granted)
                }
            default:
                completion(false)
            }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                if granted {
                    AVCaptureDevice.requestAccess(for: .audio) { audioGranted in
                        completion(audioGranted)
                    }
                } else {
                    completion(false)
                }
            }
        default:
            completion(false)
        }
    }
    
    // MARK: - Photo Library
    private func saveVideoToPhotoLibrary(url: URL) {
        PHPhotoLibrary.requestAuthorization { status in
            guard status == .authorized else {
                print("没有相册访问权限")
                return
            }
            
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }) { success, error in
                DispatchQueue.main.async {
                    if success {
                        print("视频已保存到相册")
                        // 删除临时文件
                        try? FileManager.default.removeItem(at: url)
                    } else {
                        print("保存视频到相册失败: \(error?.localizedDescription ?? "未知错误")")
                    }
                }
            }
        }
    }
    
    deinit {
        stopRecording()
    }
}

// MARK: - AVCaptureFileOutputRecordingDelegate
extension VideoRecordingManager: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        if let error = error {
            print("录制完成时出错: \(error)")
        } else {
            print("录制完成，正在保存到相册...")
            saveVideoToPhotoLibrary(url: outputFileURL)
        }
    }
}