//
//  NetworkAnalyzerApp.swift
//  NetworkAnalyzer
//
//  Main application entry point
//

import SwiftUI
import os.log

@main
struct NetworkAnalyzerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 800, minHeight: 500)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .help) {
                Button("NetworkAnalyzer Help") {
                    // Open help
                }
            }
        }

        Settings {
            SettingsView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private let log = Logger(subsystem: "com.safeme.NetworkAnalyzer", category: "AppDelegate")

    func applicationDidFinishLaunching(_ notification: Notification) {
        log.info("Application did finish launching")
        // Initialize managers
        _ = SystemExtensionManager.shared
        _ = FilterManager.shared
        _ = NetworkLogger.shared
        SystemExtensionManager.shared.refreshExtensionState()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        log.info("Application will terminate")
        // Cleanup
        NetworkLogger.shared.stopMonitoring()
    }
}
