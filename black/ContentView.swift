//
//  ContentView.swift
//  black
//
//  Created by liukang on 2025/8/31.
//

import SwiftUI
import SwiftData
import AVFoundation
import Photos
import UIKit
import CoreMedia  // 添加导入以支持CMTime

// 自定义HostingController来隐藏状态栏
class HostingController<Content: View>: UIHostingController<Content> {
    override var prefersStatusBarHidden: Bool {
        return true
    }
}

// 主视图
struct ContentView: View {
    @State private var captureSession: AVCaptureSession?
    @State private var movieOutput: AVCaptureMovieFileOutput?
    @State private var recordingURL: URL?
    @State private var isRecording = false
    @State private var hasSaved = false

    var body: some View {
        Color.black
            .ignoresSafeArea()
            .onAppear {
                setupCaptureSession()
                startRecording()
                UIApplication.shared.isIdleTimerDisabled = true // 防止自动锁屏
            }
            .onDisappear {
                stopRecordingAndSave()
                UIApplication.shared.isIdleTimerDisabled = false
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
                stopRecordingAndSave()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                if hasSaved {
                    // iOS不允许直接退出应用，这里可以重置或显示消息
                    // 为了模拟关闭，可以停止session并返回黑屏
                    captureSession?.stopRunning()
                }
            }
    }

    private func setupCaptureSession() {
        checkPermissions()

        let session = AVCaptureSession()
        session.beginConfiguration()

        // 设置预设为4K
        if session.canSetSessionPreset(.high) { // .high for best quality, but specify for 4K
            session.sessionPreset = .hd4K3840x2160
        }

        // 添加后置摄像头输入
        guard let backCamera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            print("无法访问后置摄像头")
            return
        }
        guard let input = try? AVCaptureDeviceInput(device: backCamera) else {
            print("无法创建输入")
            return
        }
        if session.canAddInput(input) {
            session.addInput(input)
        }

        // 配置设备为120 FPS, HDR
        do {
            try backCamera.lockForConfiguration()
            // 在setupCaptureSession中，确保HDR/Dolby Vision支持
            if let format = backCamera.formats.first(where: { fmt in
                fmt.videoSupportedFrameRateRanges.contains(where: { $0.maxFrameRate >= 120 })
                && fmt.isVideoHDRSupported  // 支持HDR，包括Dolby Vision如果可用
            }) {
                backCamera.activeFormat = format
                backCamera.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 120)  // 使用CMTime初始化
                backCamera.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 120)
            }
            backCamera.unlockForConfiguration()
        } catch {
            print("配置摄像头失败: \(error)")
        }

        // 添加麦克风输入
        guard let mic = AVCaptureDevice.default(for: .audio) else {
            print("无法访问麦克风")
            return
        }
        guard let micInput = try? AVCaptureDeviceInput(device: mic) else {
            print("无法创建麦克风输入")
            return
        }
        if session.canAddInput(micInput) {
            session.addInput(micInput)
        }

        // 添加电影输出
        let output = AVCaptureMovieFileOutput()
        if session.canAddOutput(output) {
            session.addOutput(output)
        }

        session.commitConfiguration()
        session.startRunning()

        captureSession = session
        movieOutput = output
    }

    private func checkPermissions() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                if !granted {
                    print("摄像头权限被拒绝")
                }
            }
        default:
            print("摄像头权限被拒绝")
            return
        }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                if !granted {
                    print("麦克风权限被拒绝")
                }
            }
        default:
            print("麦克风权限被拒绝")
            return
        }

        PHPhotoLibrary.requestAuthorization { status in
            if status != .authorized {
                print("相册权限被拒绝")
            }
        }
    }

    private func startRecording() {
        guard let output = movieOutput, !output.isRecording else { return }

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        output.startRecording(to: tempURL, recordingDelegate: self)
        recordingURL = tempURL
        isRecording = true
        hasSaved = false
    }

    private func stopRecordingAndSave() {
        guard let output = movieOutput, output.isRecording else { return }
        output.stopRecording()
        isRecording = false
    }
}

extension ContentView: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        if let error = error {
            print("录制错误: \(error)")
            return
        }

        PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: outputFileURL)
        } completionHandler: { success, error in
            if success {
                print("视频保存成功")
                self.hasSaved = true
                // 尝试清理临时文件
                try? FileManager.default.removeItem(at: outputFileURL)
            } else {
                print("保存失败: \(error?.localizedDescription ?? "未知错误")")
            }
        }
    }
}

// 修改Preview以使用自定义HostingController
#Preview {
    HostingController(rootView: ContentView())
}
