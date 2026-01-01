//
//  NetworkProviding.swift
//  limen
//
//  Protocol defining network monitoring capabilities.
//

import Foundation

/// Represents a network connection
public struct NetworkConnection: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let `protocol`: NetworkProtocol
    public let localAddress: String
    public let localPort: UInt16
    public let remoteAddress: String
    public let remotePort: UInt16
    public let state: ConnectionState
    public let pid: Int32?
    public let processName: String?
    public let bytesIn: UInt64
    public let bytesOut: UInt64
    public let createdAt: Date?

    public enum NetworkProtocol: String, Sendable {
        case tcp = "TCP"
        case udp = "UDP"
        case tcp6 = "TCP6"
        case udp6 = "UDP6"
    }

    public enum ConnectionState: String, Sendable {
        case established = "ESTABLISHED"
        case listen = "LISTEN"
        case timeWait = "TIME_WAIT"
        case closeWait = "CLOSE_WAIT"
        case finWait1 = "FIN_WAIT_1"
        case finWait2 = "FIN_WAIT_2"
        case synSent = "SYN_SENT"
        case synReceived = "SYN_RECV"
        case lastAck = "LAST_ACK"
        case closing = "CLOSING"
        case closed = "CLOSED"
        case none = "NONE"  // For UDP
        case unknown = "UNKNOWN"
    }

    public init(
        id: UUID = UUID(),
        protocol: NetworkProtocol,
        localAddress: String,
        localPort: UInt16,
        remoteAddress: String,
        remotePort: UInt16,
        state: ConnectionState,
        pid: Int32? = nil,
        processName: String? = nil,
        bytesIn: UInt64 = 0,
        bytesOut: UInt64 = 0,
        createdAt: Date? = nil
    ) {
        self.id = id
        self.protocol = `protocol`
        self.localAddress = localAddress
        self.localPort = localPort
        self.remoteAddress = remoteAddress
        self.remotePort = remotePort
        self.state = state
        self.pid = pid
        self.processName = processName
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
        self.createdAt = createdAt
    }

    /// Display string for the local endpoint
    public var localEndpoint: String {
        "\(localAddress):\(localPort)"
    }

    /// Display string for the remote endpoint
    public var remoteEndpoint: String {
        "\(remoteAddress):\(remotePort)"
    }
}

/// Network interface information
public struct NetworkInterface: Identifiable, Hashable, Sendable {
    public let id: String  // Interface name (e.g., "en0")
    public let name: String
    public let displayName: String
    public let macAddress: String?
    public let ipv4Addresses: [String]
    public let ipv6Addresses: [String]
    public let isUp: Bool
    public let isLoopback: Bool
    public let mtu: Int32
    public let bytesIn: UInt64
    public let bytesOut: UInt64
    public let packetsIn: UInt64
    public let packetsOut: UInt64

    public init(
        id: String,
        name: String,
        displayName: String = "",
        macAddress: String? = nil,
        ipv4Addresses: [String] = [],
        ipv6Addresses: [String] = [],
        isUp: Bool = false,
        isLoopback: Bool = false,
        mtu: Int32 = 0,
        bytesIn: UInt64 = 0,
        bytesOut: UInt64 = 0,
        packetsIn: UInt64 = 0,
        packetsOut: UInt64 = 0
    ) {
        self.id = id
        self.name = name
        self.displayName = displayName.isEmpty ? name : displayName
        self.macAddress = macAddress
        self.ipv4Addresses = ipv4Addresses
        self.ipv6Addresses = ipv6Addresses
        self.isUp = isUp
        self.isLoopback = isLoopback
        self.mtu = mtu
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
        self.packetsIn = packetsIn
        self.packetsOut = packetsOut
    }
}

/// Network statistics snapshot
public struct NetworkStats: Sendable {
    public let timestamp: Date
    public let totalBytesIn: UInt64
    public let totalBytesOut: UInt64
    public let totalPacketsIn: UInt64
    public let totalPacketsOut: UInt64
    public let activeConnections: Int
    public let bytesInPerSecond: Double
    public let bytesOutPerSecond: Double

    public init(
        timestamp: Date = Date(),
        totalBytesIn: UInt64 = 0,
        totalBytesOut: UInt64 = 0,
        totalPacketsIn: UInt64 = 0,
        totalPacketsOut: UInt64 = 0,
        activeConnections: Int = 0,
        bytesInPerSecond: Double = 0,
        bytesOutPerSecond: Double = 0
    ) {
        self.timestamp = timestamp
        self.totalBytesIn = totalBytesIn
        self.totalBytesOut = totalBytesOut
        self.totalPacketsIn = totalPacketsIn
        self.totalPacketsOut = totalPacketsOut
        self.activeConnections = activeConnections
        self.bytesInPerSecond = bytesInPerSecond
        self.bytesOutPerSecond = bytesOutPerSecond
    }
}

/// Protocol for network monitoring providers
public protocol NetworkProviding: Sendable {
    /// Get all active network connections
    func listConnections() async throws -> [NetworkConnection]

    /// Get connections filtered by state
    func listConnections(state: NetworkConnection.ConnectionState) async throws -> [NetworkConnection]

    /// Get connections for a specific process
    func getConnections(forPid pid: Int32) async throws -> [NetworkConnection]

    /// Get all network interfaces
    func listInterfaces() async throws -> [NetworkInterface]

    /// Get current network statistics
    func getStats() async throws -> NetworkStats

    /// Resolve hostname for an IP address
    func resolveHostname(for address: String) async -> String?
}

/// Errors that can occur during network operations
public enum NetworkError: Error, LocalizedError {
    case accessDenied
    case interfaceNotFound(String)
    case systemError(String)

    public var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "Access denied. The app may need additional permissions."
        case .interfaceNotFound(let name):
            return "Network interface '\(name)' not found."
        case .systemError(let message):
            return "System error: \(message)"
        }
    }
}
