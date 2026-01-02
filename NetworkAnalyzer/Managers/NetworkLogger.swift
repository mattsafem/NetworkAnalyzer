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
    let localHost: String?
    let localPort: String?
    let remoteHostname: String?
    let protocolName: String?
    let socketFamily: Int?
    let socketType: Int?
    let socketProtocol: Int?
    let pid: Int?
    let processPath: String?
    let processName: String?
    let flowIdentifier: String?
    let url: String?
    let tokenSource: String?

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        sourceApp: String,
        remoteHost: String,
        remotePort: String,
        direction: String,
        action: String = "allowed",
        localHost: String? = nil,
        localPort: String? = nil,
        remoteHostname: String? = nil,
        protocolName: String? = nil,
        socketFamily: Int? = nil,
        socketType: Int? = nil,
        socketProtocol: Int? = nil,
        pid: Int? = nil,
        processPath: String? = nil,
        processName: String? = nil,
        flowIdentifier: String? = nil,
        url: String? = nil,
        tokenSource: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.sourceApp = sourceApp
        self.remoteHost = remoteHost
        self.remotePort = remotePort
        self.direction = direction
        self.action = action
        self.localHost = localHost
        self.localPort = localPort
        self.remoteHostname = remoteHostname
        self.protocolName = protocolName
        self.socketFamily = socketFamily
        self.socketType = socketType
        self.socketProtocol = socketProtocol
        self.pid = pid
        self.processPath = processPath
        self.processName = processName
        self.flowIdentifier = flowIdentifier
        self.url = url
        self.tokenSource = tokenSource
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

    func clearLogs(appIdentifier: String?) {
        guard let appIdentifier = appIdentifier else {
            clearLogs()
            return
        }

        log.info("Clearing logs for app \(appIdentifier, privacy: .public)")
        logs.removeAll { $0.sourceApp == appIdentifier }
    }

    func exportLogs() -> String {
        let dateFormatter = ISO8601DateFormatter()
        log.info("Exporting \(self.logs.count, privacy: .public) log entries to CSV")
        var csv = "Timestamp,Source App,Remote Host,Port,Direction,Action,Local Host,Local Port,Remote Hostname,Protocol,Socket Family,Socket Type,Socket Protocol,PID,Process Path,Process Name,Flow ID,URL,Token Source\n"

        for entry in logs {
            csv += "\(escapeCSV(dateFormatter.string(from: entry.timestamp))),"
            csv += "\(escapeCSV(entry.sourceApp)),"
            csv += "\(escapeCSV(entry.remoteHost)),"
            csv += "\(escapeCSV(entry.remotePort)),"
            csv += "\(escapeCSV(entry.direction)),"
            csv += "\(escapeCSV(entry.action)),"
            csv += "\(escapeCSV(entry.localHost ?? "")),"
            csv += "\(escapeCSV(entry.localPort ?? "")),"
            csv += "\(escapeCSV(entry.remoteHostname ?? "")),"
            csv += "\(escapeCSV(entry.protocolName ?? "")),"
            csv += "\(escapeCSV(entry.socketFamily.map(String.init) ?? "")),"
            csv += "\(escapeCSV(entry.socketType.map(String.init) ?? "")),"
            csv += "\(escapeCSV(entry.socketProtocol.map(String.init) ?? "")),"
            csv += "\(escapeCSV(entry.pid.map(String.init) ?? "")),"
            csv += "\(escapeCSV(entry.processPath ?? "")),"
            csv += "\(escapeCSV(entry.processName ?? "")),"
            csv += "\(escapeCSV(entry.flowIdentifier ?? "")),"
            csv += "\(escapeCSV(entry.url ?? "")),"
            csv += "\(escapeCSV(entry.tokenSource ?? ""))\n"
        }

        return csv
    }

    /// RFC 4180 compliant CSV escaping
    private func escapeCSV(_ value: String) -> String {
        let needsQuoting = value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r")
        if needsQuoting {
            let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        return value
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
        let fields = parseCSVLine(line)
        guard fields.count >= 6 else { return nil }

        let timestampString = fields[0]
        let app = fields[1]
        let remoteHost = fields[2]
        let remotePort = fields[3]
        let direction = fields[4]
        let action = fields[5]
        let localHost = stringFieldFromParsed(fields, index: 6)
        let localPort = stringFieldFromParsed(fields, index: 7)
        let remoteHostname = stringFieldFromParsed(fields, index: 8)
        let protocolName = stringFieldFromParsed(fields, index: 9)
        let socketFamily = intFieldFromParsed(fields, index: 10)
        let socketType = intFieldFromParsed(fields, index: 11)
        let socketProtocol = intFieldFromParsed(fields, index: 12)
        let pid = intFieldFromParsed(fields, index: 13)
        let processPath = stringFieldFromParsed(fields, index: 14)
        let processName = stringFieldFromParsed(fields, index: 15)
        let flowIdentifier = stringFieldFromParsed(fields, index: 16)
        let url = stringFieldFromParsed(fields, index: 17)
        let tokenSource = stringFieldFromParsed(fields, index: 18)

        let timestamp = timestampFormatter.date(from: timestampString) ?? Date()

        return ConnectionLogEntry(
            timestamp: timestamp,
            sourceApp: app,
            remoteHost: remoteHost,
            remotePort: remotePort,
            direction: direction,
            action: action,
            localHost: localHost,
            localPort: localPort,
            remoteHostname: remoteHostname,
            protocolName: protocolName,
            socketFamily: socketFamily,
            socketType: socketType,
            socketProtocol: socketProtocol,
            pid: pid,
            processPath: processPath,
            processName: processName,
            flowIdentifier: flowIdentifier,
            url: url,
            tokenSource: tokenSource
        )
    }

    /// RFC 4180 compliant CSV line parser
    private func parseCSVLine(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var iterator = line.makeIterator()

        while let char = iterator.next() {
            if inQuotes {
                if char == "\"" {
                    // Check if next char is also a quote (escaped quote)
                    if let next = iterator.next() {
                        if next == "\"" {
                            current.append("\"")
                        } else {
                            inQuotes = false
                            if next == "," {
                                fields.append(current)
                                current = ""
                            } else {
                                current.append(next)
                            }
                        }
                    } else {
                        inQuotes = false
                    }
                } else {
                    current.append(char)
                }
            } else {
                if char == "\"" {
                    inQuotes = true
                } else if char == "," {
                    fields.append(current)
                    current = ""
                } else {
                    current.append(char)
                }
            }
        }
        fields.append(current)
        return fields
    }

    private func stringFieldFromParsed(_ fields: [String], index: Int) -> String? {
        guard fields.count > index else { return nil }
        let value = fields[index]
        return value.isEmpty ? nil : value
    }

    private func intFieldFromParsed(_ fields: [String], index: Int) -> Int? {
        guard let value = stringFieldFromParsed(fields, index: index) else { return nil }
        return Int(value)
    }

    private func stringField(_ fields: [Substring], index: Int) -> String? {
        guard fields.count > index else { return nil }
        let value = String(fields[index])
        return value.isEmpty ? nil : value
    }

    private func intField(_ fields: [Substring], index: Int) -> Int? {
        guard let value = stringField(fields, index: index) else { return nil }
        return Int(value)
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
        let sourceApp = stringValue(userInfo["sourceAppIdentifier"]) ?? "Unknown"
        let remoteHost = stringValue(userInfo["remoteHost"]) ?? "Unknown"
        let remotePort = stringValue(userInfo["remotePort"]) ?? "0"
        let direction = stringValue(userInfo["direction"]) ?? "unknown"
        let action = stringValue(userInfo["action"]) ?? "allowed"
        let localHost = stringValue(userInfo["localHost"])
        let localPort = stringValue(userInfo["localPort"])
        let remoteHostname = stringValue(userInfo["remoteHostname"])
        let protocolName = stringValue(userInfo["protocolName"])
        let socketFamily = intValue(userInfo["socketFamily"])
        let socketType = intValue(userInfo["socketType"])
        let socketProtocol = intValue(userInfo["socketProtocol"])
        let pid = intValue(userInfo["pid"])
        let processPath = stringValue(userInfo["processPath"])
        let processName = stringValue(userInfo["processName"])
        let flowIdentifier = stringValue(userInfo["flowIdentifier"])
        let url = stringValue(userInfo["url"])
        let tokenSource = stringValue(userInfo["tokenSource"])

        return ConnectionLogEntry(
            timestamp: Date(timeIntervalSince1970: timestamp),
            sourceApp: sourceApp,
            remoteHost: remoteHost,
            remotePort: remotePort,
            direction: direction,
            action: action,
            localHost: localHost,
            localPort: localPort,
            remoteHostname: remoteHostname,
            protocolName: protocolName,
            socketFamily: socketFamily,
            socketType: socketType,
            socketProtocol: socketProtocol,
            pid: pid,
            processPath: processPath,
            processName: processName,
            flowIdentifier: flowIdentifier,
            url: url,
            tokenSource: tokenSource
        )
    }

    private func stringValue(_ value: Any?) -> String? {
        guard let value = value else { return nil }
        if let string = value as? String {
            return string.isEmpty ? nil : string
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return nil
    }

    private func intValue(_ value: Any?) -> Int? {
        if let intValue = value as? Int {
            return intValue
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let string = value as? String {
            return Int(string)
        }
        return nil
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
