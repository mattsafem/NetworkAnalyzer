//
//  ConnectionLogView.swift
//  NetworkAnalyzer
//
//  Shows network connection logs
//

import SwiftUI
import os.log

struct ConnectionLogView: View {
    @ObservedObject var logger: NetworkLogger
    @StateObject private var ipInfoService = IPInfoService.shared
    @StateObject private var blockListManager = BlockListManager.shared

    @State private var appSearchText = ""
    @State private var logSearchText = ""
    @State private var selectedDirection: String? = nil
    @State private var selectedAppID: String? = nil
    @State private var selectedHostID: String? = nil
    @State private var reviewEntry: ConnectionLogEntry?
    @State private var ipInfoCache: [String: IPInfo] = [:]
    private let log = Logger(subsystem: "com.safeme.NetworkAnalyzer", category: "ConnectionLogView")

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                appListColumn
                Divider()
                logListColumn
            }

            Divider()

            HStack {
                Circle()
                    .fill(logger.isMonitoring ? .green : .secondary)
                    .frame(width: 8, height: 8)
                Text(logger.isMonitoring ? "Monitoring Active" : "Monitoring Inactive")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                if let selectedAppID = selectedAppID {
                    if let selectedHostID = selectedHostID {
                        Text("\(logsForSelectedHost.count) connections to \(selectedHostID)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("\(hostSummaries.count) hosts, \(logsForSelectedApp.count) connections for \(formatAppName(selectedAppID))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("No app selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .onAppear {
            updateSelectionIfNeeded()
        }
        .onReceive(logger.$logs) { _ in
            updateSelectionIfNeeded()
        }
        .onChange(of: appSearchText) { _, _ in
            updateSelectionIfNeeded()
        }
        .onChange(of: selectedAppID) { _, _ in
            selectedHostID = nil
        }
        .sheet(item: $reviewEntry) { entry in
            ConnectionLogReviewView(entry: entry)
        }
    }

    // MARK: - Filtered Logs

    private var logsForSelectedApp: [ConnectionLogEntry] {
        guard let selectedAppID = selectedAppID else { return [] }
        var logs = logger.logs.filter { $0.sourceApp == selectedAppID }

        // Filter by direction
        if let direction = selectedDirection {
            logs = logs.filter { $0.direction == direction }
        }

        // Filter by search text
        if !logSearchText.isEmpty {
            logs = logs.filter { log in
                log.remoteHost.localizedCaseInsensitiveContains(logSearchText) ||
                log.remotePort.contains(logSearchText)
            }
        }

        return logs
    }

    private var hostSummaries: [HostSummary] {
        var summaryMap: [String: (ports: Set<String>, count: Int, lastSeen: Date, hasInbound: Bool, hasOutbound: Bool)] = [:]

        for entry in logsForSelectedApp {
            let host = entry.remoteHost
            if var existing = summaryMap[host] {
                existing.ports.insert(entry.remotePort)
                existing.count += 1
                if entry.timestamp > existing.lastSeen {
                    existing.lastSeen = entry.timestamp
                }
                if entry.direction == "inbound" { existing.hasInbound = true }
                if entry.direction == "outbound" { existing.hasOutbound = true }
                summaryMap[host] = existing
            } else {
                summaryMap[host] = (
                    ports: [entry.remotePort],
                    count: 1,
                    lastSeen: entry.timestamp,
                    hasInbound: entry.direction == "inbound",
                    hasOutbound: entry.direction == "outbound"
                )
            }
        }

        return summaryMap.map { key, value in
            HostSummary(
                id: key,
                remoteHost: key,
                ports: value.ports,
                count: value.count,
                lastSeen: value.lastSeen,
                hasInbound: value.hasInbound,
                hasOutbound: value.hasOutbound
            )
        }.sorted {
            if $0.lastSeen != $1.lastSeen {
                return $0.lastSeen > $1.lastSeen
            }
            return $0.remoteHost < $1.remoteHost
        }
    }

    private var logsForSelectedHost: [ConnectionLogEntry] {
        guard let selectedHostID = selectedHostID else { return [] }
        return logsForSelectedApp.filter { $0.remoteHost == selectedHostID }
    }

    // MARK: - Helpers

    private var appSummaries: [AppSummary] {
        var summaryMap: [String: (count: Int, lastSeen: Date)] = [:]

        for entry in logger.logs {
            if var existing = summaryMap[entry.sourceApp] {
                existing.count += 1
                if entry.timestamp > existing.lastSeen {
                    existing.lastSeen = entry.timestamp
                }
                summaryMap[entry.sourceApp] = existing
            } else {
                summaryMap[entry.sourceApp] = (count: 1, lastSeen: entry.timestamp)
            }
        }

        // Add blocked apps that may not have any logs
        for blockedApp in blockListManager.blockedApps {
            if summaryMap[blockedApp] == nil {
                summaryMap[blockedApp] = (count: 0, lastSeen: Date.distantPast)
            }
        }

        var summaries = summaryMap.map { key, value in
            AppSummary(
                id: key,
                displayName: formatAppName(key),
                count: value.count,
                lastSeen: value.lastSeen,
                isBlocked: blockListManager.isAppBlocked(key)
            )
        }

        if !appSearchText.isEmpty {
            summaries = summaries.filter { summary in
                summary.displayName.localizedCaseInsensitiveContains(appSearchText) ||
                summary.id.localizedCaseInsensitiveContains(appSearchText)
            }
        }

        // Sort: blocked apps first, then by lastSeen
        return summaries.sorted {
            if $0.isBlocked != $1.isBlocked {
                return $0.isBlocked  // Blocked apps first
            }
            if $0.lastSeen != $1.lastSeen {
                return $0.lastSeen > $1.lastSeen
            }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    private func updateSelectionIfNeeded() {
        if appSummaries.isEmpty {
            selectedAppID = nil
            return
        }

        if let selectedAppID = selectedAppID,
           appSummaries.contains(where: { $0.id == selectedAppID }) {
            return
        }

        selectedAppID = appSummaries.first?.id
    }

    private var appListColumn: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search apps...", text: $appSearchText)
                    .textFieldStyle(.plain)
            }
            .padding(8)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)
            .padding()

            Divider()

            if appSummaries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "app.dashed")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("No Apps Yet")
                        .font(.headline)
                    Text("Apps will appear after connections are logged")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selectedAppID) {
                    ForEach(appSummaries) { summary in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 4) {
                                    Text(summary.displayName)
                                        .lineLimit(1)
                                    if blockListManager.isAppBlocked(summary.id) {
                                        Text("BLOCKED")
                                            .font(.caption2)
                                            .fontWeight(.semibold)
                                            .foregroundStyle(.white)
                                            .padding(.horizontal, 4)
                                            .padding(.vertical, 1)
                                            .background(Color.red)
                                            .clipShape(RoundedRectangle(cornerRadius: 3))
                                    }
                                }
                                Text(summary.id)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Text("\(summary.count)")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color(nsColor: .quaternaryLabelColor))
                                .clipShape(Capsule())
                        }
                        .tag(Optional(summary.id))
                        .contextMenu {
                            if blockListManager.isAppBlocked(summary.id) {
                                Button {
                                    blockListManager.unblockApp(summary.id)
                                } label: {
                                    Label("Unblock App", systemImage: "hand.raised.slash")
                                }
                            } else {
                                Button {
                                    blockListManager.blockApp(summary.id)
                                } label: {
                                    Label("Block App", systemImage: "hand.raised")
                                }
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 220, idealWidth: 240, maxWidth: 280)
    }

    private var logListColumn: some View {
        VStack(spacing: 0) {
            logListHeader
            Divider()
            logListContent
        }
    }

    private var logListHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if selectedHostID != nil {
                        Button {
                            selectedHostID = nil
                        } label: {
                            Image(systemName: "chevron.left")
                        }
                        .buttonStyle(.borderless)
                    }
                    Text(selectedHostID != nil ? "Connections" : "Hosts")
                        .font(.headline)
                }
                if let selectedAppID = selectedAppID {
                    if let selectedHostID = selectedHostID {
                        Text(selectedHostID)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text(selectedAppID)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                } else {
                    Text("Select an app to view its connections")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            HStack(spacing: 12) {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search...", text: $logSearchText)
                        .textFieldStyle(.plain)
                }
                .padding(8)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(8)

                Picker("Direction", selection: $selectedDirection) {
                    Text("All").tag(nil as String?)
                    Text("Outbound").tag("outbound" as String?)
                    Text("Inbound").tag("inbound" as String?)
                }
                .pickerStyle(.segmented)
                .frame(width: 200)

                Button {
                    log.info("User requested clear logs")
                    logger.clearLogs(appIdentifier: selectedAppID)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                .disabled(logsForSelectedApp.isEmpty)
                .help("Clear logs for selected app")

                Button {
                    log.info("User requested export logs")
                    exportLogs()
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
                .disabled(logsForSelectedApp.isEmpty)

                #if DEBUG
                Button {
                    log.info("User requested demo log entry")
                    logger.addDemoLog()
                } label: {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.bordered)
                #endif
            }
        }
        .padding()
    }

    @ViewBuilder
    private var logListContent: some View {
        if selectedAppID == nil {
            VStack(spacing: 12) {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("Select an App")
                    .font(.headline)
                Text("Choose an app on the left to view its connections")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if logsForSelectedApp.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("No Connections Logged")
                    .font(.headline)
                Text("Connections for this app will appear here")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let selectedHostID = selectedHostID {
            // Show individual connections for selected host
            connectionListForHost
        } else {
            // Show grouped hosts
            hostListView
        }
    }

    private var hostListView: some View {
        List(selection: $selectedHostID) {
            ForEach(hostSummaries) { summary in
                HostRowView(
                    summary: summary,
                    ipInfo: ipInfoCache[summary.remoteHost],
                    isBlocked: blockListManager.isHostBlocked(summary.remoteHost),
                    formatPorts: formatPorts,
                    formatTime: formatTime
                )
                .tag(Optional(summary.id))
                .contentShape(Rectangle())
                .task {
                    await fetchIPInfoIfNeeded(for: summary.remoteHost)
                }
                .contextMenu {
                    if blockListManager.isHostBlocked(summary.remoteHost) {
                        Button {
                            blockListManager.unblockHost(summary.remoteHost)
                        } label: {
                            Label("Unblock Host", systemImage: "hand.raised.slash")
                        }
                    } else {
                        Button {
                            blockListManager.blockHost(summary.remoteHost)
                        } label: {
                            Label("Block Host", systemImage: "hand.raised")
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    private func fetchIPInfoIfNeeded(for ip: String) async {
        guard ipInfoCache[ip] == nil else { return }
        if let info = await ipInfoService.getInfo(for: ip) {
            ipInfoCache[ip] = info
        }
    }

    private var connectionListForHost: some View {
        Table(logsForSelectedHost) {
            TableColumn("Time") { entry in
                Text(formatTime(entry.timestamp))
                    .font(.system(.caption, design: .monospaced))
            }
            .width(min: 80, max: 100)

            TableColumn("Port") { entry in
                Text(entry.remotePort)
                    .font(.system(.body, design: .monospaced))
            }
            .width(min: 50, max: 70)

            TableColumn("Direction") { entry in
                HStack(spacing: 4) {
                    Image(systemName: entry.direction == "outbound" ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                        .foregroundStyle(entry.direction == "outbound" ? .blue : .green)
                    Text(entry.direction.capitalized)
                }
            }
            .width(min: 90, max: 110)

            TableColumn("Protocol") { entry in
                Text(entry.protocolName ?? "—")
                    .font(.system(.body, design: .monospaced))
            }
            .width(min: 60, max: 80)

            TableColumn("Action") { entry in
                Text(entry.action.capitalized)
                    .foregroundStyle(entry.action == "allowed" ? .green : .red)
            }
            .width(min: 70, max: 90)

            TableColumn("") { entry in
                Button {
                    reviewEntry = entry
                } label: {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(.borderless)
                .help("Review")
            }
            .width(min: 24, max: 28)
        }
    }

    private func formatPorts(_ ports: Set<String>) -> String {
        let sortedPorts = ports.sorted { (Int($0) ?? 0) < (Int($1) ?? 0) }
        if sortedPorts.count <= 3 {
            return "Ports: " + sortedPorts.joined(separator: ", ")
        } else {
            return "Ports: " + sortedPorts.prefix(3).joined(separator: ", ") + " +\(sortedPorts.count - 3) more"
        }
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    private func formatAppName(_ identifier: String) -> String {
        if identifier.hasPrefix("process:") {
            let name = identifier.replacingOccurrences(of: "process:", with: "")
            if !name.isEmpty {
                return "\(name) (process)"
            }
        }

        // Extract app name from bundle identifier
        if identifier.contains(".") {
            return identifier.components(separatedBy: ".").last ?? identifier
        }
        return identifier
    }

    private func exportLogs() {
        let entries = selectedHostID != nil ? logsForSelectedHost : logsForSelectedApp
        guard !entries.isEmpty else { return }
        let csv = makeCSV(for: entries)

        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.commaSeparatedText]
        savePanel.nameFieldStringValue = "network_logs_\(Date().ISO8601Format()).csv"

        savePanel.begin { response in
            if response == .OK, let url = savePanel.url {
                do {
                    try csv.write(to: url, atomically: true, encoding: .utf8)
                    log.info("Exported logs to \(url.path, privacy: .public)")
                } catch {
                    log.error("Failed to save logs: \(error.localizedDescription, privacy: .public)")
                    print("Failed to save logs: \(error)")
                }
            } else {
                log.info("Export logs canceled by user")
            }
        }
    }

    private func makeCSV(for entries: [ConnectionLogEntry]) -> String {
        let dateFormatter = ISO8601DateFormatter()
        var csv = "Timestamp,Source App,Remote Host,Port,Direction,Action,Local Host,Local Port,Remote Hostname,Protocol,Socket Family,Socket Type,Socket Protocol,PID,Process Path,Process Name,Flow ID,URL,Token Source\n"

        for entry in entries {
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
}

private struct AppSummary: Identifiable {
    let id: String
    let displayName: String
    let count: Int
    let lastSeen: Date
    let isBlocked: Bool
}

private struct HostSummary: Identifiable {
    let id: String  // remoteHost
    let remoteHost: String
    let ports: Set<String>
    let count: Int
    let lastSeen: Date
    let hasInbound: Bool
    let hasOutbound: Bool
}

private struct HostRowView: View {
    let summary: HostSummary
    let ipInfo: IPInfo?
    let isBlocked: Bool
    let formatPorts: (Set<String>) -> String
    let formatTime: (Date) -> String

    var body: some View {
        HStack(spacing: 12) {
            // Direction indicators
            HStack(spacing: 2) {
                if summary.hasOutbound {
                    Image(systemName: "arrow.up.circle.fill")
                        .foregroundStyle(.blue)
                        .font(.caption)
                }
                if summary.hasInbound {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                }
            }
            .frame(width: 30)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(summary.remoteHost)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)

                    if isBlocked {
                        Text("BLOCKED")
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.red)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }

                    // Security indicators
                    if let ipInfo = ipInfo {
                        if ipInfo.isDatacenter == true {
                            Image(systemName: "server.rack")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .help("Datacenter")
                        }
                        if ipInfo.isVPN == true {
                            Image(systemName: "lock.shield")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                                .help("VPN")
                        }
                        if ipInfo.isTor == true {
                            Image(systemName: "network")
                                .font(.caption2)
                                .foregroundStyle(.purple)
                                .help("Tor")
                        }
                    }
                }

                // Show organization/company or hostname
                if let ipInfo = ipInfo {
                    if let company = ipInfo.company, !company.isEmpty {
                        HStack(spacing: 4) {
                            Text(company)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            if let country = ipInfo.country, !country.isEmpty {
                                Text("·")
                                    .foregroundStyle(.tertiary)
                                Text(country)
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    } else if let hostname = ipInfo.hostname, !hostname.isEmpty {
                        Text(hostname)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text(formatPorts(summary.ports))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                } else {
                    Text(formatPorts(summary.ports))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            // ASN badge if available
            if let ipInfo = ipInfo, let asn = ipInfo.asn {
                Text("AS\(asn)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color(nsColor: .systemGray).opacity(0.2))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }

            Text(formatTime(summary.lastSeen))
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("\(summary.count)")
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color(nsColor: .quaternaryLabelColor))
                .clipShape(Capsule())

            Image(systemName: "chevron.right")
                .foregroundStyle(.tertiary)
                .font(.caption)
        }
    }
}

private struct ConnectionLogReviewView: View {
    let entry: ConnectionLogEntry
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Connection Detail")
                    .font(.headline)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
            }

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                gridRow("Timestamp", value: formatTimestamp(entry.timestamp))
                gridRow("App", value: appDisplayName(entry.sourceApp))
                gridRow("Bundle ID", value: entry.sourceApp)
                gridRow("Process Name", value: entry.processName)
                gridRow("PID", value: entry.pid.map(String.init))
                gridRow("Process Path", value: entry.processPath)
                gridRow("Direction", value: entry.direction)
                gridRow("Action", value: entry.action)
                gridRow("Remote Host", value: entry.remoteHost)
                gridRow("Remote Port", value: entry.remotePort)
                gridRow("Remote Hostname", value: entry.remoteHostname)
                gridRow("Local Host", value: entry.localHost)
                gridRow("Local Port", value: entry.localPort)
                gridRow("Protocol", value: entry.protocolName)
                gridRow("Socket Family", value: entry.socketFamily.map(String.init))
                gridRow("Socket Type", value: entry.socketType.map(String.init))
                gridRow("Socket Protocol", value: entry.socketProtocol.map(String.init))
                gridRow("Flow ID", value: entry.flowIdentifier)
                gridRow("URL", value: entry.url)
                gridRow("Token Source", value: entry.tokenSource)
            }

            Spacer()
        }
        .padding(16)
        .frame(minWidth: 560, minHeight: 420)
    }

    @ViewBuilder
    private func gridRow(_ title: String, value: String?) -> some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
            Text(value?.isEmpty == false ? value! : "—")
                .textSelection(.enabled)
        }
    }

    private func formatTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter.string(from: date)
    }

    private func appDisplayName(_ identifier: String) -> String {
        if identifier.hasPrefix("process:") {
            let name = identifier.replacingOccurrences(of: "process:", with: "")
            if !name.isEmpty {
                return "\(name) (process)"
            }
        }

        if identifier.contains(".") {
            return identifier.components(separatedBy: ".").last ?? identifier
        }
        return identifier
    }
}
