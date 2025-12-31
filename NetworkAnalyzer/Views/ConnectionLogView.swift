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

    @State private var searchText = ""
    @State private var selectedDirection: String? = nil
    private let log = Logger(subsystem: "com.safeme.NetworkAnalyzer", category: "ConnectionLogView")

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                // Search
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search logs...", text: $searchText)
                        .textFieldStyle(.plain)
                }
                .padding(8)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(8)

                Spacer()

                // Filter by direction
                Picker("Direction", selection: $selectedDirection) {
                    Text("All").tag(nil as String?)
                    Text("Outbound").tag("outbound" as String?)
                    Text("Inbound").tag("inbound" as String?)
                }
                .pickerStyle(.segmented)
                .frame(width: 200)

                // Actions
                Button {
                    log.info("User requested clear logs")
                    logger.clearLogs()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                .disabled(logger.logs.isEmpty)

                Button {
                    log.info("User requested export logs")
                    exportLogs()
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
                .disabled(logger.logs.isEmpty)

                // Demo button for testing
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
            .padding()

            Divider()

            // Log List
            if filteredLogs.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("No Connections Logged")
                        .font(.headline)
                    Text("Network connections will appear here when the filter is active")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(filteredLogs) {
                    TableColumn("Time") { log in
                        Text(formatTime(log.timestamp))
                            .font(.system(.caption, design: .monospaced))
                    }
                    .width(min: 80, max: 100)

                    TableColumn("App") { log in
                        Text(formatAppName(log.sourceApp))
                            .lineLimit(1)
                    }
                    .width(min: 100, max: 150)

                    TableColumn("Remote Host") { log in
                        Text(log.remoteHost)
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(1)
                    }
                    .width(min: 150, ideal: 200)

                    TableColumn("Port") { log in
                        Text(log.remotePort)
                            .font(.system(.body, design: .monospaced))
                    }
                    .width(min: 50, max: 70)

                    TableColumn("Direction") { log in
                        HStack(spacing: 4) {
                            Image(systemName: log.direction == "outbound" ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                                .foregroundStyle(log.direction == "outbound" ? .blue : .green)
                            Text(log.direction.capitalized)
                        }
                    }
                    .width(min: 90, max: 110)

                    TableColumn("Action") { log in
                        Text(log.action.capitalized)
                            .foregroundStyle(log.action == "allowed" ? .green : .red)
                    }
                    .width(min: 70, max: 90)
                }
            }

            Divider()

            // Status Bar
            HStack {
                Circle()
                    .fill(logger.isMonitoring ? .green : .secondary)
                    .frame(width: 8, height: 8)
                Text(logger.isMonitoring ? "Monitoring Active" : "Monitoring Inactive")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Text("\(filteredLogs.count) connections")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor))
        }
    }

    // MARK: - Filtered Logs

    private var filteredLogs: [ConnectionLogEntry] {
        var logs = logger.logs

        // Filter by direction
        if let direction = selectedDirection {
            logs = logs.filter { $0.direction == direction }
        }

        // Filter by search text
        if !searchText.isEmpty {
            logs = logs.filter { log in
                log.sourceApp.localizedCaseInsensitiveContains(searchText) ||
                log.remoteHost.localizedCaseInsensitiveContains(searchText) ||
                log.remotePort.contains(searchText)
            }
        }

        return logs
    }

    // MARK: - Helpers

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    private func formatAppName(_ identifier: String) -> String {
        // Extract app name from bundle identifier
        if identifier.contains(".") {
            return identifier.components(separatedBy: ".").last ?? identifier
        }
        return identifier
    }

    private func exportLogs() {
        let csv = logger.exportLogs()

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
}
