//
//  NetworkProvider.swift
//  limen
//
//  Implementation of network monitoring using netstat and system APIs.
//

import Foundation
import Darwin
import Network

/// macOS implementation of NetworkProviding
public final class NetworkProvider: NetworkProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var previousStats: (timestamp: Date, bytesIn: UInt64, bytesOut: UInt64)?
    private var hostnameCache: [String: String] = [:]

    public init() {}

    // MARK: - NetworkProviding

    public func listConnections() async throws -> [NetworkConnection] {
        try await Task.detached(priority: .userInitiated) {
            try self.fetchConnections()
        }.value
    }

    public func listConnections(state: NetworkConnection.ConnectionState) async throws -> [NetworkConnection] {
        let all = try await listConnections()
        return all.filter { $0.state == state }
    }

    public func getConnections(forPid pid: Int32) async throws -> [NetworkConnection] {
        let all = try await listConnections()
        return all.filter { $0.pid == pid }
    }

    public func listInterfaces() async throws -> [NetworkInterface] {
        try await Task.detached(priority: .userInitiated) {
            self.fetchInterfaces()
        }.value
    }

    public func getStats() async throws -> NetworkStats {
        try await Task.detached(priority: .userInitiated) {
            try self.fetchStats()
        }.value
    }

    public func resolveHostname(for address: String) async -> String? {
        // Check cache first
        lock.lock()
        if let cached = hostnameCache[address] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        // Perform DNS lookup
        return await withCheckedContinuation { continuation in
            var hints = addrinfo()
            hints.ai_flags = AI_NUMERICHOST
            hints.ai_family = AF_UNSPEC

            var result: UnsafeMutablePointer<addrinfo>?

            guard getaddrinfo(address, nil, &hints, &result) == 0, let info = result else {
                continuation.resume(returning: nil)
                return
            }

            defer { freeaddrinfo(result) }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))

            let status = getnameinfo(
                info.pointee.ai_addr,
                info.pointee.ai_addrlen,
                &hostname,
                socklen_t(hostname.count),
                nil,
                0,
                0
            )

            if status == 0 {
                let name = String(cString: hostname)
                if name != address {  // Don't cache if it just returned the IP
                    self.lock.lock()
                    self.hostnameCache[address] = name
                    self.lock.unlock()
                    continuation.resume(returning: name)
                } else {
                    continuation.resume(returning: nil)
                }
            } else {
                continuation.resume(returning: nil)
            }
        }
    }

    // MARK: - Private Implementation

    private func fetchConnections() throws -> [NetworkConnection] {
        // Use lsof for more detailed connection info including PIDs
        let output = try runCommand("/usr/sbin/lsof", arguments: ["-i", "-n", "-P"])
        return parseLsofOutput(output)
    }

    private func parseLsofOutput(_ output: String) -> [NetworkConnection] {
        var connections: [NetworkConnection] = []
        let lines = output.components(separatedBy: "\n")

        // Skip header line
        for line in lines.dropFirst() {
            guard !line.isEmpty else { continue }

            let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 9 else { continue }

            let processName = parts[0]
            guard let pid = Int32(parts[1]) else { continue }

            // Parse the NAME column (last column, may contain connection info)
            let nameColumn = parts.dropFirst(8).joined(separator: " ")

            // Parse protocol
            let protocolStr = parts[7]
            let proto: NetworkConnection.NetworkProtocol
            if protocolStr.contains("TCP") {
                proto = protocolStr.contains("6") ? .tcp6 : .tcp
            } else if protocolStr.contains("UDP") {
                proto = protocolStr.contains("6") ? .udp6 : .udp
            } else {
                continue
            }

            // Parse connection details
            if let connection = parseConnectionString(nameColumn, protocol: proto, pid: pid, processName: processName) {
                connections.append(connection)
            }
        }

        return connections
    }

    private func parseConnectionString(_ str: String, protocol proto: NetworkConnection.NetworkProtocol, pid: Int32, processName: String) -> NetworkConnection? {
        // Format: "local:port->remote:port (state)" or "local:port" or "*:port"
        let state: NetworkConnection.ConnectionState
        var connectionStr = str

        // Extract state if present
        if let stateMatch = str.range(of: "\\(([A-Z_]+)\\)", options: .regularExpression) {
            let stateStr = String(str[stateMatch]).trimmingCharacters(in: CharacterSet(charactersIn: "()"))
            state = parseConnectionState(stateStr)
            connectionStr = String(str[..<stateMatch.lowerBound]).trimmingCharacters(in: .whitespaces)
        } else if str.contains("LISTEN") || str.contains("(LISTEN)") {
            state = .listen
            connectionStr = str.replacingOccurrences(of: "(LISTEN)", with: "").trimmingCharacters(in: .whitespaces)
        } else {
            state = proto == .tcp || proto == .tcp6 ? .unknown : .none
        }

        // Split into local and remote
        let parts = connectionStr.components(separatedBy: "->")
        let localPart = parts[0]
        let remotePart = parts.count > 1 ? parts[1] : ""

        // Parse local address:port
        let (localAddress, localPort) = parseEndpoint(localPart)

        // Parse remote address:port
        let (remoteAddress, remotePort) = parseEndpoint(remotePart)

        return NetworkConnection(
            protocol: proto,
            localAddress: localAddress,
            localPort: localPort,
            remoteAddress: remoteAddress,
            remotePort: remotePort,
            state: state,
            pid: pid,
            processName: processName
        )
    }

    private func parseEndpoint(_ str: String) -> (address: String, port: UInt16) {
        let trimmed = str.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return ("*", 0) }

        // Handle IPv6 addresses [addr]:port
        if trimmed.hasPrefix("[") {
            if let closeBracket = trimmed.lastIndex(of: "]") {
                let address = String(trimmed[trimmed.index(after: trimmed.startIndex)..<closeBracket])
                let afterBracket = trimmed.index(after: closeBracket)
                if afterBracket < trimmed.endIndex && trimmed[afterBracket] == ":" {
                    let portStr = String(trimmed[trimmed.index(after: afterBracket)...])
                    let port = UInt16(portStr) ?? 0
                    return (address, port)
                }
                return (address, 0)
            }
        }

        // Handle regular addr:port or *:port
        if let lastColon = trimmed.lastIndex(of: ":") {
            let address = String(trimmed[..<lastColon])
            let portStr = String(trimmed[trimmed.index(after: lastColon)...])
            let port = UInt16(portStr.trimmingCharacters(in: CharacterSet(charactersIn: " ()"))) ?? 0
            return (address.isEmpty ? "*" : address, port)
        }

        return (trimmed, 0)
    }

    private func parseConnectionState(_ str: String) -> NetworkConnection.ConnectionState {
        switch str.uppercased() {
        case "ESTABLISHED": return .established
        case "LISTEN": return .listen
        case "TIME_WAIT": return .timeWait
        case "CLOSE_WAIT": return .closeWait
        case "FIN_WAIT_1", "FIN_WAIT1": return .finWait1
        case "FIN_WAIT_2", "FIN_WAIT2": return .finWait2
        case "SYN_SENT": return .synSent
        case "SYN_RECV", "SYN_RECEIVED": return .synReceived
        case "LAST_ACK": return .lastAck
        case "CLOSING": return .closing
        case "CLOSED": return .closed
        default: return .unknown
        }
    }

    private func fetchInterfaces() -> [NetworkInterface] {
        var interfaces: [NetworkInterface] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&ifaddr) == 0 else { return [] }
        defer { freeifaddrs(ifaddr) }

        var current = ifaddr
        var interfaceData: [String: (ipv4: [String], ipv6: [String], mac: String?, flags: UInt32)] = [:]

        while let addr = current {
            let name = String(cString: addr.pointee.ifa_name)
            let family = addr.pointee.ifa_addr.pointee.sa_family
            let flags = addr.pointee.ifa_flags

            var entry = interfaceData[name] ?? (ipv4: [], ipv6: [], mac: nil, flags: flags)

            if family == UInt8(AF_INET) {
                // IPv4
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(addr.pointee.ifa_addr, socklen_t(MemoryLayout<sockaddr_in>.size),
                           &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
                entry.ipv4.append(String(cString: hostname))
            } else if family == UInt8(AF_INET6) {
                // IPv6
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(addr.pointee.ifa_addr, socklen_t(MemoryLayout<sockaddr_in6>.size),
                           &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
                let ipv6 = String(cString: hostname)
                // Remove scope ID suffix if present
                let cleanIpv6 = ipv6.components(separatedBy: "%").first ?? ipv6
                entry.ipv6.append(cleanIpv6)
            } else if family == UInt8(AF_LINK) {
                // MAC address
                let linkAddr = unsafeBitCast(addr.pointee.ifa_addr, to: UnsafeMutablePointer<sockaddr_dl>.self)
                let macBytes = linkAddr.pointee.sdl_data
                let macLength = Int(linkAddr.pointee.sdl_alen)

                if macLength == 6 {
                    let mac = withUnsafeBytes(of: macBytes) { buffer -> String in
                        let bytes = Array(buffer.prefix(6 + Int(linkAddr.pointee.sdl_nlen)))
                            .suffix(6)
                        return bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
                    }
                    entry.mac = mac
                }
            }

            interfaceData[name] = entry
            current = addr.pointee.ifa_next
        }

        // Get interface statistics
        let stats = getInterfaceStats()

        for (name, data) in interfaceData {
            let stat = stats[name]
            let isUp = (data.flags & UInt32(IFF_UP)) != 0
            let isLoopback = (data.flags & UInt32(IFF_LOOPBACK)) != 0

            let interface = NetworkInterface(
                id: name,
                name: name,
                displayName: getInterfaceDisplayName(name),
                macAddress: data.mac,
                ipv4Addresses: data.ipv4,
                ipv6Addresses: data.ipv6,
                isUp: isUp,
                isLoopback: isLoopback,
                mtu: 0,
                bytesIn: stat?.bytesIn ?? 0,
                bytesOut: stat?.bytesOut ?? 0,
                packetsIn: stat?.packetsIn ?? 0,
                packetsOut: stat?.packetsOut ?? 0
            )
            interfaces.append(interface)
        }

        return interfaces.sorted { $0.name < $1.name }
    }

    private func getInterfaceDisplayName(_ name: String) -> String {
        switch name {
        case "lo0": return "Loopback"
        case "en0": return "Wi-Fi"
        case "en1": return "Ethernet"
        case "bridge0": return "Bridge"
        case "awdl0": return "AirDrop"
        case "llw0": return "Low Latency WLAN"
        case "utun0", "utun1", "utun2", "utun3": return "VPN Tunnel"
        default:
            if name.hasPrefix("en") { return "Ethernet \(name)" }
            if name.hasPrefix("utun") { return "Tunnel \(name)" }
            return name
        }
    }

    private func getInterfaceStats() -> [String: (bytesIn: UInt64, bytesOut: UInt64, packetsIn: UInt64, packetsOut: UInt64)] {
        guard let output = try? runCommand("/usr/bin/netstat", arguments: ["-ib"]) else {
            return [:]
        }

        var stats: [String: (bytesIn: UInt64, bytesOut: UInt64, packetsIn: UInt64, packetsOut: UInt64)] = [:]
        let lines = output.components(separatedBy: "\n")

        for line in lines.dropFirst() {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 11 else { continue }

            let name = parts[0]
            // netstat -ib format: Name Mtu Network Address Ipkts Ierrs Ibytes Opkts Oerrs Obytes Coll
            guard let packetsIn = UInt64(parts[4]),
                  let bytesIn = UInt64(parts[6]),
                  let packetsOut = UInt64(parts[7]),
                  let bytesOut = UInt64(parts[9]) else { continue }

            stats[name] = (bytesIn, bytesOut, packetsIn, packetsOut)
        }

        return stats
    }

    private func fetchStats() throws -> NetworkStats {
        let interfaces = fetchInterfaces()
        let connections = try fetchConnections()

        let totalBytesIn = interfaces.reduce(0) { $0 + $1.bytesIn }
        let totalBytesOut = interfaces.reduce(0) { $0 + $1.bytesOut }
        let totalPacketsIn = interfaces.reduce(0) { $0 + $1.packetsIn }
        let totalPacketsOut = interfaces.reduce(0) { $0 + $1.packetsOut }

        let now = Date()
        var bytesInPerSecond: Double = 0
        var bytesOutPerSecond: Double = 0

        lock.lock()
        if let previous = previousStats {
            let elapsed = now.timeIntervalSince(previous.timestamp)
            if elapsed > 0 {
                bytesInPerSecond = Double(totalBytesIn - previous.bytesIn) / elapsed
                bytesOutPerSecond = Double(totalBytesOut - previous.bytesOut) / elapsed
            }
        }
        previousStats = (now, totalBytesIn, totalBytesOut)
        lock.unlock()

        return NetworkStats(
            timestamp: now,
            totalBytesIn: totalBytesIn,
            totalBytesOut: totalBytesOut,
            totalPacketsIn: totalPacketsIn,
            totalPacketsOut: totalPacketsOut,
            activeConnections: connections.count,
            bytesInPerSecond: max(0, bytesInPerSecond),
            bytesOutPerSecond: max(0, bytesOutPerSecond)
        )
    }

    // MARK: - Helpers

    private func runCommand(_ path: String, arguments: [String]) throws -> String {
        let process = Foundation.Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
