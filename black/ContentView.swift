//
//  ContentView.swift
//  black
//
//  Created by liukang on 2025/8/25.
//

import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var recordingManager = VideoRecordingManager()
    @StateObject private var appStateManager = AppStateManager()
    
    var body: some View {
        ZStack {
            // 纯黑色背景
            Color.black
                .ignoresSafeArea(.all)
            
            // 录制状态指示器（可选，用于调试）
            if recordingManager.isRecording {
                VStack {
                    Spacer()
                    HStack {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 10, height: 10)
                            .opacity(0.8)
                        Text(formatDuration(recordingManager.recordingDuration))
                            .foregroundColor(.white)
                            .font(.system(size: 12, family: .monospaced))
                            .opacity(0.7)
                        Spacer()
                    }
                    .padding(.bottom, 50)
                }
            }
        }
        .preferredColorScheme(.dark) // 强制深色模式
        .onAppear {
            // 进入界面后立即开始录制
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                recordingManager.startRecording()
            }
            
            // 设置防锁屏
            UIApplication.shared.isIdleTimerDisabled = true
            
            // 隐藏状态栏
            hideStatusBar()
        }
        .onDisappear {
            // 应用退出时保存视频
            if recordingManager.isRecording {
                recordingManager.stopRecording()
            }
            
            // 恢复锁屏设置
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            // 应用进入后台时保存视频
            if recordingManager.isRecording {
                recordingManager.stopRecording()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            // 应用重新激活时重新开始录制
            if !recordingManager.isRecording {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    recordingManager.startRecording()
                }
            }
        }
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
    
    private func hideStatusBar() {
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            windowScene.statusBarManager?.statusBarHidden = true
        }
    }
}

// MARK: - App State Manager
class AppStateManager: ObservableObject {
    @Published var isActive = true
    
    init() {
        setupNotifications()
    }
    
    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            self.isActive = false
        }
        
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            self.isActive = true
        }
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

#Preview {
    ContentView()
}
