//
//  IPInfoService.swift
//  NetworkAnalyzer
//
//  Provides IP address information including reverse DNS, ASN, and organization details
//

import Foundation
import Network
import os.log

struct IPInfo: Codable, Equatable {
    let ip: String
    let hostname: String?
    let asn: Int?
    let asnOrg: String?
    let company: String?
    let companyType: String?
    let country: String?
    let city: String?
    let isDatacenter: Bool?
    let isVPN: Bool?
    let isProxy: Bool?
    let isTor: Bool?
    let lastUpdated: Date

    var displayName: String {
        if let company = company, !company.isEmpty {
            return company
        }
        if let asnOrg = asnOrg, !asnOrg.isEmpty {
            return asnOrg
        }
        if let hostname = hostname, !hostname.isEmpty {
            return hostname
        }
        return ip
    }

    var shortDescription: String {
        var parts: [String] = []
        if let company = company, !company.isEmpty {
            parts.append(company)
        } else if let asnOrg = asnOrg, !asnOrg.isEmpty {
            parts.append(asnOrg)
        }
        if let country = country, !country.isEmpty {
            parts.append(country)
        }
        return parts.isEmpty ? ip : parts.joined(separator: " · ")
    }
}

@MainActor
class IPInfoService: ObservableObject {
    static let shared = IPInfoService()

    private let log = Logger(subsystem: "com.safeme.NetworkAnalyzer", category: "IPInfoService")
    private let cache = NSCache<NSString, CachedIPInfo>()
    private var pendingRequests: [String: Task<IPInfo?, Never>] = [:]
    private let apiBaseURL = "https://api.ipapi.is"
    private let cacheExpirationSeconds: TimeInterval = 3600 * 24  // 24 hours

    // Track API usage
    private var apiRequestCount = 0
    private var lastAPIResetDate = Date()
    private let maxDailyRequests = 900  // Leave some buffer from 1000 limit

    private init() {
        cache.countLimit = 1000
    }

    // MARK: - Public API

    func getInfo(for ip: String) async -> IPInfo? {
        // Check cache first
        if let cached = cache.object(forKey: ip as NSString) {
            if Date().timeIntervalSince(cached.info.lastUpdated) < cacheExpirationSeconds {
                return cached.info
            }
        }

        // Check if there's already a pending request
        if let pendingTask = pendingRequests[ip] {
            return await pendingTask.value
        }

        // Create new request
        let task = Task<IPInfo?, Never> {
            await fetchIPInfo(for: ip)
        }
        pendingRequests[ip] = task

        let result = await task.value
        pendingRequests.removeValue(forKey: ip)

        return result
    }

    func getCachedInfo(for ip: String) -> IPInfo? {
        guard let cached = cache.object(forKey: ip as NSString) else { return nil }
        return cached.info
    }

    // MARK: - Private Methods

    private func fetchIPInfo(for ip: String) async -> IPInfo? {
        // Skip private/local IPs
        if isPrivateIP(ip) {
            let info = IPInfo(
                ip: ip,
                hostname: nil,
                asn: nil,
                asnOrg: nil,
                company: "Local Network",
                companyType: "local",
                country: nil,
                city: nil,
                isDatacenter: false,
                isVPN: false,
                isProxy: false,
                isTor: false,
                lastUpdated: Date()
            )
            cache.setObject(CachedIPInfo(info: info), forKey: ip as NSString)
            return info
        }

        // First try reverse DNS (fast, no API limit)
        let hostname = await reverseDNSLookup(ip: ip)

        // Check API rate limit
        resetDailyCounterIfNeeded()
        guard apiRequestCount < maxDailyRequests else {
            log.warning("API rate limit reached, using hostname only")
            let info = IPInfo(
                ip: ip,
                hostname: hostname,
                asn: nil,
                asnOrg: nil,
                company: nil,
                companyType: nil,
                country: nil,
                city: nil,
                isDatacenter: nil,
                isVPN: nil,
                isProxy: nil,
                isTor: nil,
                lastUpdated: Date()
            )
            cache.setObject(CachedIPInfo(info: info), forKey: ip as NSString)
            return info
        }

        // Fetch from API
        let apiInfo = await fetchFromAPI(ip: ip)

        let info = IPInfo(
            ip: ip,
            hostname: hostname ?? apiInfo?.hostname,
            asn: apiInfo?.asn,
            asnOrg: apiInfo?.asnOrg,
            company: apiInfo?.company,
            companyType: apiInfo?.companyType,
            country: apiInfo?.country,
            city: apiInfo?.city,
            isDatacenter: apiInfo?.isDatacenter,
            isVPN: apiInfo?.isVPN,
            isProxy: apiInfo?.isProxy,
            isTor: apiInfo?.isTor,
            lastUpdated: Date()
        )

        cache.setObject(CachedIPInfo(info: info), forKey: ip as NSString)
        return info
    }

    private func reverseDNSLookup(ip: String) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var hints = addrinfo()
                hints.ai_family = AF_UNSPEC
                hints.ai_socktype = SOCK_STREAM
                hints.ai_flags = AI_NUMERICHOST

                var result: UnsafeMutablePointer<addrinfo>?
                let status = getaddrinfo(ip, nil, &hints, &result)

                guard status == 0, let addrInfo = result else {
                    continuation.resume(returning: nil)
                    return
                }

                defer { freeaddrinfo(result) }

                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let lookupStatus = getnameinfo(
                    addrInfo.pointee.ai_addr,
                    addrInfo.pointee.ai_addrlen,
                    &hostname,
                    socklen_t(hostname.count),
                    nil,
                    0,
                    0
                )

                if lookupStatus == 0 {
                    let name = String(cString: hostname)
                    // Don't return the IP as hostname
                    if name != ip {
                        continuation.resume(returning: name)
                        return
                    }
                }

                continuation.resume(returning: nil)
            }
        }
    }

    private func fetchFromAPI(ip: String) async -> APIResponse? {
        guard let url = URL(string: "\(apiBaseURL)/?q=\(ip)") else { return nil }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                log.error("API request failed for \(ip, privacy: .public)")
                return nil
            }

            apiRequestCount += 1
            log.debug("API request \(self.apiRequestCount, privacy: .public) for \(ip, privacy: .public)")

            let decoder = JSONDecoder()
            let apiResponse = try decoder.decode(APIResponseRaw.self, from: data)

            return APIResponse(
                hostname: apiResponse.rdns,
                asn: apiResponse.asn?.asn,
                asnOrg: apiResponse.asn?.org,
                company: apiResponse.company?.name,
                companyType: apiResponse.company?.type,
                country: apiResponse.location?.country,
                city: apiResponse.location?.city,
                isDatacenter: apiResponse.is_datacenter,
                isVPN: apiResponse.is_vpn,
                isProxy: apiResponse.is_proxy,
                isTor: apiResponse.is_tor
            )
        } catch {
            log.error("Failed to fetch IP info: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func isPrivateIP(_ ip: String) -> Bool {
        // Check for IPv4 private ranges
        if ip.hasPrefix("10.") ||
           ip.hasPrefix("192.168.") ||
           ip.hasPrefix("127.") ||
           ip.hasPrefix("169.254.") {
            return true
        }

        // Check 172.16.0.0 - 172.31.255.255
        if ip.hasPrefix("172.") {
            let parts = ip.split(separator: ".")
            if parts.count >= 2, let second = Int(parts[1]) {
                if second >= 16 && second <= 31 {
                    return true
                }
            }
        }

        // IPv6 loopback and link-local
        if ip == "::1" || ip.hasPrefix("fe80:") || ip.hasPrefix("fc") || ip.hasPrefix("fd") {
            return true
        }

        return false
    }

    private func resetDailyCounterIfNeeded() {
        let calendar = Calendar.current
        if !calendar.isDate(lastAPIResetDate, inSameDayAs: Date()) {
            apiRequestCount = 0
            lastAPIResetDate = Date()
            log.info("Reset daily API counter")
        }
    }
}

// MARK: - Cache Helper

private class CachedIPInfo {
    let info: IPInfo
    init(info: IPInfo) {
        self.info = info
    }
}

// MARK: - API Response Models

private struct APIResponseRaw: Codable {
    let ip: String?
    let rdns: String?
    let asn: ASNInfo?
    let company: CompanyInfo?
    let location: LocationInfo?
    let is_datacenter: Bool?
    let is_vpn: Bool?
    let is_proxy: Bool?
    let is_tor: Bool?
}

private struct ASNInfo: Codable {
    let asn: Int?
    let org: String?
    let route: String?
}

private struct CompanyInfo: Codable {
    let name: String?
    let type: String?
}

private struct LocationInfo: Codable {
    let country: String?
    let city: String?
    let state: String?
    let timezone: String?
}

private struct APIResponse {
    let hostname: String?
    let asn: Int?
    let asnOrg: String?
    let company: String?
    let companyType: String?
    let country: String?
    let city: String?
    let isDatacenter: Bool?
    let isVPN: Bool?
    let isProxy: Bool?
    let isTor: Bool?
}
