//
//  blackApp.swift
//  black
//
//  Created by liukang on 2025/8/31.
//

import SwiftUI
import SwiftData

@main
struct blackApp: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Item.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            HostingController(rootView: ContentView())
        }
        .modelContainer(sharedModelContainer) // 如果不需要SwiftData，可以移除
    }
}
