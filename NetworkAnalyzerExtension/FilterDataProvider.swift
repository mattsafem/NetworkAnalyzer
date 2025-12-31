//
//  FilterDataProvider.swift
//  NetworkAnalyzerExtension
//
//  Created by s on 12/30/25.
//

import NetworkExtension
import Network
import Security
import os.log
import Foundation
import SystemConfiguration

private let appGroupID = "group.com.safeme.NetworkAnalyzer"
private let connectionNotificationName = Notification.Name("com.safeme.NetworkAnalyzer.connectionLog")
private let udpLogHost = NWEndpoint.Host("127.0.0.1")
private let udpLogPort = NWEndpoint.Port(rawValue: 52845)!

class FilterDataProvider: NEFilterDataProvider {

    private let log = Logger(subsystem: "com.safeme.NetworkAnalyzer.NetworkAnalyzerExtension", category: "FilterDataProvider")
    private let logFileURL: URL?
    private let udpLogQueue = DispatchQueue(label: "com.safeme.NetworkAnalyzer.udpLog")
    private var udpConnection: NWConnection?
    private var udpConnectionFailed = false
    private var didLogFirstUDPSend = false
    private let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return df
    }()

    override init() {
        let consoleContainerURL = FilterDataProvider.resolveConsoleUserContainerURL()
        var containerURL = consoleContainerURL
        var containerSource = "console user"
        var resolvedLogFileURL: URL?
        var createDirectoryError: Error?

        if containerURL == nil {
            containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
            containerSource = "current user"
        }

        if let initialContainerURL = containerURL {
            let cacheDir = initialContainerURL.appendingPathComponent("Library/Caches", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
                resolvedLogFileURL = cacheDir.appendingPathComponent("network_logs.csv")
            } catch {
                createDirectoryError = error
                if consoleContainerURL != nil {
                    let fallbackURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
                    if let fallbackURL = fallbackURL {
                        containerSource = "current user (fallback)"
                        containerURL = fallbackURL
                        let fallbackCacheDir = fallbackURL.appendingPathComponent("Library/Caches", isDirectory: true)
                        do {
                            try FileManager.default.createDirectory(at: fallbackCacheDir, withIntermediateDirectories: true)
                            resolvedLogFileURL = fallbackCacheDir.appendingPathComponent("network_logs.csv")
                            createDirectoryError = nil
                        } catch {
                            createDirectoryError = error
                        }
                    }
                }
            }
        } else {
            resolvedLogFileURL = URL(fileURLWithPath: "/var/log/network_analyzer.csv")
        }

        logFileURL = resolvedLogFileURL
        super.init()

        if let containerURL = containerURL {
            log.info("App group container resolved (\(containerSource, privacy: .public)): \(containerURL.path, privacy: .public)")
        } else {
            log.error("App group container unavailable for \(appGroupID, privacy: .public)")
        }

        if let logFileURL = logFileURL {
            log.info("Log file path: \(logFileURL.path, privacy: .public)")
        } else {
            log.error("Log file URL is nil")
        }

        if let createDirectoryError = createDirectoryError {
            log.error("Failed to create cache directory: \(createDirectoryError.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Filter Lifecycle

    override func startFilter(completionHandler: @escaping (Error?) -> Void) {
        NSLog("NetworkAnalyzerExtension: startFilter called")
        log.info("Starting content filter...")

        // Configure default filter settings - filterData sends all flows to handleNewFlow
        let filterSettings = NEFilterSettings(rules: [], defaultAction: .filterData)
        log.info("Applying filter settings (defaultAction=filterData, rules=\(filterSettings.rules.count, privacy: .public))")

        apply(filterSettings) { [weak self] error in
            if let error = error {
                NSLog("NetworkAnalyzerExtension: Failed to apply filter - \(error.localizedDescription)")
                self?.log.error("Failed to apply filter settings: \(error.localizedDescription, privacy: .public)")
            } else {
                NSLog("NetworkAnalyzerExtension: Filter applied successfully")
                self?.log.info("Filter settings applied successfully")
            }
            completionHandler(error)
        }
    }

    override func stopFilter(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        log.info("Stopping content filter, reason: \(String(describing: reason), privacy: .public)")
        completionHandler()
    }

    // MARK: - Flow Handling

    override func handleNewFlow(_ flow: NEFilterFlow) -> NEFilterNewFlowVerdict {
        NSLog("NetworkAnalyzerExtension: handleNewFlow called")
        log.debug("handleNewFlow received flow type: \(String(describing: type(of: flow)), privacy: .public)")
        logFlow(flow)
        return .allow()
    }

    override func handleInboundData(from flow: NEFilterFlow, readBytesStartOffset: Int, readBytes: Data) -> NEFilterDataVerdict {
        return .allow()
    }

    override func handleOutboundData(from flow: NEFilterFlow, readBytesStartOffset: Int, readBytes: Data) -> NEFilterDataVerdict {
        return .allow()
    }

    // MARK: - Logging

    private func logFlow(_ flow: NEFilterFlow) {
        var logMessage = "New flow - "

        if let socketFlow = flow as? NEFilterSocketFlow {
            if let remoteEndpoint = socketFlow.remoteEndpoint as? NWHostEndpoint {
                logMessage += "Remote: \(remoteEndpoint.hostname):\(remoteEndpoint.port)"
            } else {
                logMessage += "Remote: unknown"
            }
            logMessage += " Direction: \(socketFlow.direction == .outbound ? "out" : "in")"
        } else {
            logMessage += "Non-socket flow: \(String(describing: type(of: flow)))"
        }

        // Get app identifier using audit token on macOS
        let appIdentifier = getAppIdentifier(from: flow)
        if let bundleId = Bundle.main.bundleIdentifier, appIdentifier == bundleId {
            log.debug("Skipping flow from extension process: \(bundleId, privacy: .public)")
            return
        }
        logMessage += " App: \(appIdentifier)"

        log.info("\(logMessage, privacy: .public)")

        // Write to the shared log file for the main app
        notifyMainApp(flow: flow, appIdentifier: appIdentifier)
    }

    private func getAppIdentifier(from flow: NEFilterFlow) -> String {
        // On macOS, use sourceAppAuditToken to get app info
        if let auditToken = flow.sourceAppAuditToken {
            // Try to get the bundle ID from the audit token
            var code: SecCode?
            let status = SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: auditToken] as CFDictionary, [], &code)

            if status == errSecSuccess, let code = code {
                var staticCode: SecStaticCode?
                if SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
                   let staticCode = staticCode {
                    var info: CFDictionary?
                    if SecCodeCopySigningInformation(staticCode, [], &info) == errSecSuccess,
                       let dict = info as? [String: Any],
                       let bundleId = dict[kSecCodeInfoIdentifier as String] as? String {
                        return bundleId
                    }
                }
            }
        }
        return "Unknown"
    }

    private func notifyMainApp(flow: NEFilterFlow, appIdentifier: String) {
        let now = Date()
        let timestamp = dateFormatter.string(from: now)
        var remoteHost = "unknown"
        var remotePort = "0"
        var direction = "unknown"

        if let socketFlow = flow as? NEFilterSocketFlow {
            if let remoteEndpoint = socketFlow.remoteEndpoint as? NWHostEndpoint {
                remoteHost = remoteEndpoint.hostname
                remotePort = remoteEndpoint.port
            }
            direction = socketFlow.direction == .outbound ? "outbound" : "inbound"
        }

        // Write to CSV log file
        writeToLogFile(
            timestamp: timestamp,
            app: appIdentifier,
            remoteHost: remoteHost,
            remotePort: remotePort,
            direction: direction,
            action: "allowed"
        )

        let connectionInfo: [String: Any] = [
            "timestamp": now.timeIntervalSince1970,
            "sourceAppIdentifier": appIdentifier,
            "remoteHost": remoteHost,
            "remotePort": remotePort,
            "direction": direction,
            "action": "allowed"
        ]

        DistributedNotificationCenter.default().post(
            name: connectionNotificationName,
            object: nil,
            userInfo: connectionInfo
        )

        sendLogOverUDP(connectionInfo)
    }

    private func writeToLogFile(timestamp: String, app: String, remoteHost: String, remotePort: String, direction: String, action: String) {
        guard let logFileURL = logFileURL else { return }

        // Escape CSV fields
        let escapedApp = app.replacingOccurrences(of: ",", with: ";")
        let escapedHost = remoteHost.replacingOccurrences(of: ",", with: ";")

        let line = "\(timestamp),\(escapedApp),\(escapedHost),\(remotePort),\(direction),\(action)\n"

        do {
            if FileManager.default.fileExists(atPath: logFileURL.path) {
                let fileHandle = try FileHandle(forWritingTo: logFileURL)
                fileHandle.seekToEndOfFile()
                if let data = line.data(using: .utf8) {
                    fileHandle.write(data)
                }
                try fileHandle.close()
            } else {
                // File doesn't exist, create it with header + line
                let content = "timestamp,app,remote_host,remote_port,direction,action\n" + line
                try content.write(to: logFileURL, atomically: true, encoding: .utf8)
            }
        } catch {
            log.error("Failed to write log file: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func sendLogOverUDP(_ connectionInfo: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: connectionInfo, options: []) else {
            log.error("Failed to encode UDP log payload")
            return
        }

        let connection = getOrCreateUDPConnection()
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error = error {
                self?.log.error("Failed to send UDP log payload: \(error.localizedDescription, privacy: .public)")
                self?.resetUDPConnectionAfterSendFailure()
            } else {
                if self?.didLogFirstUDPSend == false {
                    self?.didLogFirstUDPSend = true
                    self?.log.info("UDP log payload sent (\(data.count, privacy: .public) bytes)")
                } else {
                    self?.log.debug("UDP log payload sent (\(data.count, privacy: .public) bytes)")
                }
            }
        })
    }

    private func getOrCreateUDPConnection() -> NWConnection {
        if let connection = udpConnection, !udpConnectionFailed {
            return connection
        }

        if let connection = udpConnection {
            connection.cancel()
            udpConnection = nil
        }
        udpConnectionFailed = false

        let connection = NWConnection(host: udpLogHost, port: udpLogPort, using: .udp)
        connection.stateUpdateHandler = { [weak self] (state: NWConnection.State) in
            switch state {
            case .ready:
                self?.udpConnectionFailed = false
                let hostDescription = String(describing: udpLogHost)
                self?.log.info("UDP log connection ready to \(hostDescription, privacy: .public):\(udpLogPort.rawValue, privacy: .public)")
            case .failed(let error):
                self?.udpConnectionFailed = true
                self?.udpConnection = nil
                self?.log.error("UDP log connection failed: \(error.localizedDescription, privacy: .public)")
            case .cancelled:
                self?.udpConnectionFailed = true
                self?.udpConnection = nil
            default:
                break
            }
        }
        connection.start(queue: udpLogQueue)
        udpConnection = connection
        return connection
    }

    private func resetUDPConnectionAfterSendFailure() {
        udpConnectionFailed = true
        udpConnection?.cancel()
        udpConnection = nil
    }

    private static func resolveConsoleUserContainerURL() -> URL? {
        guard let username = SCDynamicStoreCopyConsoleUser(nil, nil, nil) as String?,
              !username.isEmpty,
              username != "loginwindow" else {
            return nil
        }

        guard let homeDirectory = FileManager.default.homeDirectory(forUser: username) else {
            return nil
        }

        return homeDirectory.appendingPathComponent("Library/Group Containers/\(appGroupID)", isDirectory: true)
    }
}
