//
//  ContentView.swift
//  black
//
//  Created by liukang on 2025/8/31.
//

import SwiftUI
import SwiftData
import AVFoundation
import UIKit

struct BlackStatusBarStyle: ViewModifier {
    @State private var hidden: Bool = true
    func body(content: Content) -> some View {
        content
            .statusBarHidden(hidden)
    }
}

struct ContentView: View {
    @StateObject private var recorder = VideoRecorder()
    @Environment(\.scenePhase) private var scenePhase
    @State private var showCapabilityAlert: Bool = false
    @State private var capabilityMessage: String = ""

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            // Pure black screen; no controls
        }
        .modifier(BlackStatusBarStyle())
        .preferredColorScheme(.dark)
        .onAppear {
            if let error = recorder.checkRequiredCapabilities() {
                capabilityMessage = error
                showCapabilityAlert = true
                UIApplication.shared.isIdleTimerDisabled = false
            } else {
                UIApplication.shared.isIdleTimerDisabled = true
                recorder.startRecording()
            }
        }
        .onChange(of: scenePhase) { newPhase in
            switch newPhase {
            case .background, .inactive:
                // Save when app goes to background/lock
                recorder.stopAndSave(reason: "scenePhase \(newPhase)")
            case .active:
                // If user comes back after lock, close app automatically
                if !recorder.isRecording {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        UIApplication.shared.perform(#selector(NSXPCConnection.suspend))
                        exit(0)
                    }
                }
            @unknown default:
                break
            }
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .alert("不支持的录制模式", isPresented: $showCapabilityAlert) {
            Button("退出") {
                UIApplication.shared.perform(#selector(NSXPCConnection.suspend))
                exit(0)
            }
        } message: {
            Text(capabilityMessage)
        }
    }
}

#Preview {
    ContentView()
}
