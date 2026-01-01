//
//  PortProvider.swift
//  limen
//
//  Implementation of port monitoring using lsof and netstat.
//

import Foundation
import Darwin

/// macOS implementation of PortProviding
public final class PortProvider: PortProviding, @unchecked Sendable {
    private let networkProvider: NetworkProvider
    private let processProvider: ProcessProvider

    public init(networkProvider: NetworkProvider = NetworkProvider(), processProvider: ProcessProvider = ProcessProvider()) {
        self.networkProvider = networkProvider
        self.processProvider = processProvider
    }

    // MARK: - PortProviding

    public func listPorts() async throws -> [Port] {
        try await Task.detached(priority: .userInitiated) {
            try self.fetchAllPorts()
        }.value
    }

    public func listListeningPorts() async throws -> [Port] {
        try await Task.detached(priority: .userInitiated) {
            try self.fetchListeningPorts()
        }.value
    }

    public func getPorts(forPid pid: Int32) async throws -> [Port] {
        let allPorts = try await listPorts()
        return allPorts.filter { $0.pid == pid }
    }

    public func isPortInUse(port: UInt16, protocol proto: Port.PortProtocol) async throws -> Bool {
        let info = try await getPortInfo(port: port, protocol: proto)
        return info != nil
    }

    public func getPortInfo(port: UInt16, protocol proto: Port.PortProtocol) async throws -> Port? {
        let allPorts = try await listPorts()
        return allPorts.first { $0.number == port && $0.protocol == proto }
    }

    public func getSummary() async throws -> PortSummary {
        let allPorts = try await listPorts()

        let listening = allPorts.filter { $0.state == .listening }
        let established = allPorts.filter { $0.state == .established }
        let tcp = allPorts.filter { $0.protocol == .tcp || $0.protocol == .tcp6 }
        let udp = allPorts.filter { $0.protocol == .udp || $0.protocol == .udp6 }
        let privileged = allPorts.filter { $0.number < 1024 }
        let unprivileged = allPorts.filter { $0.number >= 1024 }

        return PortSummary(
            totalListening: listening.count,
            totalEstablished: established.count,
            tcpPorts: tcp.count,
            udpPorts: udp.count,
            portsUnder1024: privileged.count,
            portsOver1024: unprivileged.count
        )
    }

    public func findProcess(usingPort port: UInt16, protocol proto: Port.PortProtocol) async throws -> (pid: Int32, name: String)? {
        guard let portInfo = try await getPortInfo(port: port, protocol: proto),
              let pid = portInfo.pid,
              let name = portInfo.processName else {
            return nil
        }
        return (pid, name)
    }

    // MARK: - Port Control

    public func closePort(port: UInt16, protocol proto: Port.PortProtocol, force: Bool) async -> PortCloseResult {
        // First validate the close
        let validation = await validateClosePort(port: port, protocol: proto, force: force)

        switch validation {
        case .blocked:
            return validation
        case .requiresConfirmation:
            return validation
        case .accessDenied, .portNotInUse, .failed:
            return validation
        case .success:
            break
        }

        return await executeConfirmedClose(port: port, protocol: proto, forceQuit: force)
    }

    public func validateClosePort(port: UInt16, protocol proto: Port.PortProtocol, force: Bool) async -> PortCloseResult {
        // Get port info to find the process
        guard let portInfo = try? await getPortInfo(port: port, protocol: proto) else {
            return .portNotInUse
        }

        guard let pid = portInfo.pid else {
            return .failed(error: "Could not determine which process is using this port")
        }

        // Get full process info for better classification
        let process = try? await processProvider.getProcess(pid: pid)
        let userId = process?.userId

        // Use PortSafety to validate
        return PortSafety.validateKill(
            port: port,
            processName: portInfo.processName,
            processPid: pid,
            processUserId: userId,
            force: force
        )
    }

    public func executeConfirmedClose(port: UInt16, protocol proto: Port.PortProtocol, forceQuit: Bool) async -> PortCloseResult {
        // Get the process using this port
        guard let portInfo = try? await getPortInfo(port: port, protocol: proto),
              let pid = portInfo.pid else {
            return .portNotInUse
        }

        // Re-check safety (defense in depth)
        let level = PortSafety.classify(
            port: port,
            processName: portInfo.processName,
            processPid: pid,
            processUserId: nil
        )

        if level == .critical {
            return .blocked(reason: "Critical system port - close blocked for safety")
        }

        // Delegate to ProcessProvider to kill the process
        let signal = forceQuit ? SIGKILL : SIGTERM
        let killResult = await processProvider.executeConfirmedKill(pid: pid, signal: signal)

        // Convert KillResult to PortCloseResult
        switch killResult {
        case .success:
            return .success
        case .blocked(let reason):
            return .blocked(reason: reason)
        case .requiresConfirmation(let level, let message):
            // Shouldn't happen at this stage, but handle it
            return .requiresConfirmation(
                level: PortSafetyLevel(rawValue: level.rawValue) ?? .normal,
                message: message,
                processName: portInfo.processName
            )
        case .failed(let error):
            return .failed(error: error)
        case .accessDenied:
            return .accessDenied
        case .processNotFound:
            // Port may have been closed by another means
            return .success
        }
    }

    // MARK: - Private Implementation

    private func fetchAllPorts() throws -> [Port] {
        // Use lsof to get all network ports with process info
        let output = try runCommand("/usr/sbin/lsof", arguments: ["-i", "-n", "-P"])
        return parseLsofOutputToPorts(output)
    }

    private func fetchListeningPorts() throws -> [Port] {
        // Use lsof to get only listening TCP ports
        let tcpOutput = try runCommand("/usr/sbin/lsof", arguments: ["-iTCP", "-sTCP:LISTEN", "-n", "-P"])
        var ports = parseLsofOutputToPorts(tcpOutput)

        // Add UDP ports (UDP doesn't have LISTEN state, but bound ports)
        let udpOutput = try runCommand("/usr/sbin/lsof", arguments: ["-iUDP", "-n", "-P"])
        let udpPorts = parseLsofOutputToPorts(udpOutput)
            .map { port -> Port in
                // Mark UDP ports as listening if they're bound
                Port(
                    id: port.id,
                    number: port.number,
                    protocol: port.protocol,
                    state: .listening,
                    address: port.address,
                    pid: port.pid,
                    processName: port.processName,
                    serviceName: port.serviceName,
                    connectionCount: port.connectionCount
                )
            }

        ports.append(contentsOf: udpPorts)

        // Remove duplicates based on port number and protocol
        var seen: Set<String> = []
        return ports.filter { port in
            let key = "\(port.number)-\(port.protocol.rawValue)"
            if seen.contains(key) {
                return false
            }
            seen.insert(key)
            return true
        }.sorted { $0.number < $1.number }
    }

    private func parseLsofOutputToPorts(_ output: String) -> [Port] {
        var portMap: [String: (port: Port, count: Int)] = [:]
        let lines = output.components(separatedBy: "\n")

        for line in lines.dropFirst() {
            guard !line.isEmpty else { continue }

            let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 9 else { continue }

            let processName = parts[0]
            guard let pid = Int32(parts[1]) else { continue }

            let protocolStr = parts[7]
            let proto: Port.PortProtocol
            if protocolStr.contains("TCP") {
                proto = protocolStr.contains("6") ? .tcp6 : .tcp
            } else if protocolStr.contains("UDP") {
                proto = protocolStr.contains("6") ? .udp6 : .udp
            } else {
                continue
            }

            let nameColumn = parts.dropFirst(8).joined(separator: " ")

            // Parse port from the name column
            guard let portInfo = parsePortFromLsofName(nameColumn, protocol: proto) else { continue }

            let state: Port.PortState
            if nameColumn.contains("LISTEN") {
                state = .listening
            } else if nameColumn.contains("ESTABLISHED") || nameColumn.contains("->") {
                state = .established
            } else {
                state = .bound
            }

            let serviceName = Port.commonServiceName(for: portInfo.port)

            let key = "\(portInfo.port)-\(proto.rawValue)"

            if let existing = portMap[key] {
                // Update connection count
                portMap[key] = (existing.port, existing.count + 1)
            } else {
                let port = Port(
                    number: portInfo.port,
                    protocol: proto,
                    state: state,
                    address: portInfo.address,
                    pid: pid,
                    processName: processName,
                    serviceName: serviceName,
                    connectionCount: 1
                )
                portMap[key] = (port, 1)
            }
        }

        return portMap.map { (_, value) in
            Port(
                id: value.port.id,
                number: value.port.number,
                protocol: value.port.protocol,
                state: value.port.state,
                address: value.port.address,
                pid: value.port.pid,
                processName: value.port.processName,
                serviceName: value.port.serviceName,
                connectionCount: value.count
            )
        }.sorted { $0.number < $1.number }
    }

    private func parsePortFromLsofName(_ name: String, protocol proto: Port.PortProtocol) -> (port: UInt16, address: String)? {
        // Format: "addr:port" or "*:port" or "addr:port->remote:port"
        var cleanName = name

        // Remove state info in parentheses
        if let parenIndex = cleanName.firstIndex(of: "(") {
            cleanName = String(cleanName[..<parenIndex]).trimmingCharacters(in: .whitespaces)
        }

        // Take the local part (before ->)
        if let arrowIndex = cleanName.range(of: "->") {
            cleanName = String(cleanName[..<arrowIndex.lowerBound])
        }

        cleanName = cleanName.trimmingCharacters(in: .whitespaces)

        // Handle IPv6 [addr]:port
        if cleanName.hasPrefix("[") {
            if let closeBracket = cleanName.lastIndex(of: "]") {
                let address = String(cleanName[cleanName.index(after: cleanName.startIndex)..<closeBracket])
                let afterBracket = cleanName.index(after: closeBracket)
                if afterBracket < cleanName.endIndex && cleanName[afterBracket] == ":" {
                    let portStr = String(cleanName[cleanName.index(after: afterBracket)...])
                    if let port = UInt16(portStr) {
                        return (port, address)
                    }
                }
            }
        }

        // Handle regular addr:port
        if let lastColon = cleanName.lastIndex(of: ":") {
            let address = String(cleanName[..<lastColon])
            let portStr = String(cleanName[cleanName.index(after: lastColon)...])
            if let port = UInt16(portStr) {
                return (port, address.isEmpty ? "*" : address)
            }
        }

        return nil
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
