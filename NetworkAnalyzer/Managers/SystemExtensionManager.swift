//
//  SystemExtensionManager.swift
//  NetworkAnalyzer
//
//  Handles System Extension activation and deactivation
//

import Foundation
import SystemExtensions
import os.log

enum SystemExtensionState: Equatable {
    case unknown
    case notInstalled
    case activating
    case needsUserApproval
    case activated
    case deactivating
    case failed(String)

    var description: String {
        switch self {
        case .unknown:
            return "Unknown"
        case .notInstalled:
            return "Not Installed"
        case .activating:
            return "Activating..."
        case .needsUserApproval:
            return "Awaiting User Approval"
        case .activated:
            return "Activated"
        case .deactivating:
            return "Deactivating..."
        case .failed(let message):
            return "Failed: \(message)"
        }
    }

    var isActive: Bool {
        self == .activated
    }
}

@MainActor
class SystemExtensionManager: NSObject, ObservableObject {
    static let shared = SystemExtensionManager()

    private let log = Logger(subsystem: "com.safeme.NetworkAnalyzer", category: "SystemExtensionManager")
    private let extensionBundleIdentifier = "com.safeme.NetworkAnalyzer.NetworkAnalyzerExtension"

    @Published var state: SystemExtensionState = .unknown
    @Published var statusMessage: String = ""

    private var activationCompletion: ((Result<Void, Error>) -> Void)?
    private var deactivationCompletion: ((Result<Void, Error>) -> Void)?
    private var pendingPropertiesRequest = false

    private override init() {
        super.init()
    }

    // MARK: - Public Methods

    func activateExtension() async throws {
        log.info("Requesting system extension activation...")
        state = .activating
        statusMessage = "Requesting system extension activation..."
        log.info("Activation request for \(self.extensionBundleIdentifier, privacy: .public)")

        return try await withCheckedThrowingContinuation { continuation in
            self.activationCompletion = { result in
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            let request = OSSystemExtensionRequest.activationRequest(
                forExtensionWithIdentifier: extensionBundleIdentifier,
                queue: .main
            )
            request.delegate = self
            OSSystemExtensionManager.shared.submitRequest(request)
        }
    }

    func deactivateExtension() async throws {
        log.info("Requesting system extension deactivation...")
        state = .deactivating
        statusMessage = "Requesting system extension deactivation..."
        log.info("Deactivation request for \(self.extensionBundleIdentifier, privacy: .public)")

        return try await withCheckedThrowingContinuation { continuation in
            self.deactivationCompletion = { result in
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            let request = OSSystemExtensionRequest.deactivationRequest(
                forExtensionWithIdentifier: extensionBundleIdentifier,
                queue: .main
            )
            request.delegate = self
            OSSystemExtensionManager.shared.submitRequest(request)
        }
    }

    func refreshExtensionState() {
        guard state != .activating, state != .deactivating else {
            return
        }

        guard #available(macOS 12.0, *) else {
            log.info("System extension status query requires macOS 12+")
            return
        }

        log.info("Refreshing system extension status")
        pendingPropertiesRequest = true
        let request = OSSystemExtensionRequest.propertiesRequest(
            forExtensionWithIdentifier: extensionBundleIdentifier,
            queue: .main
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }
}

// MARK: - OSSystemExtensionRequestDelegate

extension SystemExtensionManager: OSSystemExtensionRequestDelegate {
    nonisolated func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        Task { @MainActor in
            if pendingPropertiesRequest {
                pendingPropertiesRequest = false
                return
            }

            log.info("System extension request finished with result: \(String(describing: result), privacy: .public)")

            switch result {
            case .completed:
                state = .activated
                statusMessage = "System extension activated successfully"
                activationCompletion?(.success(()))
                deactivationCompletion?(.success(()))
            case .willCompleteAfterReboot:
                state = .needsUserApproval
                statusMessage = "System extension will complete after reboot"
                activationCompletion?(.success(()))
            @unknown default:
                state = .failed("Unknown result")
                statusMessage = "Unknown result from system extension request"
                activationCompletion?(.failure(SystemExtensionError.unknownResult))
            }

            activationCompletion = nil
            deactivationCompletion = nil
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        Task { @MainActor in
            if pendingPropertiesRequest {
                pendingPropertiesRequest = false
                log.error("System extension status query failed: \(error.localizedDescription, privacy: .public)")
                state = .notInstalled
                statusMessage = "System extension not installed"
                return
            }

            log.error("System extension request failed: \(error.localizedDescription, privacy: .public)")

            let nsError = error as NSError
            let errorMessage: String

            switch nsError.code {
            case 1: // OSSystemExtensionErrorUnsupportedParentBundleLocation
                errorMessage = "App must be in /Applications folder"
            case 4: // OSSystemExtensionErrorExtensionNotFound
                errorMessage = "Extension not found in app bundle"
            case 8: // OSSystemExtensionErrorRequestCanceled
                errorMessage = "Request was canceled"
            default:
                errorMessage = error.localizedDescription
            }

            state = .failed(errorMessage)
            statusMessage = errorMessage

            activationCompletion?(.failure(error))
            deactivationCompletion?(.failure(error))
            activationCompletion = nil
            deactivationCompletion = nil
        }
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        Task { @MainActor in
            log.info("System extension needs user approval")
            state = .needsUserApproval
            statusMessage = "Please approve the system extension in System Settings > Privacy & Security"
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, foundProperties properties: [OSSystemExtensionProperties]) {
        Task { @MainActor in
            guard pendingPropertiesRequest else { return }
            pendingPropertiesRequest = false

            guard let properties = properties.first else {
                state = .notInstalled
                statusMessage = "System extension not installed"
                log.info("System extension not installed")
                return
            }

            if properties.isAwaitingUserApproval {
                state = .needsUserApproval
                statusMessage = "System extension awaiting user approval"
            } else if properties.isEnabled {
                state = .activated
                statusMessage = "System extension active"
            } else {
                state = .notInstalled
                statusMessage = "System extension installed but disabled"
            }

            log.info("System extension status refreshed (enabled=\(properties.isEnabled, privacy: .public), awaitingApproval=\(properties.isAwaitingUserApproval, privacy: .public))")
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties, withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        log.info("Replacing existing extension")
        return .replace
    }
}

// MARK: - Errors

enum SystemExtensionError: LocalizedError {
    case unknownResult
    case activationFailed(String)

    var errorDescription: String? {
        switch self {
        case .unknownResult:
            return "Unknown result from system extension activation"
        case .activationFailed(let message):
            return "System extension activation failed: \(message)"
        }
    }
}
