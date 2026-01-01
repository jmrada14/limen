//
//  PortSafety.swift
//  limen
//
//  Defines port safety levels and provides kill protection for ports.
//

import Foundation

/// Safety level for a port - combines port importance with process safety
public enum PortSafetyLevel: Int, Comparable, Sendable {
    /// Critical system port - killing will break core system functionality
    case critical = 0

    /// System service port - may affect system stability
    case system = 1

    /// Important service port - may affect running applications
    case important = 2

    /// Regular application port
    case normal = 3

    /// Ephemeral/temporary port
    case ephemeral = 4

    public static func < (lhs: PortSafetyLevel, rhs: PortSafetyLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var description: String {
        switch self {
        case .critical: return "Critical System Port"
        case .system: return "System Service Port"
        case .important: return "Important Service"
        case .normal: return "Application Port"
        case .ephemeral: return "Ephemeral Port"
        }
    }
}

/// Result of attempting to close a port
public enum PortCloseResult: Sendable {
    case success
    case blocked(reason: String)
    case requiresConfirmation(level: PortSafetyLevel, message: String, processName: String?)
    case failed(error: String)
    case accessDenied
    case portNotInUse
}

/// Manages port safety classifications
public struct PortSafety: Sendable {

    // MARK: - Critical Ports (Block or Warn Strongly)

    /// Ports that are critical for system operation
    public static let criticalPorts: Set<UInt16> = [
        22,    // SSH - may lock you out
        53,    // DNS - breaks name resolution
        88,    // Kerberos - breaks authentication
        123,   // NTP - time sync
        631,   // CUPS/IPP - printing (system service)
    ]

    /// System service ports that should have strong warnings
    public static let systemPorts: Set<UInt16> = [
        80,    // HTTP
        443,   // HTTPS
        25,    // SMTP
        110,   // POP3
        143,   // IMAP
        389,   // LDAP
        636,   // LDAPS
        445,   // SMB
        548,   // AFP
        3283,  // Apple Remote Desktop
        5900,  // VNC/Screen Sharing
        5988,  // WBEM HTTP
        5989,  // WBEM HTTPS
    ]

    /// Processes that own critical ports and should never be killed via port
    public static let criticalPortProcesses: Set<String> = [
        "launchd",
        "mDNSResponder",
        "configd",
        "discoveryd",
        "netbiosd",
        "smbd",
        "cupsd",
        "sshd",
        "coreaudiod",
    ]

    // MARK: - Classification

    /// Classify a port by its safety level
    public static func classify(
        port: UInt16,
        processName: String?,
        processPid: Int32?,
        processUserId: UInt32?
    ) -> PortSafetyLevel {
        // Check if the process itself is critical
        if let name = processName {
            if ProcessSafety.criticalProcessNames.contains(name) {
                return .critical
            }
            if criticalPortProcesses.contains(name) {
                return .critical
            }
            if ProcessSafety.systemProcessNames.contains(name) {
                return .system
            }
        }

        // Check critical PIDs
        if let pid = processPid, ProcessSafety.criticalPIDs.contains(pid) {
            return .critical
        }

        // Check if it's a root-owned process on a privileged port
        if let uid = processUserId, uid == 0 && port < 1024 {
            if criticalPorts.contains(port) {
                return .critical
            }
            return .system
        }

        // Check port ranges
        if criticalPorts.contains(port) {
            return .critical
        }

        if systemPorts.contains(port) {
            return .system
        }

        // Well-known ports (< 1024) are generally more important
        if port < 1024 {
            return .important
        }

        // Registered ports (1024-49151) for applications
        if port < 49152 {
            // Check if it's a database or important service
            if isImportantServicePort(port) {
                return .important
            }
            return .normal
        }

        // Ephemeral ports (49152-65535)
        return .ephemeral
    }

    /// Check if a port is typically used by important services
    private static func isImportantServicePort(_ port: UInt16) -> Bool {
        let importantPorts: Set<UInt16> = [
            1433,  // MS SQL
            1521,  // Oracle
            3306,  // MySQL
            5432,  // PostgreSQL
            6379,  // Redis
            27017, // MongoDB
            9200,  // Elasticsearch
            5672,  // RabbitMQ/AMQP
            2181,  // ZooKeeper
            8080,  // HTTP Proxy/Alt
            8443,  // HTTPS Alt
            9000,  // Various services
            9090,  // Prometheus
            3000,  // Dev servers (Node, Rails, etc.)
            4000,  // Dev servers
            5000,  // Dev servers
            8000,  // Dev servers
        ]
        return importantPorts.contains(port)
    }

    // MARK: - Kill Validation

    /// Validate if a port's process can be killed
    public static func validateKill(
        port: UInt16,
        processName: String?,
        processPid: Int32?,
        processUserId: UInt32?,
        force: Bool = false
    ) -> PortCloseResult {
        let level = classify(
            port: port,
            processName: processName,
            processPid: processPid,
            processUserId: processUserId
        )

        let serviceName = Port.commonServiceName(for: port)
        let displayName = processName ?? "Unknown process"
        let serviceInfo = serviceName.map { " (\($0))" } ?? ""

        switch level {
        case .critical:
            return .blocked(reason: """
                Cannot close port \(port)\(serviceInfo).

                This port is used by '\(displayName)', which is a critical system service. \
                Closing it could crash your system or cause serious instability.

                If you're having issues with this service, try restarting your Mac instead.
                """)

        case .system:
            if force {
                return .requiresConfirmation(level: level, message: """
                    ⚠️ DANGER: You are about to kill a system service.

                    Port: \(port)\(serviceInfo)
                    Process: \(displayName)

                    This may cause:
                    • Loss of network connectivity
                    • Other applications to malfunction
                    • System instability
                    • Need to restart your Mac

                    Only proceed if you understand the consequences.
                    """, processName: processName)
            } else {
                return .requiresConfirmation(level: level, message: """
                    ⚠️ Warning: Port \(port)\(serviceInfo) is a system service.

                    Closing it may affect system functionality or other applications.

                    Process: \(displayName)
                    """, processName: processName)
            }

        case .important:
            return .requiresConfirmation(level: level, message: """
                Port \(port)\(serviceInfo) is used by '\(displayName)'.

                Closing this port will terminate the process, which may cause \
                data loss or affect other applications.
                """, processName: processName)

        case .normal:
            return .requiresConfirmation(level: level, message: """
                Close port \(port)?

                This will terminate '\(displayName)'.
                """, processName: processName)

        case .ephemeral:
            // Ephemeral ports can be closed with minimal confirmation
            return .requiresConfirmation(level: level, message: """
                Close connection on port \(port)?

                Process: \(displayName)
                """, processName: processName)
        }
    }
}

// MARK: - Port Extension

public extension Port {
    /// Get the safety level for this port
    var safetyLevel: PortSafetyLevel {
        PortSafety.classify(
            port: number,
            processName: processName,
            processPid: pid,
            processUserId: nil  // We don't have this in Port, will use process lookup
        )
    }

    /// Check if this port's process can be killed
    var canBeClosed: Bool {
        safetyLevel != .critical
    }

    /// Get kill validation result
    func validateKill(force: Bool = false) -> PortCloseResult {
        PortSafety.validateKill(
            port: number,
            processName: processName,
            processPid: pid,
            processUserId: nil,
            force: force
        )
    }
}
