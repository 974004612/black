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
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
                .statusBarHidden(true)
        }
    }
}
