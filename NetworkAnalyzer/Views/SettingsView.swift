//
//  SettingsView.swift
//  NetworkAnalyzer
//
//  Application settings view
//

import SwiftUI

struct SettingsView: View {
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("showInMenuBar") private var showInMenuBar = true
    @AppStorage("showNotifications") private var showNotifications = true
    @AppStorage("logRetentionDays") private var logRetentionDays = 7

    var body: some View {
        Form {
            Section {
                Toggle("Launch at Login", isOn: $launchAtLogin)
                Toggle("Show in Menu Bar", isOn: $showInMenuBar)
            } header: {
                Text("General")
            }

            Section {
                Toggle("Show Notifications", isOn: $showNotifications)
                    .help("Show notifications for blocked connections")
            } header: {
                Text("Notifications")
            }

            Section {
                Picker("Keep Logs For", selection: $logRetentionDays) {
                    Text("1 Day").tag(1)
                    Text("7 Days").tag(7)
                    Text("30 Days").tag(30)
                    Text("Forever").tag(0)
                }
            } header: {
                Text("Logging")
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("About NetworkAnalyzer")
                        .font(.headline)

                    Text("Version 1.0")
                        .foregroundStyle(.secondary)

                    Text("A network monitoring and filtering tool similar to Little Snitch and Radio Silence.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Divider()

                    Text("Required Setup:")
                        .font(.subheadline)
                        .fontWeight(.medium)

                    VStack(alignment: .leading, spacing: 4) {
                        Label("Install the app in /Applications", systemImage: "folder")
                        Label("Approve the system extension in System Settings", systemImage: "gearshape")
                        Label("Allow Content Filter in Network settings", systemImage: "network")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } header: {
                Text("Information")
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 400)
    }
}

#Preview {
    SettingsView()
}
