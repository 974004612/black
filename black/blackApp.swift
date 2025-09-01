//
//  blackApp.swift
//  black
//
//  Created by liukang on 2025/8/31.
//

import SwiftUI
import AVFoundation

@main
struct blackApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .statusBarHidden(true) // 全局隐藏状态栏
        }
        .windowStyle(HiddenTitleBarWindowStyle()) // 隐藏标题栏
    }
}

// 隐藏标题栏的窗口样式
struct HiddenTitleBarWindowStyle: WindowStyle {
    func body(configuration: Configuration) -> some Scene {
        configuration
            .defaultSize(width: .infinity, height: .infinity)
    }
}
