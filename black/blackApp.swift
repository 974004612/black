//
//  blackApp.swift
//  black
//
//  Created by liukang on 2025/8/25.
//

import SwiftUI
import UIKit

@main
struct blackApp: App {
    
    init() {
        // 全局设置隐藏状态栏
        setupStatusBarHiding()
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
                .statusBarHidden(true)
        }
    }
    
    private func setupStatusBarHiding() {
        // 设置全局状态栏隐藏
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            windowScene.statusBarManager?.statusBarHidden = true
        }
    }
}
