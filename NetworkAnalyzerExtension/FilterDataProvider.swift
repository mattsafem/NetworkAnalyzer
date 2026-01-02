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
import Darwin

private let appGroupID = "group.com.safeme.NetworkAnalyzer"
private let connectionNotificationName = Notification.Name("com.safeme.NetworkAnalyzer.connectionLog")
private let udpLogHost = NWEndpoint.Host("127.0.0.1")
private let udpLogPort = NWEndpoint.Port(rawValue: 52845)!

class FilterDataProvider: NEFilterDataProvider {

    private let log = Logger(subsystem: "com.safeme.NetworkAnalyzer.NetworkAnalyzerExtension", category: "FilterDataProvider")
    private let udpLogQueue = DispatchQueue(label: "com.safeme.NetworkAnalyzer.udpLog")
    private var udpConnection: NWConnection?
    private var udpConnectionFailed = false
    private var didLogFirstUDPSend = false
    private let blockListReader = BlockListReader()
    private let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return df
    }()

    override init() {
        super.init()
        log.info("FilterDataProvider initialized")
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

        let metadata = resolveAppMetadata(from: flow)
        var remoteHost = "unknown"

        if let socketFlow = flow as? NEFilterSocketFlow,
           let remoteEndpoint = socketFlow.remoteEndpoint as? NWHostEndpoint {
            remoteHost = remoteEndpoint.hostname
        }

        // Check if app or host is blocked
        let isAppBlocked = blockListReader.isAppBlocked(metadata.appIdentifier)
        let isHostBlocked = blockListReader.isHostBlocked(remoteHost)

        // Debug log for blocked app checks
        let blockedCount = blockListReader.blockedAppsCount
        NSLog("NetworkAnalyzerExtension: Block check app=%@ isBlocked=%d totalBlocked=%d", metadata.appIdentifier, isAppBlocked ? 1 : 0, blockedCount)

        if isAppBlocked || isHostBlocked {
            NSLog("NetworkAnalyzerExtension: BLOCKING %@ -> %@", metadata.appIdentifier, remoteHost)
            return .drop()
        }

        logFlow(flow, action: "allowed")
        return .allow()
    }

    override func handleInboundData(from flow: NEFilterFlow, readBytesStartOffset: Int, readBytes: Data) -> NEFilterDataVerdict {
        return .allow()
    }

    override func handleOutboundData(from flow: NEFilterFlow, readBytesStartOffset: Int, readBytes: Data) -> NEFilterDataVerdict {
        return .allow()
    }

    // MARK: - Logging

    private func logFlow(_ flow: NEFilterFlow, action: String = "allowed") {
        let metadata = resolveAppMetadata(from: flow)
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

        let appIdentifier = metadata.appIdentifier
        if let bundleId = Bundle.main.bundleIdentifier, appIdentifier == bundleId {
            log.debug("Skipping flow from extension process: \(bundleId, privacy: .public)")
            return
        }
        logMessage += " App: \(appIdentifier)"
        if let pid = metadata.pid {
            logMessage += " PID: \(pid)"
        }

        log.info("\(logMessage, privacy: .public)")

        // Write to the shared log file for the main app
        notifyMainApp(flow: flow, metadata: metadata, action: action)
    }

    private func resolveAppMetadata(from flow: NEFilterFlow) -> AppMetadata {
        if let auditToken = flow.sourceAppAuditToken {
            if let identifier = resolveSigningIdentifier(from: auditToken) {
                return metadataFromAuditToken(identifier: identifier, auditToken: auditToken, tokenSource: "app")
            }
        }

        if #available(macOS 13.0, *), let auditToken = flow.sourceProcessAuditToken {
            if let identifier = resolveSigningIdentifier(from: auditToken) {
                return metadataFromAuditToken(identifier: identifier, auditToken: auditToken, tokenSource: "process")
            }
        }

        if let auditToken = flow.sourceAppAuditToken {
            if let identifier = resolveProcessFallbackIdentifier(from: auditToken) {
                return metadataFromAuditToken(identifier: identifier, auditToken: auditToken, tokenSource: "app")
            }
        }

        if #available(macOS 13.0, *), let auditToken = flow.sourceProcessAuditToken {
            if let identifier = resolveProcessFallbackIdentifier(from: auditToken) {
                return metadataFromAuditToken(identifier: identifier, auditToken: auditToken, tokenSource: "process")
            }
        }

        return AppMetadata(
            appIdentifier: "Unknown",
            pid: nil,
            processPath: nil,
            processName: nil,
            tokenSource: nil
        )
    }

    private func metadataFromAuditToken(identifier: String, auditToken: Data, tokenSource: String) -> AppMetadata {
        let pid = resolveProcessID(from: auditToken)
        let processPath = resolveProcessPath(from: auditToken)
        let processName = processPath.map { URL(fileURLWithPath: $0).lastPathComponent }

        return AppMetadata(
            appIdentifier: identifier,
            pid: pid,
            processPath: processPath,
            processName: processName,
            tokenSource: tokenSource
        )
    }

    private func resolveSigningIdentifier(from auditToken: Data) -> String? {
        if let identifier = resolveSigningIdentifierWithSecCode(from: auditToken) {
            return identifier
        }

        if let identifier = resolveSigningIdentifierWithSecTask(from: auditToken) {
            return identifier
        }

        return nil
    }

    private func resolveSigningIdentifierWithSecCode(from auditToken: Data) -> String? {
        var code: SecCode?
        let status = SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: auditToken] as CFDictionary, [], &code)

        guard status == errSecSuccess, let code = code else {
            return nil
        }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode = staticCode else {
            return nil
        }

        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, [], &info) == errSecSuccess,
              let dict = info as? [String: Any] else {
            return nil
        }

        return dict[kSecCodeInfoIdentifier as String] as? String
    }

    private func resolveSigningIdentifierWithSecTask(from auditToken: Data) -> String? {
        guard let token = makeAuditToken(from: auditToken) else {
            return nil
        }

        guard let task = SecTaskCreateWithAuditToken(nil, token) else {
            return nil
        }

        let identifier = SecTaskCopySigningIdentifier(task, nil) as String?
        return identifier
    }

    private func resolveProcessID(from auditToken: Data) -> Int? {
        guard let token = makeAuditToken(from: auditToken) else {
            return nil
        }

        // Extract PID from audit_token_t structure
        // The PID is stored at index 5 in the val array of audit_token_t
        let pid = withUnsafeBytes(of: token) { ptr in
            ptr.load(fromByteOffset: 5 * MemoryLayout<UInt32>.size, as: Int32.self)
        }
        return pid > 0 ? Int(pid) : nil
    }

    private func resolveProcessFallbackIdentifier(from auditToken: Data) -> String? {
        guard let processPath = resolveProcessPath(from: auditToken) else {
            return nil
        }

        if let bundleIdentifier = resolveBundleIdentifier(fromProcessPath: processPath) {
            return bundleIdentifier
        }

        let processName = URL(fileURLWithPath: processPath).lastPathComponent
        if processName.isEmpty {
            return nil
        }

        return "process:\(processName)"
    }

    private func resolveProcessPath(from auditToken: Data) -> String? {
        guard #available(macOS 11.0, *) else {
            return nil
        }

        guard var token = makeAuditToken(from: auditToken) else {
            return nil
        }

        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let result = proc_pidpath_audittoken(&token, &buffer, UInt32(buffer.count))
        guard result > 0 else {
            return nil
        }

        return String(cString: buffer)
    }

    private func resolveBundleIdentifier(fromProcessPath processPath: String) -> String? {
        var url = URL(fileURLWithPath: processPath)
        while url.path != "/" {
            if url.pathExtension == "app" {
                return Bundle(url: url)?.bundleIdentifier
            }
            url.deleteLastPathComponent()
        }

        return nil
    }

    private func makeAuditToken(from data: Data) -> audit_token_t? {
        guard data.count == MemoryLayout<audit_token_t>.size else {
            return nil
        }

        var token = audit_token_t()
        _ = withUnsafeMutableBytes(of: &token) { buffer in
            data.copyBytes(to: buffer)
        }
        return token
    }

    private func transportProtocolLabel(for socketProtocol: Int) -> String {
        switch socketProtocol {
        case Int(IPPROTO_TCP):
            return "tcp"
        case Int(IPPROTO_UDP):
            return "udp"
        case Int(IPPROTO_ICMP):
            return "icmp"
        default:
            return "proto:\(socketProtocol)"
        }
    }

    private func notifyMainApp(flow: NEFilterFlow, metadata: AppMetadata, action: String) {
        let now = Date()
        let timestamp = dateFormatter.string(from: now)
        var remoteHost = "unknown"
        var remotePort = "0"
        var direction = "unknown"
        var localHost: String?
        var localPort: String?
        var remoteHostname: String?
        var protocolLabel: String?
        var socketFamily: Int?
        var socketType: Int?
        var socketProtocol: Int?
        var flowIdentifier: String?
        var flowURL: String?

        if let socketFlow = flow as? NEFilterSocketFlow {
            if let remoteEndpoint = socketFlow.remoteEndpoint as? NWHostEndpoint {
                remoteHost = remoteEndpoint.hostname
                remotePort = remoteEndpoint.port
            }
            if let localEndpoint = socketFlow.localEndpoint as? NWHostEndpoint {
                localHost = localEndpoint.hostname
                localPort = localEndpoint.port
            }
            direction = socketFlow.direction == .outbound ? "outbound" : "inbound"
            remoteHostname = socketFlow.remoteHostname
            socketFamily = Int(socketFlow.socketFamily)
            socketType = Int(socketFlow.socketType)
            socketProtocol = Int(socketFlow.socketProtocol)
            protocolLabel = transportProtocolLabel(for: Int(socketFlow.socketProtocol))
        }

        if #available(macOS 13.1, *) {
            flowIdentifier = flow.identifier.uuidString
        }

        if let url = flow.url?.absoluteString {
            flowURL = url
        }

        var connectionInfo: [String: Any] = [
            "timestamp": now.timeIntervalSince1970,
            "sourceAppIdentifier": metadata.appIdentifier,
            "remoteHost": remoteHost,
            "remotePort": remotePort,
            "direction": direction,
            "action": action
        ]

        if let localHost = localHost { connectionInfo["localHost"] = localHost }
        if let localPort = localPort { connectionInfo["localPort"] = localPort }
        if let remoteHostname = remoteHostname { connectionInfo["remoteHostname"] = remoteHostname }
        if let protocolLabel = protocolLabel { connectionInfo["protocolName"] = protocolLabel }
        if let socketFamily = socketFamily { connectionInfo["socketFamily"] = socketFamily }
        if let socketType = socketType { connectionInfo["socketType"] = socketType }
        if let socketProtocol = socketProtocol { connectionInfo["socketProtocol"] = socketProtocol }
        if let pid = metadata.pid { connectionInfo["pid"] = pid }
        if let processPath = metadata.processPath { connectionInfo["processPath"] = processPath }
        if let processName = metadata.processName { connectionInfo["processName"] = processName }
        if let flowIdentifier = flowIdentifier { connectionInfo["flowIdentifier"] = flowIdentifier }
        if let flowURL = flowURL { connectionInfo["url"] = flowURL }
        if let tokenSource = metadata.tokenSource { connectionInfo["tokenSource"] = tokenSource }

        DistributedNotificationCenter.default().post(
            name: connectionNotificationName,
            object: nil,
            userInfo: connectionInfo
        )

        sendLogOverUDP(connectionInfo)
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
}

private struct AppMetadata {
    let appIdentifier: String
    let pid: Int?
    let processPath: String?
    let processName: String?
    let tokenSource: String?
}

// MARK: - Block List

private struct BlockList: Codable, Equatable {
    var blockedApps: Set<String>
    var blockedHosts: Set<String>
    var lastModified: Date

    init() {
        blockedApps = []
        blockedHosts = []
        lastModified = Date()
    }
}

class BlockListReader {
    private static let appGroupID = "group.com.safeme.NetworkAnalyzer"
    private let blockListFileName = "block_list.json"
    private var blockList = BlockList()
    private let log = Logger(subsystem: "com.safeme.NetworkAnalyzer.NetworkAnalyzerExtension", category: "BlockListReader")
    private var fileURL: URL?

    init() {
        setupFileURL()
        reload()
        startWatchingForChanges()
    }

    func isAppBlocked(_ appIdentifier: String) -> Bool {
        blockList.blockedApps.contains(appIdentifier)
    }

    func isHostBlocked(_ host: String) -> Bool {
        blockList.blockedHosts.contains(host)
    }

    var blockedAppsCount: Int {
        blockList.blockedApps.count
    }

    private func setupFileURL() {
        log.info("BlockListReader: setupFileURL starting")

        // Use system-wide location accessible to both app and extension
        if let sharedURL = BlockListReader.resolveSharedContainerURL() {
            fileURL = sharedURL.appendingPathComponent(blockListFileName)
            log.info("Block list path: \(self.fileURL?.path ?? "nil", privacy: .public)")

            // Check if file exists
            if let path = fileURL?.path {
                let exists = FileManager.default.fileExists(atPath: path)
                log.info("Block list file exists: \(exists, privacy: .public)")
            }
            return
        } else {
            log.warning("Could not resolve console user container")
        }

        // Fallback to current user's container
        if let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: BlockListReader.appGroupID) {
            fileURL = containerURL
                .appendingPathComponent("Library/Caches", isDirectory: true)
                .appendingPathComponent(blockListFileName)
            log.info("Block list path (current user): \(self.fileURL?.path ?? "nil", privacy: .public)")
            return
        }

        log.error("Failed to resolve block list container URL")
    }

    private static func resolveSharedContainerURL() -> URL? {
        // Use system-wide location accessible to both app and extension
        let path = "/Library/Application Support/NetworkAnalyzer"
        let url = URL(fileURLWithPath: path, isDirectory: true)

        // Create directory if needed
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        return url
    }

    func reload() {
        log.info("BlockListReader: reload() called")

        guard let fileURL = fileURL else {
            log.error("Block list file URL not set!")
            return
        }

        log.info("Checking file at: \(fileURL.path, privacy: .public)")

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            log.warning("Block list file not found at: \(fileURL.path, privacy: .public)")
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            log.info("Read \(data.count, privacy: .public) bytes from block list file")

            let decoder = JSONDecoder()
            let newBlockList = try decoder.decode(BlockList.self, from: data)

            blockList = newBlockList
            log.info("Loaded block list: \(self.blockList.blockedApps.count, privacy: .public) apps, \(self.blockList.blockedHosts.count, privacy: .public) hosts")

            // Log the actual blocked apps for debugging
            for app in blockList.blockedApps {
                log.info("Blocked app: \(app, privacy: .public)")
            }
        } catch {
            log.error("Failed to reload block list: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func startWatchingForChanges() {
        // Use CFNotificationCenter Darwin notifications (work across sandbox boundaries)
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let notifyName = "com.safeme.NetworkAnalyzer.blockListChanged" as CFString

        CFNotificationCenterAddObserver(
            center,
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer = observer else { return }
                let myself = Unmanaged<BlockListReader>.fromOpaque(observer).takeUnretainedValue()
                myself.log.info("Block list change notification received (Darwin)")
                myself.reload()
            },
            notifyName,
            nil,
            .deliverImmediately
        )

        log.info("Registered for Darwin notifications: \(notifyName as String, privacy: .public)")
    }
}
