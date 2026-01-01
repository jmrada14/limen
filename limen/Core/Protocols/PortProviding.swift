//
//  PortProviding.swift
//  limen
//
//  Protocol defining port monitoring capabilities.
//

import Foundation

/// Information about a port
public struct Port: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let number: UInt16
    public let `protocol`: PortProtocol
    public let state: PortState
    public let address: String
    public let pid: Int32?
    public let processName: String?
    public let serviceName: String?
    public let connectionCount: Int

    public enum PortProtocol: String, Sendable, CaseIterable {
        case tcp = "TCP"
        case udp = "UDP"
        case tcp6 = "TCP6"
        case udp6 = "UDP6"
    }

    public enum PortState: String, Sendable {
        case listening = "LISTENING"
        case established = "ESTABLISHED"
        case bound = "BOUND"
        case closed = "CLOSED"
    }

    public init(
        id: UUID = UUID(),
        number: UInt16,
        protocol: PortProtocol,
        state: PortState,
        address: String = "*",
        pid: Int32? = nil,
        processName: String? = nil,
        serviceName: String? = nil,
        connectionCount: Int = 0
    ) {
        self.id = id
        self.number = number
        self.protocol = `protocol`
        self.state = state
        self.address = address
        self.pid = pid
        self.processName = processName
        self.serviceName = serviceName
        self.connectionCount = connectionCount
    }

    /// Common service names for well-known ports
    public static func commonServiceName(for port: UInt16) -> String? {
        switch port {
        case 20: return "FTP Data"
        case 21: return "FTP Control"
        case 22: return "SSH"
        case 23: return "Telnet"
        case 25: return "SMTP"
        case 53: return "DNS"
        case 67, 68: return "DHCP"
        case 80: return "HTTP"
        case 110: return "POP3"
        case 119: return "NNTP"
        case 123: return "NTP"
        case 143: return "IMAP"
        case 161, 162: return "SNMP"
        case 194: return "IRC"
        case 443: return "HTTPS"
        case 445: return "SMB"
        case 465: return "SMTPS"
        case 514: return "Syslog"
        case 587: return "SMTP Submission"
        case 631: return "IPP (CUPS)"
        case 993: return "IMAPS"
        case 995: return "POP3S"
        case 1080: return "SOCKS"
        case 1433: return "MS SQL"
        case 1521: return "Oracle"
        case 3306: return "MySQL"
        case 3389: return "RDP"
        case 5432: return "PostgreSQL"
        case 5672: return "AMQP"
        case 5900...5999: return "VNC"
        case 6379: return "Redis"
        case 8080: return "HTTP Proxy"
        case 8443: return "HTTPS Alt"
        case 9200: return "Elasticsearch"
        case 27017: return "MongoDB"
        default: return nil
        }
    }
}

/// Summary of port usage
public struct PortSummary: Sendable {
    public let totalListening: Int
    public let totalEstablished: Int
    public let tcpPorts: Int
    public let udpPorts: Int
    public let portsUnder1024: Int
    public let portsOver1024: Int

    public init(
        totalListening: Int = 0,
        totalEstablished: Int = 0,
        tcpPorts: Int = 0,
        udpPorts: Int = 0,
        portsUnder1024: Int = 0,
        portsOver1024: Int = 0
    ) {
        self.totalListening = totalListening
        self.totalEstablished = totalEstablished
        self.tcpPorts = tcpPorts
        self.udpPorts = udpPorts
        self.portsUnder1024 = portsUnder1024
        self.portsOver1024 = portsOver1024
    }
}

/// Protocol for port monitoring providers
public protocol PortProviding: Sendable {
    /// Get all ports in use (listening and established)
    func listPorts() async throws -> [Port]

    /// Get only listening ports
    func listListeningPorts() async throws -> [Port]

    /// Get ports for a specific process
    func getPorts(forPid pid: Int32) async throws -> [Port]

    /// Check if a specific port is in use
    func isPortInUse(port: UInt16, protocol: Port.PortProtocol) async throws -> Bool

    /// Get information about a specific port
    func getPortInfo(port: UInt16, protocol: Port.PortProtocol) async throws -> Port?

    /// Get port usage summary
    func getSummary() async throws -> PortSummary

    /// Find which process is using a port
    func findProcess(usingPort port: UInt16, protocol: Port.PortProtocol) async throws -> (pid: Int32, name: String)?
}

/// Errors that can occur during port operations
public enum PortError: Error, LocalizedError {
    case accessDenied
    case portNotFound(UInt16)
    case systemError(String)

    public var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "Access denied. The app may need additional permissions."
        case .portNotFound(let port):
            return "Port \(port) not found or not in use."
        case .systemError(let message):
            return "System error: \(message)"
        }
    }
}
