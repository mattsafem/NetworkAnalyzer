//
//  FilterManager.swift
//  NetworkAnalyzer
//
//  Manages the NEFilterManager configuration for content filtering
//

import Foundation
import NetworkExtension
import os.log

enum FilterState: Equatable {
    case unknown
    case disabled
    case enabled
    case configuring
    case error(String)

    var description: String {
        switch self {
        case .unknown:
            return "Unknown"
        case .disabled:
            return "Disabled"
        case .enabled:
            return "Enabled"
        case .configuring:
            return "Configuring..."
        case .error(let message):
            return "Error: \(message)"
        }
    }

    var isEnabled: Bool {
        self == .enabled
    }
}

@MainActor
class FilterManager: ObservableObject {
    static let shared = FilterManager()

    private let log = Logger(subsystem: "com.safeme.NetworkAnalyzer", category: "FilterManager")

    @Published var state: FilterState = .unknown
    @Published var statusMessage: String = ""
    @Published var isLoading: Bool = false

    private let filterManager = NEFilterManager.shared()

    private init() {
        loadCurrentConfiguration()
    }

    // MARK: - Public Methods

    func loadCurrentConfiguration() {
        isLoading = true
        statusMessage = "Loading filter configuration..."
        log.info("Loading filter configuration from preferences")

        filterManager.loadFromPreferences { [weak self] error in
            Task { @MainActor in
                guard let self = self else { return }
                self.isLoading = false

                if let error = error {
                    self.log.error("Failed to load filter configuration: \(error.localizedDescription, privacy: .public)")
                    self.state = .error(error.localizedDescription)
                    self.statusMessage = "Failed to load configuration"
                    return
                }

                let providerId = self.filterManager.providerConfiguration?.filterDataProviderBundleIdentifier ?? "none"
                self.log.info("Loaded filter configuration (enabled=\(self.filterManager.isEnabled, privacy: .public), provider=\(providerId, privacy: .public))")
                self.updateStateFromManager()
            }
        }
    }

    func enableFilter() async throws {
        log.info("Enabling content filter...")
        isLoading = true
        state = .configuring
        statusMessage = "Enabling content filter..."

        return try await withCheckedThrowingContinuation { continuation in
            // First load current preferences
            filterManager.loadFromPreferences { [weak self] error in
                guard let self = self else { return }

                if let error = error {
                    Task { @MainActor in
                        self.isLoading = false
                        self.state = .error(error.localizedDescription)
                        self.statusMessage = "Failed to load preferences"
                    }
                    continuation.resume(throwing: error)
                    return
                }

                // Configure the filter
                let providerConfiguration = NEFilterProviderConfiguration()
                providerConfiguration.filterSockets = true
                providerConfiguration.filterPackets = false
                providerConfiguration.organization = "NetworkAnalyzer"
                providerConfiguration.filterDataProviderBundleIdentifier = "com.safeme.NetworkAnalyzer.NetworkAnalyzerExtension"

                self.log.info("Configuring provider (filterSockets=\(providerConfiguration.filterSockets, privacy: .public), filterPackets=\(providerConfiguration.filterPackets, privacy: .public), providerId=\(providerConfiguration.filterDataProviderBundleIdentifier ?? "none", privacy: .public))")

                self.filterManager.providerConfiguration = providerConfiguration
                self.filterManager.isEnabled = true
                self.filterManager.localizedDescription = "NetworkAnalyzer Content Filter"

                // Save the configuration
                self.filterManager.saveToPreferences { [weak self] saveError in
                    guard let self = self else { return }

                    Task { @MainActor in
                        self.isLoading = false

                        if let saveError = saveError {
                            self.log.error("Failed to save filter configuration: \(saveError.localizedDescription, privacy: .public)")
                            self.state = .error(saveError.localizedDescription)
                            self.statusMessage = "Failed to enable filter"
                            continuation.resume(throwing: saveError)
                            return
                        }

                        self.log.info("Content filter enabled successfully")
                        self.state = .enabled
                        self.statusMessage = "Content filter enabled"
                        let providerId = self.filterManager.providerConfiguration?.filterDataProviderBundleIdentifier ?? "none"
                        self.log.info("Saved filter configuration (enabled=\(self.filterManager.isEnabled, privacy: .public), provider=\(providerId, privacy: .public))")
                        continuation.resume()
                    }
                }
            }
        }
    }

    func disableFilter() async throws {
        log.info("Disabling content filter...")
        isLoading = true
        state = .configuring
        statusMessage = "Disabling content filter..."

        return try await withCheckedThrowingContinuation { continuation in
            filterManager.loadFromPreferences { [weak self] error in
                guard let self = self else { return }

                if let error = error {
                    Task { @MainActor in
                        self.isLoading = false
                        self.state = .error(error.localizedDescription)
                    }
                    continuation.resume(throwing: error)
                    return
                }

                self.filterManager.isEnabled = false

                self.filterManager.saveToPreferences { [weak self] saveError in
                    guard let self = self else { return }

                    Task { @MainActor in
                        self.isLoading = false

                        if let saveError = saveError {
                            self.log.error("Failed to disable filter: \(saveError.localizedDescription, privacy: .public)")
                            self.state = .error(saveError.localizedDescription)
                            self.statusMessage = "Failed to disable filter"
                            continuation.resume(throwing: saveError)
                            return
                        }

                        self.log.info("Content filter disabled successfully")
                        self.state = .disabled
                        self.statusMessage = "Content filter disabled"
                        let providerId = self.filterManager.providerConfiguration?.filterDataProviderBundleIdentifier ?? "none"
                        self.log.info("Saved filter configuration (enabled=\(self.filterManager.isEnabled, privacy: .public), provider=\(providerId, privacy: .public))")
                        continuation.resume()
                    }
                }
            }
        }
    }

    func removeFilter() async throws {
        log.info("Removing content filter configuration...")
        isLoading = true
        statusMessage = "Removing filter configuration..."

        return try await withCheckedThrowingContinuation { continuation in
            filterManager.loadFromPreferences { [weak self] error in
                guard let self = self else { return }

                if let error = error {
                    Task { @MainActor in
                        self.isLoading = false
                        self.state = .error(error.localizedDescription)
                    }
                    continuation.resume(throwing: error)
                    return
                }

                self.filterManager.removeFromPreferences { [weak self] removeError in
                    guard let self = self else { return }

                    Task { @MainActor in
                        self.isLoading = false

                        if let removeError = removeError {
                            self.log.error("Failed to remove filter: \(removeError.localizedDescription, privacy: .public)")
                            self.state = .error(removeError.localizedDescription)
                            self.statusMessage = "Failed to remove filter"
                            continuation.resume(throwing: removeError)
                            return
                        }

                        self.log.info("Content filter removed successfully")
                        self.state = .disabled
                        self.statusMessage = "Filter configuration removed"
                        self.log.info("Removed filter configuration from preferences")
                        continuation.resume()
                    }
                }
            }
        }
    }

    // MARK: - Private Methods

    private func updateStateFromManager() {
        if filterManager.providerConfiguration != nil {
            if filterManager.isEnabled {
                state = .enabled
                statusMessage = "Content filter is active"
            } else {
                state = .disabled
                statusMessage = "Content filter is configured but disabled"
            }
        } else {
            state = .disabled
            statusMessage = "Content filter not configured"
        }

        log.info("Filter state updated: \(String(describing: self.state), privacy: .public)")
    }
}
