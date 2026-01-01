//
//  ProcessProviding.swift
//  limen
//
//  Protocol defining process monitoring capabilities.
//

import Foundation

/// Information about a running process
public struct Process: Identifiable, Hashable, Sendable {
    public let id: Int32  // PID
    public let parentId: Int32  // PPID
    public let name: String
    public let path: String?
    public let user: String
    public let userId: UInt32
    public let groupId: UInt32
    public let status: ProcessStatus
    public let cpuUsage: Double
    public let memoryBytes: UInt64
    public let memoryPercent: Double
    public let threadCount: Int32
    public let startTime: Date?
    public let command: String?

    public enum ProcessStatus: String, Sendable {
        case running = "Running"
        case sleeping = "Sleeping"
        case idle = "Idle"
        case stopped = "Stopped"
        case zombie = "Zombie"
        case unknown = "Unknown"
    }

    public init(
        id: Int32,
        parentId: Int32 = 0,
        name: String,
        path: String? = nil,
        user: String = "",
        userId: UInt32 = 0,
        groupId: UInt32 = 0,
        status: ProcessStatus = .unknown,
        cpuUsage: Double = 0,
        memoryBytes: UInt64 = 0,
        memoryPercent: Double = 0,
        threadCount: Int32 = 0,
        startTime: Date? = nil,
        command: String? = nil
    ) {
        self.id = id
        self.parentId = parentId
        self.name = name
        self.path = path
        self.user = user
        self.userId = userId
        self.groupId = groupId
        self.status = status
        self.cpuUsage = cpuUsage
        self.memoryBytes = memoryBytes
        self.memoryPercent = memoryPercent
        self.threadCount = threadCount
        self.startTime = startTime
        self.command = command
    }
}

/// Protocol for process monitoring providers
public protocol ProcessProviding: Sendable {
    /// Get all running processes
    func listProcesses() async throws -> [Process]

    /// Get a specific process by PID
    func getProcess(pid: Int32) async throws -> Process?

    /// Get child processes of a given PID
    func getChildren(of pid: Int32) async throws -> [Process]

    /// Search processes by name (case-insensitive)
    func searchProcesses(matching query: String) async throws -> [Process]

    /// Get process tree (hierarchical view)
    func getProcessTree() async throws -> [ProcessTreeNode]

    // MARK: - Process Control (Kill)

    /// Terminate a process gracefully (SIGTERM)
    /// Returns the result of the kill attempt including any safety blocks
    func terminateProcess(pid: Int32, force: Bool) async -> KillResult

    /// Force quit a process (SIGKILL) - use with caution
    /// This bypasses graceful shutdown and may cause data loss
    func forceQuitProcess(pid: Int32) async -> KillResult

    /// Validate if a process can be killed without actually killing it
    func validateKill(pid: Int32, force: Bool) async -> KillResult

    /// Execute a kill after user confirmation has been received
    /// This is the only method that should actually send the kill signal
    func executeConfirmedKill(pid: Int32, signal: Int32) async -> KillResult
}

/// Node in a process tree
public struct ProcessTreeNode: Identifiable, Sendable {
    public let id: Int32
    public let process: Process
    public var children: [ProcessTreeNode]

    public init(process: Process, children: [ProcessTreeNode] = []) {
        self.id = process.id
        self.process = process
        self.children = children
    }
}

/// Errors that can occur during process operations
public enum ProcessError: Error, LocalizedError {
    case accessDenied
    case processNotFound(pid: Int32)
    case systemError(String)

    public var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "Access denied. The app may need additional permissions."
        case .processNotFound(let pid):
            return "Process with PID \(pid) not found."
        case .systemError(let message):
            return "System error: \(message)"
        }
    }
}
