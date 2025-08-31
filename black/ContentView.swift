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
    @State private var isRecording = false
    
    var body: some View {
        ZStack {
            // 纯黑色背景
            Color.black
                .ignoresSafeArea()
            
            // 录制状态指示器
            VStack {
                Spacer()
                
                HStack {
                    // 录制状态圆点
                    Circle()
                        .fill(isRecording ? Color.red : Color.gray)
                        .frame(width: 20, height: 20)
                        .scaleEffect(isRecording ? 1.2 : 1.0)
                        .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: isRecording)
                    
                    Text(isRecording ? "录制中..." : "准备录制")
                        .foregroundColor(.white)
                        .font(.headline)
                }
                .padding(.bottom, 50)
            }
        }
        .onAppear {
            setupCamera()
            preventScreenLock()
        }
        .onDisappear {
            stopRecordingAndSave()
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
                    isRecording = true
                }
            }
        }
    }
    
    private func preventScreenLock() {
        UIApplication.shared.isIdleTimerDisabled = true
    }
    
    private func stopRecordingAndSave() {
        if isRecording {
            cameraManager.stopRecording()
            isRecording = false
        }
        UIApplication.shared.isIdleTimerDisabled = false
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
        
        // 设置4K分辨率
        captureSession?.sessionPreset = .hd4K3840x2160
        
        guard let captureSession = captureSession else { return }
        
        // 配置视频输入
        guard let videoDevice = AVCaptureDevice.default(.builtInTripleCamera, for: .video, position: .back) else { return }
        
        do {
            let videoInput = try AVCaptureDeviceInput(device: videoDevice)
            if captureSession.canAddInput(videoInput) {
                captureSession.addInput(videoInput)
            }
            
            // 配置120帧率
            try videoDevice.lockForConfiguration()
            if videoDevice.isFrameRateSupported(120) {
                videoDevice.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 120)
                videoDevice.activeInput = videoInput
                videoDevice.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 120)
                videoDevice.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 120)
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
        
        // 配置视频输出
        videoOutput = AVCaptureMovieFileOutput()
        if let videoOutput = videoOutput, captureSession.canAddOutput(videoOutput) {
            captureSession.addOutput(videoOutput)
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
