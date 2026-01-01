//
//  LimenCore.swift
//  limen
//
//  Main facade for accessing all Limen monitoring capabilities.
//  Designed for use by menubar app, TUI, or CLI.
//

import Foundation
import Combine

/// Main entry point for Limen monitoring functionality
/// Thread-safe and designed for concurrent access
public final class LimenCore: @unchecked Sendable {

    // MARK: - Shared Instance

    /// Shared instance for convenience (can also create custom instances)
    public static let shared = LimenCore()

    // MARK: - Providers

    public let processes: ProcessProviding
    public let network: NetworkProviding
    public let ports: PortProviding

    // MARK: - Initialization

    public init(
        processProvider: ProcessProviding? = nil,
        networkProvider: NetworkProviding? = nil,
        portProvider: PortProviding? = nil
    ) {
        let netProvider = (networkProvider as? NetworkProvider) ?? NetworkProvider()

        self.processes = processProvider ?? ProcessProvider()
        self.network = networkProvider ?? netProvider
        self.ports = portProvider ?? PortProvider(networkProvider: netProvider)
    }

    // MARK: - Convenience Methods

    /// Get a snapshot of all system activity
    public func getSystemSnapshot() async throws -> SystemSnapshot {
        async let processList = processes.listProcesses()
        async let connectionList = network.listConnections()
        async let portList = ports.listListeningPorts()
        async let netStats = network.getStats()
        async let portSummary = ports.getSummary()

        return try await SystemSnapshot(
            timestamp: Date(),
            processes: processList,
            connections: connectionList,
            listeningPorts: portList,
            networkStats: netStats,
            portSummary: portSummary
        )
    }

    /// Get processes using the most CPU
    public func getTopProcessesByCPU(limit: Int = 10) async throws -> [Process] {
        let all = try await processes.listProcesses()
        return Array(all.sorted { $0.cpuUsage > $1.cpuUsage }.prefix(limit))
    }

    /// Get processes using the most memory
    public func getTopProcessesByMemory(limit: Int = 10) async throws -> [Process] {
        let all = try await processes.listProcesses()
        return Array(all.sorted { $0.memoryBytes > $1.memoryBytes }.prefix(limit))
    }

    /// Get all connections for a process by name
    public func getConnectionsForProcess(name: String) async throws -> [NetworkConnection] {
        let all = try await network.listConnections()
        return all.filter { $0.processName?.lowercased() == name.lowercased() }
    }

    /// Get established connections (active traffic)
    public func getActiveConnections() async throws -> [NetworkConnection] {
        try await network.listConnections(state: .established)
    }

    /// Check which process is using a port
    public func whichProcessUsesPort(_ port: UInt16) async throws -> (pid: Int32, name: String)? {
        // Try TCP first
        if let result = try await ports.findProcess(usingPort: port, protocol: .tcp) {
            return result
        }
        // Then try UDP
        return try await ports.findProcess(usingPort: port, protocol: .udp)
    }

    // MARK: - Process Control

    /// Validate if a process can be killed (check safety level)
    public func validateKill(pid: Int32, force: Bool = false) async -> KillResult {
        await processes.validateKill(pid: pid, force: force)
    }

    /// Terminate a process (SIGTERM) - requires confirmation for non-background processes
    public func terminateProcess(pid: Int32) async -> KillResult {
        await processes.terminateProcess(pid: pid, force: false)
    }

    /// Force quit a process (SIGKILL) - requires confirmation, may cause data loss
    public func forceQuitProcess(pid: Int32) async -> KillResult {
        await processes.forceQuitProcess(pid: pid)
    }

    /// Execute kill after user has confirmed - this actually sends the signal
    public func executeConfirmedKill(pid: Int32, forceQuit: Bool = false) async -> KillResult {
        let signal = forceQuit ? SIGKILL : SIGTERM
        return await processes.executeConfirmedKill(pid: pid, signal: signal)
    }

    /// Get the safety level for a process
    public func getProcessSafetyLevel(pid: Int32) async -> ProcessSafetyLevel? {
        guard let process = try? await processes.getProcess(pid: pid) else {
            return nil
        }
        return process.safetyLevel
    }

    // MARK: - Port Control

    /// Validate if a port can be closed (check safety level)
    public func validateClosePort(port: UInt16, protocol proto: Port.PortProtocol, force: Bool = false) async -> PortCloseResult {
        await ports.validateClosePort(port: port, protocol: proto, force: force)
    }

    /// Close a port by killing the process using it
    public func closePort(port: UInt16, protocol proto: Port.PortProtocol, force: Bool = false) async -> PortCloseResult {
        await ports.closePort(port: port, protocol: proto, force: force)
    }

    /// Execute port close after user has confirmed
    public func executeConfirmedClosePort(port: UInt16, protocol proto: Port.PortProtocol, forceQuit: Bool = false) async -> PortCloseResult {
        await ports.executeConfirmedClose(port: port, protocol: proto, forceQuit: forceQuit)
    }

    /// Get the safety level for a port
    public func getPortSafetyLevel(port: UInt16, protocol proto: Port.PortProtocol) async -> PortSafetyLevel? {
        guard let portInfo = try? await ports.getPortInfo(port: port, protocol: proto) else {
            return nil
        }
        return portInfo.safetyLevel
    }
}

// MARK: - System Snapshot

/// Complete snapshot of system state at a point in time
public struct SystemSnapshot: Sendable {
    public let timestamp: Date
    public let processes: [Process]
    public let connections: [NetworkConnection]
    public let listeningPorts: [Port]
    public let networkStats: NetworkStats
    public let portSummary: PortSummary

    /// Total number of running processes
    public var processCount: Int { processes.count }

    /// Total number of active connections
    public var connectionCount: Int { connections.count }

    /// Number of listening ports
    public var listeningPortCount: Int { listeningPorts.count }

    /// Processes grouped by user
    public var processesByUser: [String: [Process]] {
        Dictionary(grouping: processes, by: { $0.user })
    }

    /// Connections grouped by process
    public var connectionsByProcess: [String: [NetworkConnection]] {
        Dictionary(grouping: connections.filter { $0.processName != nil }, by: { $0.processName! })
    }
}

// MARK: - Observable Monitor

/// Observable wrapper for real-time monitoring with SwiftUI/Combine
@MainActor
public final class LimenMonitor: ObservableObject {
    private let core: LimenCore
    private var refreshTask: Task<Void, Never>?

    @Published public var processes: [Process] = []
    @Published public var connections: [NetworkConnection] = []
    @Published public var ports: [Port] = []
    @Published public var networkStats: NetworkStats?
    @Published public var isMonitoring: Bool = false
    @Published public var lastError: Error?
    @Published public var lastUpdated: Date?

    public init(core: LimenCore = .shared) {
        self.core = core
    }

    /// Start monitoring with specified refresh interval
    public func startMonitoring(interval: TimeInterval = 2.0) {
        guard !isMonitoring else { return }
        isMonitoring = true
        lastError = nil

        refreshTask = Task {
            while !Task.isCancelled && isMonitoring {
                await refresh()
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    /// Stop monitoring
    public func stopMonitoring() {
        isMonitoring = false
        refreshTask?.cancel()
        refreshTask = nil
    }

    /// Manually refresh all data
    public func refresh() async {
        do {
            async let p = core.processes.listProcesses()
            async let c = core.network.listConnections()
            async let pt = core.ports.listListeningPorts()
            async let s = core.network.getStats()

            let (procs, conns, ports, stats) = try await (p, c, pt, s)

            self.processes = procs
            self.connections = conns
            self.ports = ports
            self.networkStats = stats
            self.lastUpdated = Date()
            self.lastError = nil
        } catch {
            self.lastError = error
        }
    }

    // MARK: - Process Control

    /// Validate if a process can be killed
    public func validateKill(pid: Int32, force: Bool = false) async -> KillResult {
        await core.validateKill(pid: pid, force: force)
    }

    /// Execute a confirmed kill
    public func executeKill(pid: Int32, forceQuit: Bool = false) async -> KillResult {
        let result = await core.executeConfirmedKill(pid: pid, forceQuit: forceQuit)
        // Refresh process list after kill
        if case .success = result {
            await refresh()
        }
        return result
    }

    // MARK: - Port Control

    /// Validate if a port can be closed
    public func validateClosePort(port: UInt16, protocol proto: Port.PortProtocol, force: Bool = false) async -> PortCloseResult {
        await core.validateClosePort(port: port, protocol: proto, force: force)
    }

    /// Execute a confirmed port close
    public func executeClosePort(port: UInt16, protocol proto: Port.PortProtocol, forceQuit: Bool = false) async -> PortCloseResult {
        let result = await core.executeConfirmedClosePort(port: port, protocol: proto, forceQuit: forceQuit)
        // Refresh port list after close
        if case .success = result {
            await refresh()
        }
        return result
    }

    deinit {
        refreshTask?.cancel()
    }
}

// MARK: - Formatting Helpers

public extension LimenCore {

    /// Format bytes to human readable string
    static func formatBytes(_ bytes: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var unitIndex = 0

        while value >= 1024 && unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }

        if unitIndex == 0 {
            return "\(bytes) B"
        }
        return String(format: "%.1f %@", value, units[unitIndex])
    }

    /// Format bytes per second to human readable string
    static func formatBytesPerSecond(_ bytesPerSecond: Double) -> String {
        let units = ["B/s", "KB/s", "MB/s", "GB/s"]
        var value = bytesPerSecond
        var unitIndex = 0

        while value >= 1024 && unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }

        return String(format: "%.1f %@", value, units[unitIndex])
    }

    /// Format percentage
    static func formatPercent(_ value: Double) -> String {
        String(format: "%.1f%%", value)
    }

    /// Format process uptime
    static func formatUptime(from startTime: Date?) -> String {
        guard let start = startTime else { return "Unknown" }

        let elapsed = Date().timeIntervalSince(start)

        if elapsed < 60 {
            return "\(Int(elapsed))s"
        } else if elapsed < 3600 {
            return "\(Int(elapsed / 60))m"
        } else if elapsed < 86400 {
            let hours = Int(elapsed / 3600)
            let minutes = Int((elapsed.truncatingRemainder(dividingBy: 3600)) / 60)
            return "\(hours)h \(minutes)m"
        } else {
            let days = Int(elapsed / 86400)
            let hours = Int((elapsed.truncatingRemainder(dividingBy: 86400)) / 3600)
            return "\(days)d \(hours)h"
        }
    }
}
