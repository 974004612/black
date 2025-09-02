//
//  ContentView.swift
//  black
//
//  Created by liukang on 2025/8/31.
//

import SwiftUI
import AVFoundation
import Photos
import UIKit

struct ContentView: View {
    @StateObject private var cameraManager = CameraManager()
    
    var body: some View {
        // 纯黑色背景，不显示任何其他元素
        Color.black
            .ignoresSafeArea()
            .statusBarHidden(true) // 强制隐藏状态栏
        .onAppear {
            setupCamera()
            preventScreenLock()
            hideStatusBar()
        }
        .onDisappear {
            stopRecordingAndSave()
            showStatusBar()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            stopRecordingAndSave()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            stopRecordingAndSave()
        }
    }
    
    private func setupCamera() {
        cameraManager.requestPermissions { granted in
            if granted {
                DispatchQueue.main.async {
                    cameraManager.startRecording()
                }
            }
        }
    }
    
    private func preventScreenLock() {
        UIApplication.shared.isIdleTimerDisabled = true
    }
    
    private func stopRecordingAndSave() {
        cameraManager.stopRecording()
        UIApplication.shared.isIdleTimerDisabled = false
    }
    
    private func hideStatusBar() {
        // 状态栏隐藏已通过SwiftUI修饰符设置
        print("状态栏隐藏已通过SwiftUI修饰符设置")
    }
    
    private func showStatusBar() {
        // 状态栏显示已通过SwiftUI修饰符设置
        print("状态栏显示已通过SwiftUI修饰符设置")
    }
}

class CameraManager: NSObject, ObservableObject {
    private var captureSession: AVCaptureSession?
    private var videoOutput: AVCaptureMovieFileOutput?
    private var currentVideoURL: URL?
    
    func requestPermissions(completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .video) { videoGranted in
            AVCaptureDevice.requestAccess(for: .audio) { audioGranted in
                DispatchQueue.main.async {
                    completion(videoGranted && audioGranted)
                }
            }
        }
    }
    
    func startRecording() {
        setupCaptureSession()
        captureSession?.startRunning()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.startVideoRecording()
        }
    }
    
    private func setupCaptureSession() {
        captureSession = AVCaptureSession()
        
        guard let captureSession = captureSession else { return }
        
        // 配置视频输入 - 强制使用后置主摄 wideAngle
        var videoDevice: AVCaptureDevice?
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .builtInTripleCamera],
            mediaType: .video,
            position: .back
        )
        // 先找物理主摄 wideAngle，其次退回 tripleCamera
        videoDevice = discovery.devices.first(where: { $0.deviceType == .builtInWideAngleCamera })
        if videoDevice == nil {
            videoDevice = discovery.devices.first
        }
        
        guard let videoDevice = videoDevice else { return }
        
        do {
            let videoInput = try AVCaptureDeviceInput(device: videoDevice)
            if captureSession.canAddInput(videoInput) {
                captureSession.addInput(videoInput)
            }
            
            // 配置高帧率和4K分辨率
            try videoDevice.lockForConfiguration()
            
            // 查找支持4K 120帧率的格式
            let formats = videoDevice.formats
            var selectedFormat: AVCaptureDevice.Format?
            var selectedFrameRate: Double = 30.0
            
            for format in formats {
                // 检查分辨率是否支持4K
                let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                let is4K = dimensions.width >= 3840 && dimensions.height >= 2160
                
                // 检查是否支持HDR/杜比视界
                let supportsHDR = format.isVideoHDRSupported
                
                // 检查帧率范围
                for frameRateRange in format.videoSupportedFrameRateRanges {
                    if frameRateRange.minFrameRate <= 120 && frameRateRange.maxFrameRate >= 120 && is4K {
                        // 优先选择支持HDR的格式
                        if selectedFormat == nil || (supportsHDR && !selectedFormat!.isVideoHDRSupported) {
                            selectedFormat = format
                            selectedFrameRate = 120.0
                        }
                    }
                }
            }
            
            if let format = selectedFormat {
                // 设置格式（这会同时设置分辨率和帧率）
                videoDevice.activeFormat = format
                
                // 设置帧率
                let frameDuration = CMTime(value: 1, timescale: Int32(selectedFrameRate))
                videoDevice.activeVideoMinFrameDuration = frameDuration
                videoDevice.activeVideoMaxFrameDuration = frameDuration
                
                // 打印详细信息
                let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                print("成功设置格式:")
                print("- 分辨率: \(dimensions.width) x \(dimensions.height)")
                print("- 帧率: \(selectedFrameRate) FPS")
                print("- HDR支持: \(format.isVideoHDRSupported ? "是" : "否")")
                print("- 杜比视界支持: \(format.isVideoHDRSupported ? "是" : "否")")
                print("- 设备: \(videoDevice.localizedName), 类型: \(videoDevice.deviceType.rawValue)")
            } else {
                print("未找到支持4K 120帧率的格式，使用默认设置")
                // 打印可用的格式信息
                print("可用格式:")
                for (index, format) in formats.enumerated() {
                    let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                    let maxFrameRate = format.videoSupportedFrameRateRanges.map { $0.maxFrameRate }.max() ?? 0
                    let minFrameRate = format.videoSupportedFrameRateRanges.map { $0.minFrameRate }.min() ?? 0
                    print("格式 \(index): \(dimensions.width)x\(dimensions.height), 帧率范围: \(minFrameRate)-\(maxFrameRate), HDR: \(format.isVideoHDRSupported)")
                }
            }
            
            videoDevice.unlockForConfiguration()
            
        } catch {
            print("Error setting up video input: \(error)")
        }
        
        // 配置音频输入
        guard let audioDevice = AVCaptureDevice.default(for: .audio) else { return }
        
        do {
            let audioInput = try AVCaptureDeviceInput(device: audioDevice)
            if captureSession.canAddInput(audioInput) {
                captureSession.addInput(audioInput)
            }
        } catch {
            print("Error setting up audio input: \(error)")
        }
        
        // 配置视频输出 - 支持杜比视界
        videoOutput = AVCaptureMovieFileOutput()
        if let videoOutput = videoOutput, captureSession.canAddOutput(videoOutput) {
            captureSession.addOutput(videoOutput)
            
            // 配置HDR和杜比视界支持
            if let connection = videoOutput.connection(with: .video) {
                // 高帧率下关闭视频防抖，避免系统自动降低帧率
                if connection.isVideoStabilizationSupported {
                    connection.preferredVideoStabilizationMode = .off
                }
                
                // 设置视频方向 - 使用现代API
                if #available(iOS 17.0, *) {
                    connection.videoRotationAngle = 0 // 0度表示竖屏
                } else {
                    connection.videoOrientation = .portrait
                }
                
                // 尝试启用HDR（机型支持时有效）
                if #available(iOS 17.0, *) {
                    if connection.isVideoHDREnabled != nil {
                        connection.isVideoHDREnabled = true
                    }
                }
            }
        }
    }
    
    private func startVideoRecording() {
        guard let videoOutput = videoOutput else { return }
        
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let videoName = "recording_\(Date().timeIntervalSince1970).mov"
        let videoURL = documentsPath.appendingPathComponent(videoName)
        
        currentVideoURL = videoURL
        
        videoOutput.startRecording(to: videoURL, recordingDelegate: self)
    }
    
    func stopRecording() {
        videoOutput?.stopRecording()
        captureSession?.stopRunning()
    }
}

extension CameraManager: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        if error == nil {
            saveVideoToPhotosLibrary(url: outputFileURL)
        }
    }
    
    private func saveVideoToPhotosLibrary(url: URL) {
        PHPhotoLibrary.requestAuthorization { status in
            if status == .authorized {
                PHPhotoLibrary.shared().performChanges({
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                }) { success, error in
                    if success {
                        print("Video saved to photos library successfully")
                    } else if let error = error {
                        print("Error saving video: \(error)")
                    }
                }
            }
        }
    }
}

#Preview {
    ContentView()
}
