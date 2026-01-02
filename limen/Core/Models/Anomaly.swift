//
//  Anomaly.swift
//  limen
//
//  Data models for anomaly detection across processes, network, and ports.
//

import Foundation

// MARK: - Anomaly Types

/// Severity level for detected anomalies
public enum AnomalySeverity: String, Codable, Sendable, Comparable {
    case low = "Low"
    case medium = "Medium"
    case high = "High"
    case critical = "Critical"

    public static func < (lhs: AnomalySeverity, rhs: AnomalySeverity) -> Bool {
        let order: [AnomalySeverity] = [.low, .medium, .high, .critical]
        guard let lhsIndex = order.firstIndex(of: lhs),
              let rhsIndex = order.firstIndex(of: rhs) else { return false }
        return lhsIndex < rhsIndex
    }
}

/// Category of anomaly for grouping and filtering
public enum AnomalyCategory: String, Codable, Sendable {
    case process = "Process"
    case network = "Network"
    case port = "Port"
}

/// Specific type of anomaly detected
public enum AnomalyType: String, Codable, Sendable {
    // Process anomalies
    case cpuSpike = "CPU Spike"
    case memorySpike = "Memory Spike"
    case unusualProcess = "Unusual Process"
    case processSpawn = "Rapid Process Spawn"
    case zombieProcess = "Zombie Process"
    case privilegeEscalation = "Privilege Escalation"

    // Network anomalies
    case trafficSpike = "Traffic Spike"
    case unusualConnection = "Unusual Connection"
    case suspiciousPort = "Suspicious Port"
    case connectionFlood = "Connection Flood"
    case dataExfiltration = "Potential Data Exfiltration"
    case unusualProtocol = "Unusual Protocol"

    // Port anomalies
    case newListeningPort = "New Listening Port"
    case portScan = "Potential Port Scan"
    case unusualPortActivity = "Unusual Port Activity"
    case privilegedPort = "Privileged Port Opened"

    var category: AnomalyCategory {
        switch self {
        case .cpuSpike, .memorySpike, .unusualProcess, .processSpawn, .zombieProcess, .privilegeEscalation:
            return .process
        case .trafficSpike, .unusualConnection, .suspiciousPort, .connectionFlood, .dataExfiltration, .unusualProtocol:
            return .network
        case .newListeningPort, .portScan, .unusualPortActivity, .privilegedPort:
            return .port
        }
    }

    var defaultSeverity: AnomalySeverity {
        switch self {
        case .zombieProcess, .unusualPortActivity:
            return .low
        case .cpuSpike, .memorySpike, .processSpawn, .trafficSpike, .newListeningPort:
            return .medium
        case .unusualProcess, .unusualConnection, .suspiciousPort, .connectionFlood, .portScan:
            return .high
        case .privilegeEscalation, .dataExfiltration, .unusualProtocol, .privilegedPort:
            return .critical
        }
    }
}

// MARK: - Anomaly Model

/// Represents a detected anomaly in the system
public struct Anomaly: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let type: AnomalyType
    public let severity: AnomalySeverity
    public let category: AnomalyCategory
    public let timestamp: Date
    public let title: String
    public let description: String
    public let details: AnomalyDetails
    public let relatedPid: Int32?
    public let relatedPort: UInt16?
    public let relatedAddress: String?

    public init(
        id: UUID = UUID(),
        type: AnomalyType,
        severity: AnomalySeverity? = nil,
        timestamp: Date = Date(),
        title: String,
        description: String,
        details: AnomalyDetails = .none,
        relatedPid: Int32? = nil,
        relatedPort: UInt16? = nil,
        relatedAddress: String? = nil
    ) {
        self.id = id
        self.type = type
        self.severity = severity ?? type.defaultSeverity
        self.category = type.category
        self.timestamp = timestamp
        self.title = title
        self.description = description
        self.details = details
        self.relatedPid = relatedPid
        self.relatedPort = relatedPort
        self.relatedAddress = relatedAddress
    }
}

/// Additional details specific to anomaly type
public enum AnomalyDetails: Hashable, Sendable {
    case none
    case process(ProcessAnomalyDetails)
    case network(NetworkAnomalyDetails)
    case port(PortAnomalyDetails)
}

/// Details for process-related anomalies
public struct ProcessAnomalyDetails: Hashable, Sendable {
    public let processName: String
    public let pid: Int32
    public let currentValue: Double
    public let baselineValue: Double
    public let threshold: Double
    public let userId: UInt32?

    public init(processName: String, pid: Int32, currentValue: Double, baselineValue: Double, threshold: Double, userId: UInt32? = nil) {
        self.processName = processName
        self.pid = pid
        self.currentValue = currentValue
        self.baselineValue = baselineValue
        self.threshold = threshold
        self.userId = userId
    }
}

/// Details for network-related anomalies
public struct NetworkAnomalyDetails: Hashable, Sendable {
    public let bytesPerSecond: Double
    public let baselineBytesPerSecond: Double
    public let connectionCount: Int
    public let remoteAddress: String?
    public let remotePort: UInt16?
    public let processName: String?

    public init(bytesPerSecond: Double = 0, baselineBytesPerSecond: Double = 0, connectionCount: Int = 0, remoteAddress: String? = nil, remotePort: UInt16? = nil, processName: String? = nil) {
        self.bytesPerSecond = bytesPerSecond
        self.baselineBytesPerSecond = baselineBytesPerSecond
        self.connectionCount = connectionCount
        self.remoteAddress = remoteAddress
        self.remotePort = remotePort
        self.processName = processName
    }
}

/// Details for port-related anomalies
public struct PortAnomalyDetails: Hashable, Sendable {
    public let port: UInt16
    public let `protocol`: String
    public let processName: String?
    public let pid: Int32?
    public let isPrivileged: Bool

    public init(port: UInt16, protocol proto: String, processName: String? = nil, pid: Int32? = nil, isPrivileged: Bool = false) {
        self.port = port
        self.protocol = proto
        self.processName = processName
        self.pid = pid
        self.isPrivileged = isPrivileged
    }
}

// MARK: - Baseline Models

/// Historical baseline for process metrics
public struct ProcessBaseline: Sendable {
    public let pid: Int32
    public let name: String
    public var cpuSamples: [Double]
    public var memorySamples: [Double]
    public var lastSeen: Date

    public var avgCpu: Double {
        guard !cpuSamples.isEmpty else { return 0 }
        return cpuSamples.reduce(0, +) / Double(cpuSamples.count)
    }

    public var avgMemory: Double {
        guard !memorySamples.isEmpty else { return 0 }
        return memorySamples.reduce(0, +) / Double(memorySamples.count)
    }

    public var cpuStdDev: Double {
        guard cpuSamples.count > 1 else { return 0 }
        let mean = avgCpu
        let variance = cpuSamples.reduce(0) { $0 + pow($1 - mean, 2) } / Double(cpuSamples.count - 1)
        return sqrt(variance)
    }

    public var memoryStdDev: Double {
        guard memorySamples.count > 1 else { return 0 }
        let mean = avgMemory
        let variance = memorySamples.reduce(0) { $0 + pow($1 - mean, 2) } / Double(memorySamples.count - 1)
        return sqrt(variance)
    }

    public init(pid: Int32, name: String) {
        self.pid = pid
        self.name = name
        self.cpuSamples = []
        self.memorySamples = []
        self.lastSeen = Date()
    }

    public mutating func addSample(cpu: Double, memory: Double, maxSamples: Int = 60) {
        cpuSamples.append(cpu)
        memorySamples.append(memory)
        lastSeen = Date()

        // Keep only recent samples
        if cpuSamples.count > maxSamples {
            cpuSamples.removeFirst(cpuSamples.count - maxSamples)
        }
        if memorySamples.count > maxSamples {
            memorySamples.removeFirst(memorySamples.count - maxSamples)
        }
    }
}

/// Historical baseline for network metrics
public struct NetworkBaseline: Sendable {
    public var bytesInSamples: [Double]
    public var bytesOutSamples: [Double]
    public var connectionCountSamples: [Int]
    public var lastUpdated: Date

    public var avgBytesIn: Double {
        guard !bytesInSamples.isEmpty else { return 0 }
        return bytesInSamples.reduce(0, +) / Double(bytesInSamples.count)
    }

    public var avgBytesOut: Double {
        guard !bytesOutSamples.isEmpty else { return 0 }
        return bytesOutSamples.reduce(0, +) / Double(bytesOutSamples.count)
    }

    public var avgConnections: Double {
        guard !connectionCountSamples.isEmpty else { return 0 }
        return Double(connectionCountSamples.reduce(0, +)) / Double(connectionCountSamples.count)
    }

    public var bytesInStdDev: Double {
        guard bytesInSamples.count > 1 else { return 0 }
        let mean = avgBytesIn
        let variance = bytesInSamples.reduce(0) { $0 + pow($1 - mean, 2) } / Double(bytesInSamples.count - 1)
        return sqrt(variance)
    }

    public var bytesOutStdDev: Double {
        guard bytesOutSamples.count > 1 else { return 0 }
        let mean = avgBytesOut
        let variance = bytesOutSamples.reduce(0) { $0 + pow($1 - mean, 2) } / Double(bytesOutSamples.count - 1)
        return sqrt(variance)
    }

    public init() {
        self.bytesInSamples = []
        self.bytesOutSamples = []
        self.connectionCountSamples = []
        self.lastUpdated = Date()
    }

    public mutating func addSample(bytesIn: Double, bytesOut: Double, connections: Int, maxSamples: Int = 60) {
        bytesInSamples.append(bytesIn)
        bytesOutSamples.append(bytesOut)
        connectionCountSamples.append(connections)
        lastUpdated = Date()

        if bytesInSamples.count > maxSamples {
            bytesInSamples.removeFirst(bytesInSamples.count - maxSamples)
        }
        if bytesOutSamples.count > maxSamples {
            bytesOutSamples.removeFirst(bytesOutSamples.count - maxSamples)
        }
        if connectionCountSamples.count > maxSamples {
            connectionCountSamples.removeFirst(connectionCountSamples.count - maxSamples)
        }
    }
}

/// Tracks known listening ports and their state over time
public struct PortBaseline: Sendable {
    public var knownPorts: Set<PortKey>
    public var portHistory: [PortKey: Date]
    public var lastUpdated: Date

    public init() {
        self.knownPorts = []
        self.portHistory = [:]
        self.lastUpdated = Date()
    }

    public mutating func update(ports: [Port]) {
        lastUpdated = Date()
        let currentPorts = Set(ports.map { PortKey(port: $0.number, protocol: $0.protocol.rawValue) })

        // Track new ports
        for portKey in currentPorts {
            if !knownPorts.contains(portKey) {
                portHistory[portKey] = Date()
            }
        }

        knownPorts = currentPorts
    }

    public func isNewPort(_ port: UInt16, protocol proto: String) -> Bool {
        let key = PortKey(port: port, protocol: proto)
        guard let firstSeen = portHistory[key] else { return true }
        // Consider port "new" if seen for less than 5 minutes
        return Date().timeIntervalSince(firstSeen) < 300
    }
}

/// Key for tracking ports in baseline
public struct PortKey: Hashable, Sendable {
    public let port: UInt16
    public let `protocol`: String

    public init(port: UInt16, protocol proto: String) {
        self.port = port
        self.protocol = proto
    }
}

// MARK: - Configuration

/// Configuration for anomaly detection thresholds
public struct AnomalyDetectionConfig: Sendable {
    // Process thresholds
    public var cpuSpikeThreshold: Double = 80.0  // Percentage
    public var cpuSpikeMultiplier: Double = 3.0  // Times above baseline
    public var memorySpikeThreshold: Double = 70.0  // Percentage
    public var memorySpikeMultiplier: Double = 2.5  // Times above baseline
    public var processSpawnRate: Int = 10  // New processes per sample

    // Network thresholds
    public var trafficSpikeMultiplier: Double = 5.0  // Times above baseline
    public var minBytesForSpike: Double = 1_000_000  // 1MB/s minimum to consider spike
    public var connectionFloodThreshold: Int = 100  // Connections per process
    public var suspiciousPorts: Set<UInt16> = [4444, 5555, 6666, 31337, 1337, 12345, 54321]

    // Port thresholds
    public var privilegedPortThreshold: UInt16 = 1024
    public var alertOnNewListeningPorts: Bool = true

    // Baseline configuration
    public var baselineWindowSize: Int = 60  // Number of samples to keep
    public var minSamplesForBaseline: Int = 5  // Minimum samples before anomaly detection

    public init() {}
}

// MARK: - Anomaly Summary

/// Summary of current anomalies for quick display
public struct AnomalySummary: Sendable {
    public let total: Int
    public let critical: Int
    public let high: Int
    public let medium: Int
    public let low: Int
    public let byCategory: [AnomalyCategory: Int]

    public init(anomalies: [Anomaly]) {
        self.total = anomalies.count
        self.critical = anomalies.filter { $0.severity == .critical }.count
        self.high = anomalies.filter { $0.severity == .high }.count
        self.medium = anomalies.filter { $0.severity == .medium }.count
        self.low = anomalies.filter { $0.severity == .low }.count

        var categoryCount: [AnomalyCategory: Int] = [:]
        for anomaly in anomalies {
            categoryCount[anomaly.category, default: 0] += 1
        }
        self.byCategory = categoryCount
    }

    public var hasAnomalies: Bool { total > 0 }
    public var hasCritical: Bool { critical > 0 }
    public var hasHighOrAbove: Bool { critical > 0 || high > 0 }
}
