//
//  BlockListManager.swift
//  NetworkAnalyzer
//
//  Manages blocked apps and IPs, shared between main app and extension
//

import Foundation
import os.log

struct BlockList: Codable, Equatable {
    var blockedApps: Set<String>  // Bundle identifiers
    var blockedHosts: Set<String>  // IP addresses or hostnames
    var lastModified: Date

    init() {
        blockedApps = []
        blockedHosts = []
        lastModified = Date()
    }
}

@MainActor
class BlockListManager: ObservableObject {
    static let shared = BlockListManager()

    private let log = Logger(subsystem: "com.safeme.NetworkAnalyzer", category: "BlockListManager")
    private let appGroupID = "group.com.safeme.NetworkAnalyzer"
    private let blockListFileName = "block_list.json"
    private var fileURL: URL?

    @Published private(set) var blockList = BlockList()

    private init() {
        setupFileURL()
        loadBlockList()
        startWatchingForChanges()
    }

    // MARK: - Public API

    var blockedApps: Set<String> {
        blockList.blockedApps
    }

    var blockedHosts: Set<String> {
        blockList.blockedHosts
    }

    func isAppBlocked(_ appIdentifier: String) -> Bool {
        blockList.blockedApps.contains(appIdentifier)
    }

    func isHostBlocked(_ host: String) -> Bool {
        blockList.blockedHosts.contains(host)
    }

    func blockApp(_ appIdentifier: String) {
        guard !appIdentifier.isEmpty else { return }
        log.info("Blocking app: \(appIdentifier, privacy: .public)")
        blockList.blockedApps.insert(appIdentifier)
        blockList.lastModified = Date()
        saveBlockList()
    }

    func unblockApp(_ appIdentifier: String) {
        log.info("Unblocking app: \(appIdentifier, privacy: .public)")
        blockList.blockedApps.remove(appIdentifier)
        blockList.lastModified = Date()
        saveBlockList()
    }

    func blockHost(_ host: String) {
        guard !host.isEmpty else { return }
        log.info("Blocking host: \(host, privacy: .public)")
        blockList.blockedHosts.insert(host)
        blockList.lastModified = Date()
        saveBlockList()
    }

    func unblockHost(_ host: String) {
        log.info("Unblocking host: \(host, privacy: .public)")
        blockList.blockedHosts.remove(host)
        blockList.lastModified = Date()
        saveBlockList()
    }

    func toggleAppBlock(_ appIdentifier: String) {
        if isAppBlocked(appIdentifier) {
            unblockApp(appIdentifier)
        } else {
            blockApp(appIdentifier)
        }
    }

    func toggleHostBlock(_ host: String) {
        if isHostBlocked(host) {
            unblockHost(host)
        } else {
            blockHost(host)
        }
    }

    // MARK: - Private Methods

    private func setupFileURL() {
        // Use system-wide location accessible to both app and extension
        let sharedDir = URL(fileURLWithPath: "/Library/Application Support/NetworkAnalyzer", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: sharedDir, withIntermediateDirectories: true)
        } catch {
            log.error("Failed to create shared directory: \(error.localizedDescription, privacy: .public)")
        }

        fileURL = sharedDir.appendingPathComponent(blockListFileName)
        log.info("Block list file: \(self.fileURL?.path ?? "nil", privacy: .public)")
    }

    private func loadBlockList() {
        guard let fileURL = fileURL else { return }

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            log.info("Block list file not found, using empty list")
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            blockList = try decoder.decode(BlockList.self, from: data)
            log.info("Loaded block list: \(self.blockList.blockedApps.count, privacy: .public) apps, \(self.blockList.blockedHosts.count, privacy: .public) hosts")
        } catch {
            log.error("Failed to load block list: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func saveBlockList() {
        guard let fileURL = fileURL else { return }

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(blockList)
            try data.write(to: fileURL, options: .atomic)
            log.info("Saved block list: \(self.blockList.blockedApps.count, privacy: .public) apps, \(self.blockList.blockedHosts.count, privacy: .public) hosts")

            // Post Darwin notification for extension to pick up changes (works across sandbox)
            let center = CFNotificationCenterGetDarwinNotifyCenter()
            CFNotificationCenterPostNotification(center, CFNotificationName("com.safeme.NetworkAnalyzer.blockListChanged" as CFString), nil, nil, true)
            log.debug("Posted Darwin notification for block list change")
        } catch {
            log.error("Failed to save block list: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func startWatchingForChanges() {
        // Watch for changes from the extension
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.safeme.NetworkAnalyzer.blockListChanged"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.loadBlockList()
        }
    }
}

