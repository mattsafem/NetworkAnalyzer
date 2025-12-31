//
//  FilterStatusView.swift
//  NetworkAnalyzer
//
//  Shows current filter status and controls
//

import SwiftUI
import os.log

struct FilterStatusView: View {
    @ObservedObject var extensionManager: SystemExtensionManager
    @ObservedObject var filterManager: FilterManager

    @State private var isProcessing = false
    @State private var errorMessage: String?
    @State private var showingError = false
    private let log = Logger(subsystem: "com.safeme.NetworkAnalyzer", category: "FilterStatusView")

    var body: some View {
        VStack(spacing: 20) {
            // Status Card
            GroupBox {
                VStack(spacing: 16) {
                    // Extension Status
                    HStack {
                        Image(systemName: extensionStatusIcon)
                            .font(.title2)
                            .foregroundStyle(extensionStatusColor)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("System Extension")
                                .font(.headline)
                            Text(extensionManager.state.description)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        extensionButton
                    }

                    Divider()

                    // Filter Status
                    HStack {
                        Image(systemName: filterStatusIcon)
                            .font(.title2)
                            .foregroundStyle(filterStatusColor)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Content Filter")
                                .font(.headline)
                            Text(filterManager.state.description)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        filterButton
                    }
                }
                .padding()
            } label: {
                Label("Filter Status", systemImage: "shield.checkered")
            }

            // Instructions
            if extensionManager.state == .needsUserApproval {
                GroupBox {
                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.title2)
                            .foregroundStyle(.orange)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("User Approval Required")
                                .font(.headline)
                            Text("Open System Settings > Privacy & Security > Security to allow the system extension.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button("Open Settings") {
                            openSecuritySettings()
                        }
                    }
                    .padding()
                }
            }

            // Status Messages
            if !extensionManager.statusMessage.isEmpty || !filterManager.statusMessage.isEmpty {
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        if !extensionManager.statusMessage.isEmpty {
                            Label(extensionManager.statusMessage, systemImage: "info.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if !filterManager.statusMessage.isEmpty {
                            Label(filterManager.statusMessage, systemImage: "info.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                } label: {
                    Label("Status", systemImage: "text.bubble")
                }
            }
        }
        .alert("Error", isPresented: $showingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "An unknown error occurred")
        }
    }

    // MARK: - Extension Button

    @ViewBuilder
    private var extensionButton: some View {
        switch extensionManager.state {
        case .unknown, .notInstalled, .failed:
            Button("Install") {
                installExtension()
            }
            .buttonStyle(.borderedProminent)
            .disabled(isProcessing)

        case .activating, .deactivating:
            ProgressView()
                .controlSize(.small)

        case .needsUserApproval:
            Button("Retry") {
                installExtension()
            }
            .buttonStyle(.bordered)
            .disabled(isProcessing)

        case .activated:
            Button("Uninstall") {
                uninstallExtension()
            }
            .buttonStyle(.bordered)
            .disabled(isProcessing)
        }
    }

    // MARK: - Filter Button

    @ViewBuilder
    private var filterButton: some View {
        if !extensionManager.state.isActive {
            Text("Extension Required")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            switch filterManager.state {
            case .unknown, .disabled, .error:
                Button("Enable") {
                    enableFilter()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isProcessing || filterManager.isLoading)

            case .configuring:
                ProgressView()
                    .controlSize(.small)

            case .enabled:
                Button("Disable") {
                    disableFilter()
                }
                .buttonStyle(.bordered)
                .disabled(isProcessing || filterManager.isLoading)
            }
        }
    }

    // MARK: - Status Helpers

    private var extensionStatusIcon: String {
        switch extensionManager.state {
        case .activated:
            return "checkmark.shield.fill"
        case .activating, .deactivating:
            return "arrow.triangle.2.circlepath"
        case .needsUserApproval:
            return "exclamationmark.shield.fill"
        case .failed:
            return "xmark.shield.fill"
        default:
            return "shield"
        }
    }

    private var extensionStatusColor: Color {
        switch extensionManager.state {
        case .activated:
            return .green
        case .activating, .deactivating, .needsUserApproval:
            return .orange
        case .failed:
            return .red
        default:
            return .secondary
        }
    }

    private var filterStatusIcon: String {
        switch filterManager.state {
        case .enabled:
            return "network.badge.shield.half.filled"
        case .configuring:
            return "arrow.triangle.2.circlepath"
        case .error:
            return "exclamationmark.triangle.fill"
        default:
            return "network"
        }
    }

    private var filterStatusColor: Color {
        switch filterManager.state {
        case .enabled:
            return .green
        case .configuring:
            return .orange
        case .error:
            return .red
        default:
            return .secondary
        }
    }

    // MARK: - Actions

    private func installExtension() {
        isProcessing = true
        log.info("User requested system extension installation")
        Task {
            do {
                try await extensionManager.activateExtension()
                log.info("System extension activation request completed")
            } catch {
                log.error("System extension activation failed: \(error.localizedDescription, privacy: .public)")
                errorMessage = error.localizedDescription
                showingError = true
            }
            isProcessing = false
        }
    }

    private func uninstallExtension() {
        isProcessing = true
        log.info("User requested system extension uninstallation")
        Task {
            do {
                try await filterManager.removeFilter()
                try await extensionManager.deactivateExtension()
                log.info("System extension deactivation request completed")
            } catch {
                log.error("System extension deactivation failed: \(error.localizedDescription, privacy: .public)")
                errorMessage = error.localizedDescription
                showingError = true
            }
            isProcessing = false
        }
    }

    private func enableFilter() {
        isProcessing = true
        log.info("User requested filter enable")
        Task {
            do {
                try await filterManager.enableFilter()
                log.info("Filter enable request completed")
            } catch {
                log.error("Filter enable failed: \(error.localizedDescription, privacy: .public)")
                errorMessage = error.localizedDescription
                showingError = true
            }
            isProcessing = false
        }
    }

    private func disableFilter() {
        isProcessing = true
        log.info("User requested filter disable")
        Task {
            do {
                try await filterManager.disableFilter()
                log.info("Filter disable request completed")
            } catch {
                log.error("Filter disable failed: \(error.localizedDescription, privacy: .public)")
                errorMessage = error.localizedDescription
                showingError = true
            }
            isProcessing = false
        }
    }

    private func openSecuritySettings() {
        log.info("Opening System Settings > Privacy & Security")
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
            NSWorkspace.shared.open(url)
        }
    }
}
