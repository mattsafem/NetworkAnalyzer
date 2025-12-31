//
//  NetworkLogger.swift
//  NetworkAnalyzer
//
//  Manages logging of network connections and events
//

import Foundation
import os.log
import Combine
import Network

private let appGroupID = "group.com.safeme.NetworkAnalyzer"

struct ConnectionLogEntry: Identifiable, Codable {
    let id: UUID
    let timestamp: Date
    let sourceApp: String
    let remoteHost: String
    let remotePort: String
    let direction: String
    let action: String

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        sourceApp: String,
        remoteHost: String,
        remotePort: String,
        direction: String,
        action: String = "allowed"
    ) {
        self.id = id
        self.timestamp = timestamp
        self.sourceApp = sourceApp
        self.remoteHost = remoteHost
        self.remotePort = remotePort
        self.direction = direction
        self.action = action
    }
}

@MainActor
class NetworkLogger: ObservableObject {
    static let shared = NetworkLogger()

    private let log = Logger(subsystem: "com.safeme.NetworkAnalyzer", category: "NetworkLogger")

    @Published var logs: [ConnectionLogEntry] = []
    @Published var isMonitoring: Bool = false

    private var timer: Timer?
    private let maxLogs = 500
    private let logFileName = "network_logs.csv"
    private let udpLogPort = NWEndpoint.Port(rawValue: 52845)!
    private let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()
    private var logFileURL: URL?
    private var lastFileOffset: UInt64 = 0
    private var pendingLineFragment = ""
    private var didLogMissingLogFile = false
    private let connectionNotificationName = Notification.Name("com.safeme.NetworkAnalyzer.connectionLog")
    private var notificationObserver: NSObjectProtocol?
    private var didReceiveNotificationLog = false
    private var didReceiveLiveLog = false
    private var udpListener: UDPLogListener?
    private var didLogFirstUDPReceipt = false

    private init() {}

    // MARK: - Public Methods

    func startMonitoring() {
        guard !isMonitoring else { return }

        log.info("Starting network log monitoring")
        isMonitoring = true

        if let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            log.info("App group container resolved: \(containerURL.path, privacy: .public)")
        } else {
            log.error("App group container unavailable for \(appGroupID, privacy: .public)")
        }

        logFileURL = resolveLogFileURL()
        lastFileOffset = 0
        pendingLineFragment = ""
        didLogMissingLogFile = false

        if let logFileURL = logFileURL {
            log.info("Log file path: \(logFileURL.path, privacy: .public)")
        } else {
            log.error("Log file path unavailable for \(appGroupID, privacy: .public)")
        }

        // Poll the shared log file for new entries from the extension
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.fetchLogsFromExtension()
            }
        }
        registerNotificationObserver()
        startUDPListener()
        fetchLogsFromExtension()
    }

    func stopMonitoring() {
        log.info("Stopping network log monitoring")
        isMonitoring = false
        timer?.invalidate()
        timer = nil
        unregisterNotificationObserver()
        stopUDPListener()
    }

    func clearLogs() {
        log.info("Clearing all logs (current count: \(self.logs.count, privacy: .public))")
        logs.removeAll()
        lastFileOffset = 0
        pendingLineFragment = ""

        if let logFileURL = logFileURL {
            do {
                try FileManager.default.removeItem(at: logFileURL)
                log.info("Removed log file at \(logFileURL.path, privacy: .public)")
            } catch {
                log.error("Failed to remove log file: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func exportLogs() -> String {
        let dateFormatter = ISO8601DateFormatter()
        log.info("Exporting \(self.logs.count, privacy: .public) log entries to CSV")
        var csv = "Timestamp,Source App,Remote Host,Port,Direction,Action\n"

        for entry in logs {
            csv += "\(dateFormatter.string(from: entry.timestamp)),"
            csv += "\"\(entry.sourceApp)\","
            csv += "\"\(entry.remoteHost)\","
            csv += "\(entry.remotePort),"
            csv += "\(entry.direction),"
            csv += "\(entry.action)\n"
        }

        return csv
    }

    // MARK: - Private Methods

    private func fetchLogsFromExtension() {
        if didReceiveNotificationLog || didReceiveLiveLog {
            return
        }

        guard let logFileURL = logFileURL ?? resolveLogFileURL() else {
            if !didLogMissingLogFile {
                didLogMissingLogFile = true
                log.error("Log file path unavailable for \(appGroupID, privacy: .public)")
            }
            return
        }

        self.logFileURL = logFileURL

        guard FileManager.default.fileExists(atPath: logFileURL.path) else {
            if !didLogMissingLogFile {
                didLogMissingLogFile = true
                log.info("Log file not found yet at \(logFileURL.path, privacy: .public)")
            }
            return
        }

        didLogMissingLogFile = false

        do {
            let fileHandle = try FileHandle(forReadingFrom: logFileURL)
            defer { try? fileHandle.close() }

            let fileSize = try fileHandle.seekToEnd()
            if fileSize < lastFileOffset {
                lastFileOffset = 0
                pendingLineFragment = ""
            }

            guard fileSize > lastFileOffset else {
                return
            }

            try fileHandle.seek(toOffset: lastFileOffset)
            let data = try fileHandle.readToEnd() ?? Data()
            lastFileOffset = fileSize

            appendLogEntries(from: data)
        } catch {
            log.error("Failed to read log file: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func resolveLogFileURL() -> URL? {
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            return nil
        }

        return containerURL
            .appendingPathComponent("Library/Caches", isDirectory: true)
            .appendingPathComponent(logFileName)
    }

    private func appendLogEntries(from data: Data) {
        guard !data.isEmpty else { return }

        let text = pendingLineFragment + String(decoding: data, as: UTF8.self)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)

        if text.hasSuffix("\n") {
            pendingLineFragment = ""
        } else {
            pendingLineFragment = String(lines.popLast() ?? "")
        }

        var newEntries: [ConnectionLogEntry] = []

        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedLine.isEmpty || trimmedLine.hasPrefix("timestamp,") {
                continue
            }

            if let entry = parseLogLine(trimmedLine) {
                newEntries.append(entry)
            }
        }

        guard !newEntries.isEmpty else { return }

        log.info("Parsed \(newEntries.count, privacy: .public) log entries from file")
        logs.insert(contentsOf: newEntries.reversed(), at: 0)

        if logs.count > maxLogs {
            log.info("Trimming logs from \(self.logs.count, privacy: .public) to \(self.maxLogs, privacy: .public)")
            logs = Array(logs.prefix(maxLogs))
        }
    }

    private func parseLogLine(_ line: String) -> ConnectionLogEntry? {
        let fields = line.split(separator: ",", omittingEmptySubsequences: false)
        guard fields.count >= 6 else { return nil }

        let timestampString = String(fields[0])
        let app = String(fields[1])
        let remoteHost = String(fields[2])
        let remotePort = String(fields[3])
        let direction = String(fields[4])
        let action = String(fields[5])

        let timestamp = timestampFormatter.date(from: timestampString) ?? Date()

        return ConnectionLogEntry(
            timestamp: timestamp,
            sourceApp: app,
            remoteHost: remoteHost,
            remotePort: remotePort,
            direction: direction,
            action: action
        )
    }

    private func registerNotificationObserver() {
        guard notificationObserver == nil else { return }

        notificationObserver = DistributedNotificationCenter.default().addObserver(
            forName: connectionNotificationName,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleDistributedLogNotification(notification)
        }
        log.info("Registered distributed log observer")
    }

    private func unregisterNotificationObserver() {
        guard let observer = notificationObserver else { return }
        DistributedNotificationCenter.default().removeObserver(observer)
        notificationObserver = nil
        log.info("Removed distributed log observer")
    }

    private func handleDistributedLogNotification(_ notification: Notification) {
        guard let userInfo = notification.userInfo else { return }

        didReceiveNotificationLog = true
        didReceiveLiveLog = true
        guard let entry = parseNotification(userInfo) else { return }

        log.debug("Received distributed log notification")
        logs.insert(entry, at: 0)
        if logs.count > maxLogs {
            log.info("Trimming logs from \(self.logs.count, privacy: .public) to \(self.maxLogs, privacy: .public)")
            logs = Array(logs.prefix(maxLogs))
        }
    }

    private func parseNotification(_ userInfo: [AnyHashable: Any]) -> ConnectionLogEntry? {
        let timestamp = userInfo["timestamp"] as? TimeInterval ?? Date().timeIntervalSince1970
        let sourceApp = userInfo["sourceAppIdentifier"] as? String ?? "Unknown"
        let remoteHost = userInfo["remoteHost"] as? String ?? "Unknown"
        let remotePort = userInfo["remotePort"] as? String ?? "0"
        let direction = userInfo["direction"] as? String ?? "unknown"
        let action = userInfo["action"] as? String ?? "allowed"

        return ConnectionLogEntry(
            timestamp: Date(timeIntervalSince1970: timestamp),
            sourceApp: sourceApp,
            remoteHost: remoteHost,
            remotePort: remotePort,
            direction: direction,
            action: action
        )
    }

    private func startUDPListener() {
        guard udpListener == nil else { return }

        udpListener = UDPLogListener(
            port: udpLogPort,
            onMessage: { [weak self] data in
                Task { @MainActor in
                    self?.handleUDPMessage(data)
                }
            },
            onState: { [weak self] state in
                Task { @MainActor in
                    self?.log.info("UDP listener state: \(self?.describeListenerState(state) ?? "unknown", privacy: .public)")
                }
            },
            onError: { [weak self] message in
                Task { @MainActor in
                    self?.log.error("\(message, privacy: .public)")
                }
            },
            onConnection: { [weak self] in
                Task { @MainActor in
                    self?.log.info("UDP listener accepted connection")
                }
            }
        )
        udpListener?.start()
        log.info("Starting UDP log listener on port \(self.udpLogPort.rawValue, privacy: .public)")
    }

    private func stopUDPListener() {
        udpListener?.stop()
        udpListener = nil
        log.info("Stopped UDP log listener")
    }

    private func handleUDPMessage(_ data: Data) {
        guard !data.isEmpty else { return }
        guard let object = try? JSONSerialization.jsonObject(with: data, options: []),
              let userInfo = object as? [AnyHashable: Any],
              let entry = parseNotification(userInfo) else {
            log.error("Failed to decode UDP log payload")
            return
        }

        didReceiveLiveLog = true
        if !didLogFirstUDPReceipt {
            didLogFirstUDPReceipt = true
            log.info("Received UDP log payload (\(data.count, privacy: .public) bytes)")
        } else {
            log.debug("Received UDP log payload (\(data.count, privacy: .public) bytes)")
        }
        logs.insert(entry, at: 0)

        if logs.count > maxLogs {
            log.info("Trimming logs from \(self.logs.count, privacy: .public) to \(self.maxLogs, privacy: .public)")
            logs = Array(logs.prefix(maxLogs))
        }
    }

    private func describeListenerState(_ state: NWListener.State) -> String {
        switch state {
        case .setup:
            return "setup"
        case .waiting(let error):
            return "waiting (\(error.localizedDescription))"
        case .ready:
            return "ready"
        case .failed(let error):
            return "failed (\(error.localizedDescription))"
        case .cancelled:
            return "cancelled"
        @unknown default:
            return "unknown"
        }
    }

    // MARK: - Demo Data (for testing UI)

    func addDemoLog() {
        log.info("Adding demo log entry")
        let demoApps = ["Safari", "Chrome", "Slack", "Spotify", "Mail", "Messages"]
        let demoHosts = ["api.apple.com", "www.google.com", "slack.com", "spotify.com", "imap.gmail.com"]
        let demoPorts = ["443", "80", "993", "8080"]
        let demoDirections = ["outbound", "inbound"]

        let entry = ConnectionLogEntry(
            sourceApp: demoApps.randomElement()!,
            remoteHost: demoHosts.randomElement()!,
            remotePort: demoPorts.randomElement()!,
            direction: demoDirections.randomElement()!
        )

        logs.insert(entry, at: 0)

        if logs.count > maxLogs {
            logs = Array(logs.prefix(maxLogs))
        }
    }
}

private final class UDPLogListener {
    private let port: NWEndpoint.Port
    private let queue = DispatchQueue(label: "com.safeme.NetworkAnalyzer.udpListener")
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private let onMessage: (Data) -> Void
    private let onState: (NWListener.State) -> Void
    private let onError: (String) -> Void
    private let onConnection: () -> Void

    init(
        port: NWEndpoint.Port,
        onMessage: @escaping (Data) -> Void,
        onState: @escaping (NWListener.State) -> Void,
        onError: @escaping (String) -> Void,
        onConnection: @escaping () -> Void
    ) {
        self.port = port
        self.onMessage = onMessage
        self.onState = onState
        self.onError = onError
        self.onConnection = onConnection
    }

    func start() {
        do {
            let listener = try NWListener(using: .udp, on: port)
            listener.stateUpdateHandler = { [weak self] state in
                self?.onState(state)
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            onError("Failed to start UDP listener: \(error.localizedDescription)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        connections.forEach { $0.cancel() }
        connections.removeAll()
    }

    private func handleConnection(_ connection: NWConnection) {
        connections.append(connection)
        onConnection()
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self = self, let connection = connection else { return }
            switch state {
            case .failed, .cancelled:
                self.removeConnection(connection)
            default:
                break
            }
        }
        connection.start(queue: queue)
        receiveNextMessage(on: connection)
    }

    private func receiveNextMessage(on connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] data, _, _, error in
            guard let self = self, let connection = connection else { return }

            if let data = data, !data.isEmpty {
                self.onMessage(data)
            }

            if let error = error {
                self.onError("UDP receive failed: \(error.localizedDescription)")
                connection.cancel()
                self.removeConnection(connection)
                return
            }

            self.receiveNextMessage(on: connection)
        }
    }

    private func removeConnection(_ connection: NWConnection) {
        connections.removeAll { $0 === connection }
    }
}
