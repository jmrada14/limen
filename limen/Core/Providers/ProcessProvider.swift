//
//  ProcessProvider.swift
//  limen
//
//  Implementation of process monitoring using macOS libproc APIs.
//

import Foundation
import Darwin

// Constants not exposed in Swift
private let PROC_PIDPATHINFO_MAXSIZE: Int = 4096

/// macOS implementation of ProcessProviding using libproc
public final class ProcessProvider: ProcessProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var userCache: [UInt32: String] = [:]
    private var totalMemory: UInt64 = 0

    public init() {
        self.totalMemory = Self.getPhysicalMemory()
    }

    // MARK: - ProcessProviding

    public func listProcesses() async throws -> [Process] {
        try await Task.detached(priority: .userInitiated) {
            try self.fetchAllProcesses()
        }.value
    }

    public func getProcess(pid: Int32) async throws -> Process? {
        try await Task.detached(priority: .userInitiated) {
            try self.fetchProcess(pid: pid)
        }.value
    }

    public func getChildren(of pid: Int32) async throws -> [Process] {
        let allProcesses = try await listProcesses()
        return allProcesses.filter { $0.parentId == pid }
    }

    public func searchProcesses(matching query: String) async throws -> [Process] {
        let allProcesses = try await listProcesses()
        let lowercaseQuery = query.lowercased()
        return allProcesses.filter {
            $0.name.lowercased().contains(lowercaseQuery) ||
            ($0.command?.lowercased().contains(lowercaseQuery) ?? false)
        }
    }

    public func getProcessTree() async throws -> [ProcessTreeNode] {
        let allProcesses = try await listProcesses()
        return buildProcessTree(from: allProcesses)
    }

    // MARK: - Private Implementation

    private func fetchAllProcesses() throws -> [Process] {
        // Get number of processes
        var numberOfProcesses = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard numberOfProcesses > 0 else {
            return []
        }

        // Allocate buffer for PIDs
        let pidBufferSize = Int(numberOfProcesses) * MemoryLayout<Int32>.size
        var pids = [Int32](repeating: 0, count: Int(numberOfProcesses))

        // Get all PIDs
        numberOfProcesses = pids.withUnsafeMutableBufferPointer { buffer in
            proc_listpids(UInt32(PROC_ALL_PIDS), 0, buffer.baseAddress, Int32(pidBufferSize))
        }

        let count = Int(numberOfProcesses) / MemoryLayout<Int32>.size
        var processes: [Process] = []
        processes.reserveCapacity(count)

        for i in 0..<count {
            let pid = pids[i]
            if pid > 0, let process = try? fetchProcess(pid: pid) {
                processes.append(process)
            }
        }

        return processes.sorted { $0.cpuUsage > $1.cpuUsage }
    }

    private func fetchProcess(pid: Int32) throws -> Process? {
        // Get basic process info
        var info = proc_bsdinfo()
        let infoSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        let result = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, infoSize)

        guard result == infoSize else {
            return nil
        }

        // Get process name
        let name = getProcessName(pid: pid, bsdInfo: info)

        // Get process path
        let path = getProcessPath(pid: pid)

        // Get task info for CPU/memory
        var taskInfo = proc_taskinfo()
        let taskInfoSize = Int32(MemoryLayout<proc_taskinfo>.size)
        let taskResult = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &taskInfo, taskInfoSize)

        let memoryBytes: UInt64
        let threadCount: Int32
        let cpuUsage: Double

        if taskResult == taskInfoSize {
            memoryBytes = taskInfo.pti_resident_size
            threadCount = Int32(taskInfo.pti_threadnum)
            // CPU usage calculation (simplified - would need sampling for accurate values)
            let totalTime = taskInfo.pti_total_user + taskInfo.pti_total_system
            cpuUsage = Double(totalTime) / 1_000_000_000.0  // Rough approximation
        } else {
            memoryBytes = 0
            threadCount = 0
            cpuUsage = 0
        }

        let memoryPercent = totalMemory > 0 ? (Double(memoryBytes) / Double(totalMemory)) * 100.0 : 0

        // Get username
        let username = getUsername(uid: info.pbi_uid)

        // Determine process status
        let status = mapProcessStatus(info.pbi_status)

        // Get start time
        let startTime = Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec))

        // Get command line
        let command = getProcessCommand(pid: pid)

        return Process(
            id: pid,
            parentId: Int32(info.pbi_ppid),
            name: name,
            path: path,
            user: username,
            userId: info.pbi_uid,
            groupId: info.pbi_gid,
            status: status,
            cpuUsage: cpuUsage,
            memoryBytes: memoryBytes,
            memoryPercent: memoryPercent,
            threadCount: threadCount,
            startTime: startTime,
            command: command
        )
    }

    private func getProcessName(pid: Int32, bsdInfo: proc_bsdinfo) -> String {
        // Try proc_name first
        var nameBuffer = [CChar](repeating: 0, count: Int(MAXCOMLEN) + 1)
        let nameLength = proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))

        if nameLength > 0 {
            return String(cString: nameBuffer)
        }

        // Fallback to bsdinfo name
        return withUnsafePointer(to: bsdInfo.pbi_name) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN)) { charPtr in
                String(cString: charPtr)
            }
        }
    }

    private func getProcessPath(pid: Int32) -> String? {
        var pathBuffer = [CChar](repeating: 0, count: Int(PROC_PIDPATHINFO_MAXSIZE))
        let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))

        guard pathLength > 0 else { return nil }
        return String(cString: pathBuffer)
    }

    private func getProcessCommand(pid: Int32) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size: Int = 0

        // Get size needed
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else {
            return nil
        }

        var buffer = [CChar](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else {
            return nil
        }

        // Parse the buffer (first int32 is argc, then executable path, then args)
        // This is a simplified version - full parsing is more complex
        let data = Data(bytes: buffer, count: size)
        guard data.count > MemoryLayout<Int32>.size else { return nil }

        // Skip argc
        var offset = MemoryLayout<Int32>.size

        // Find end of executable path
        while offset < data.count && data[offset] != 0 {
            offset += 1
        }

        // Skip null terminators
        while offset < data.count && data[offset] == 0 {
            offset += 1
        }

        // Collect arguments
        var args: [String] = []
        var currentArg = ""

        for i in offset..<data.count {
            if data[i] == 0 {
                if !currentArg.isEmpty {
                    args.append(currentArg)
                    currentArg = ""
                }
                // Stop at first double null or after collecting some args
                if i + 1 < data.count && data[i + 1] == 0 {
                    break
                }
            } else {
                currentArg.append(Character(UnicodeScalar(data[i])))
            }
        }

        return args.isEmpty ? nil : args.joined(separator: " ")
    }

    private func getUsername(uid: UInt32) -> String {
        lock.lock()
        defer { lock.unlock() }

        if let cached = userCache[uid] {
            return cached
        }

        guard let passwd = getpwuid(uid) else {
            return "\(uid)"
        }

        let username = String(cString: passwd.pointee.pw_name)
        userCache[uid] = username
        return username
    }

    private func mapProcessStatus(_ status: UInt32) -> Process.ProcessStatus {
        switch status {
        case UInt32(SIDL):
            return .idle
        case UInt32(SRUN):
            return .running
        case UInt32(SSLEEP):
            return .sleeping
        case UInt32(SSTOP):
            return .stopped
        case UInt32(SZOMB):
            return .zombie
        default:
            return .unknown
        }
    }

    private func buildProcessTree(from processes: [Process]) -> [ProcessTreeNode] {
        var processMap: [Int32: Process] = [:]
        var childrenMap: [Int32: [Int32]] = [:]

        for process in processes {
            processMap[process.id] = process
            childrenMap[process.parentId, default: []].append(process.id)
        }

        func buildNode(pid: Int32) -> ProcessTreeNode? {
            guard let process = processMap[pid] else { return nil }

            let childPids = childrenMap[pid] ?? []
            let childNodes = childPids.compactMap { buildNode(pid: $0) }

            return ProcessTreeNode(process: process, children: childNodes)
        }

        // Find root processes (those whose parent is not in our list or is 0/1)
        let rootPids = processes.filter { process in
            process.parentId == 0 ||
            process.parentId == 1 ||
            processMap[process.parentId] == nil
        }.map { $0.id }

        return rootPids.compactMap { buildNode(pid: $0) }
    }

    // MARK: - System Info

    private static func getPhysicalMemory() -> UInt64 {
        var size = MemoryLayout<UInt64>.size
        var memory: UInt64 = 0
        sysctlbyname("hw.memsize", &memory, &size, nil, 0)
        return memory
    }
}
