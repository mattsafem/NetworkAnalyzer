//
//  ContentView.swift
//  NetworkAnalyzer
//
//  Main application view with tab-based navigation
//

import SwiftUI
import os.log

enum AppTab: String, CaseIterable {
    case status = "Status"
    case logs = "Logs"
    case settings = "Settings"

    var icon: String {
        switch self {
        case .status: return "shield.checkered"
        case .logs: return "list.bullet.rectangle"
        case .settings: return "gearshape"
        }
    }
}

struct ContentView: View {
    @StateObject private var extensionManager = SystemExtensionManager.shared
    @StateObject private var filterManager = FilterManager.shared
    @StateObject private var logger = NetworkLogger.shared

    @State private var selectedTab: AppTab = .status
    private let log = Logger(subsystem: "com.safeme.NetworkAnalyzer", category: "ContentView")

    var body: some View {
        NavigationSplitView {
            // Sidebar
            List(AppTab.allCases, id: \.self, selection: $selectedTab) { tab in
                Label(tab.rawValue, systemImage: tab.icon)
            }
            .listStyle(.sidebar)
            .frame(minWidth: 150)
        } detail: {
            // Main Content
            VStack(spacing: 0) {
                switch selectedTab {
                case .status:
                    FilterStatusView(
                        extensionManager: extensionManager,
                        filterManager: filterManager
                    )
                    .padding()

                case .logs:
                    ConnectionLogView(logger: logger)

                case .settings:
                    SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                HStack(spacing: 8) {
                    statusIndicator
                    Text("NetworkAnalyzer")
                        .fontWeight(.semibold)
                }
            }

            ToolbarItem(placement: .automatic) {
                Button {
                    filterManager.loadCurrentConfiguration()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh Status")
            }
        }
        .onAppear {
            log.info("ContentView appeared")
            filterManager.loadCurrentConfiguration()
            updateMonitoringState()
        }
        .onChange(of: filterManager.state) { _, _ in
            log.info("Filter state changed to \(String(describing: filterManager.state), privacy: .public)")
            updateMonitoringState()
        }
        .onChange(of: extensionManager.state) { _, _ in
            log.info("System extension state changed to \(String(describing: extensionManager.state), privacy: .public)")
            updateMonitoringState()
        }
        .onChange(of: selectedTab) { _, newValue in
            log.info("Selected tab changed to \(newValue.rawValue, privacy: .public)")
        }
    }

    @ViewBuilder
    private var statusIndicator: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 10, height: 10)
            .overlay {
                if extensionManager.state == .activating || filterManager.state == .configuring {
                    Circle()
                        .stroke(statusColor.opacity(0.5), lineWidth: 2)
                        .scaleEffect(1.5)
                        .opacity(0.5)
                }
            }
    }

    private var statusColor: Color {
        if filterManager.state.isEnabled && extensionManager.state.isActive {
            return .green
        } else if case .error = filterManager.state {
            return .red
        } else if case .failed = extensionManager.state {
            return .red
        } else {
            return .orange
        }
    }

    private func updateMonitoringState() {
        if filterManager.state.isEnabled && extensionManager.state.isActive {
            log.info("Starting log monitoring (filter enabled, extension active)")
            logger.startMonitoring()
        } else {
            log.info("Stopping log monitoring (filter or extension inactive)")
            logger.stopMonitoring()
        }
    }
}

#Preview {
    ContentView()
}
