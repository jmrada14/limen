//
//  AnomalyDetectionService.swift
//  limen
//
//  Service for detecting anomalies in processes, network, and ports.
//  Maintains baselines and triggers alerts when deviations are detected.
//

import Foundation

/// Service for detecting anomalies across system resources
public final class AnomalyDetectionService: @unchecked Sendable {
    private let lock = NSLock()

    // Configuration
    private var config: AnomalyDetectionConfig

    // Baselines
    private var processBaselines: [Int32: ProcessBaseline] = [:]
    private var networkBaseline: NetworkBaseline = NetworkBaseline()
    private var portBaseline: PortBaseline = PortBaseline()

    // Known processes for detecting unusual ones
    private var knownProcessNames: Set<String> = []
    private var processFirstSeen: [String: Date] = [:]

    // Previous state for delta detection
    private var previousProcessCount: Int = 0
    private var previousPids: Set<Int32> = []
    private var previousConnectionsByProcess: [String: Int] = [:]

    // Active anomalies
    private var activeAnomalies: [Anomaly] = []
    private var anomalyHistory: [Anomaly] = []
    private let maxHistorySize = 100

    // Sample counter for baseline initialization
    private var sampleCount: Int = 0

    public init(config: AnomalyDetectionConfig = AnomalyDetectionConfig()) {
        self.config = config
        initializeKnownProcesses()
    }

    // MARK: - Configuration

    /// Update detection configuration
    public func updateConfig(_ config: AnomalyDetectionConfig) {
        lock.lock()
        defer { lock.unlock() }
        self.config = config
    }

    /// Get current configuration
    public func getConfig() -> AnomalyDetectionConfig {
        lock.lock()
        defer { lock.unlock() }
        return config
    }

    // MARK: - Main Detection

    /// Analyze system snapshot and detect anomalies
    public func analyze(
        processes: [Process],
        connections: [NetworkConnection],
        ports: [Port],
        networkStats: NetworkStats?
    ) -> [Anomaly] {
        lock.lock()
        defer { lock.unlock() }

        sampleCount += 1
        var detectedAnomalies: [Anomaly] = []

        // Update baselines
        updateProcessBaselines(processes)
        updateNetworkBaseline(networkStats, connectionCount: connections.count)
        portBaseline.update(ports: ports)

        // Only detect anomalies after minimum baseline samples
        guard sampleCount >= config.minSamplesForBaseline else {
            return []
        }

        // Detect anomalies
        detectedAnomalies.append(contentsOf: detectProcessAnomalies(processes))
        detectedAnomalies.append(contentsOf: detectNetworkAnomalies(connections, stats: networkStats))
        detectedAnomalies.append(contentsOf: detectPortAnomalies(ports))

        // Update active anomalies
        activeAnomalies = detectedAnomalies

        // Add to history
        for anomaly in detectedAnomalies {
            anomalyHistory.insert(anomaly, at: 0)
        }
        if anomalyHistory.count > maxHistorySize {
            anomalyHistory = Array(anomalyHistory.prefix(maxHistorySize))
        }

        // Update previous state
        previousProcessCount = processes.count
        previousPids = Set(processes.map { $0.id })

        var connByProcess: [String: Int] = [:]
        for conn in connections {
            if let name = conn.processName {
                connByProcess[name, default: 0] += 1
            }
        }
        previousConnectionsByProcess = connByProcess

        return detectedAnomalies
    }

    /// Get currently active anomalies
    public func getActiveAnomalies() -> [Anomaly] {
        lock.lock()
        defer { lock.unlock() }
        return activeAnomalies
    }

    /// Get anomaly history
    public func getAnomalyHistory() -> [Anomaly] {
        lock.lock()
        defer { lock.unlock() }
        return anomalyHistory
    }

    /// Get anomaly summary
    public func getSummary() -> AnomalySummary {
        lock.lock()
        defer { lock.unlock() }
        return AnomalySummary(anomalies: activeAnomalies)
    }

    /// Clear anomaly history
    public func clearHistory() {
        lock.lock()
        defer { lock.unlock() }
        anomalyHistory.removeAll()
    }

    /// Reset all baselines
    public func resetBaselines() {
        lock.lock()
        defer { lock.unlock() }
        processBaselines.removeAll()
        networkBaseline = NetworkBaseline()
        portBaseline = PortBaseline()
        sampleCount = 0
    }

    // MARK: - Process Anomaly Detection

    private func detectProcessAnomalies(_ processes: [Process]) -> [Anomaly] {
        var anomalies: [Anomaly] = []

        for process in processes {
            // CPU spike detection
            if let cpuAnomaly = detectCpuSpike(process) {
                anomalies.append(cpuAnomaly)
            }

            // Memory spike detection
            if let memoryAnomaly = detectMemorySpike(process) {
                anomalies.append(memoryAnomaly)
            }

            // Unusual process detection
            if let unusualAnomaly = detectUnusualProcess(process) {
                anomalies.append(unusualAnomaly)
            }

            // Zombie process detection
            if process.status == .zombie {
                anomalies.append(Anomaly(
                    type: .zombieProcess,
                    title: "Zombie Process: \(process.name)",
                    description: "Process \(process.name) (PID \(process.id)) is in zombie state",
                    details: .process(ProcessAnomalyDetails(
                        processName: process.name,
                        pid: process.id,
                        currentValue: 0,
                        baselineValue: 0,
                        threshold: 0,
                        userId: process.userId
                    )),
                    relatedPid: process.id
                ))
            }
        }

        // Rapid process spawn detection
        let currentPids = Set(processes.map { $0.id })
        let newPids = currentPids.subtracting(previousPids)
        if newPids.count > config.processSpawnRate {
            anomalies.append(Anomaly(
                type: .processSpawn,
                severity: .medium,
                title: "Rapid Process Spawning",
                description: "\(newPids.count) new processes spawned since last check",
                details: .none
            ))
        }

        return anomalies
    }

    private func detectCpuSpike(_ process: Process) -> Anomaly? {
        guard let baseline = processBaselines[process.id],
              baseline.cpuSamples.count >= config.minSamplesForBaseline else {
            return nil
        }

        let avgCpu = baseline.avgCpu
        let stdDev = baseline.cpuStdDev
        let threshold = max(avgCpu + stdDev * config.cpuSpikeMultiplier, config.cpuSpikeThreshold)

        guard process.cpuUsage > threshold else { return nil }

        let severity: AnomalySeverity
        if process.cpuUsage > 95 {
            severity = .critical
        } else if process.cpuUsage > 90 {
            severity = .high
        } else {
            severity = .medium
        }

        return Anomaly(
            type: .cpuSpike,
            severity: severity,
            title: "CPU Spike: \(process.name)",
            description: "Process \(process.name) CPU at \(String(format: "%.1f", process.cpuUsage))% (baseline: \(String(format: "%.1f", avgCpu))%)",
            details: .process(ProcessAnomalyDetails(
                processName: process.name,
                pid: process.id,
                currentValue: process.cpuUsage,
                baselineValue: avgCpu,
                threshold: threshold,
                userId: process.userId
            )),
            relatedPid: process.id
        )
    }

    private func detectMemorySpike(_ process: Process) -> Anomaly? {
        guard let baseline = processBaselines[process.id],
              baseline.memorySamples.count >= config.minSamplesForBaseline else {
            return nil
        }

        let avgMemory = baseline.avgMemory
        let stdDev = baseline.memoryStdDev
        let threshold = max(avgMemory + stdDev * config.memorySpikeMultiplier, config.memorySpikeThreshold)

        guard process.memoryPercent > threshold else { return nil }

        let severity: AnomalySeverity
        if process.memoryPercent > 90 {
            severity = .critical
        } else if process.memoryPercent > 80 {
            severity = .high
        } else {
            severity = .medium
        }

        return Anomaly(
            type: .memorySpike,
            severity: severity,
            title: "Memory Spike: \(process.name)",
            description: "Process \(process.name) memory at \(String(format: "%.1f", process.memoryPercent))% (baseline: \(String(format: "%.1f", avgMemory))%)",
            details: .process(ProcessAnomalyDetails(
                processName: process.name,
                pid: process.id,
                currentValue: process.memoryPercent,
                baselineValue: avgMemory,
                threshold: threshold,
                userId: process.userId
            )),
            relatedPid: process.id
        )
    }

    private func detectUnusualProcess(_ process: Process) -> Anomaly? {
        let name = process.name.lowercased()

        // Skip known system processes
        guard !knownProcessNames.contains(name) else { return nil }

        // Check if this is a recently seen process
        if let firstSeen = processFirstSeen[name] {
            // Only alert if process seen for less than 1 minute
            guard Date().timeIntervalSince(firstSeen) < 60 else { return nil }
        } else {
            processFirstSeen[name] = Date()
        }

        // Check for suspicious characteristics
        var suspiciousReasons: [String] = []

        // Process with no path (could be hidden)
        if process.path == nil {
            suspiciousReasons.append("no executable path")
        }

        // Process running as root from unusual location
        if process.userId == 0, let path = process.path {
            let suspiciousPaths = ["/tmp/", "/var/tmp/", "/Users/", "/private/tmp/"]
            for suspPath in suspiciousPaths {
                if path.hasPrefix(suspPath) {
                    suspiciousReasons.append("root process in \(suspPath)")
                    break
                }
            }
        }

        // Process with suspicious name patterns
        let suspiciousPatterns = ["nc", "ncat", "netcat", "socat", "reverse", "shell", "backdoor", "exploit", "payload"]
        for pattern in suspiciousPatterns {
            if name.contains(pattern) {
                suspiciousReasons.append("suspicious name pattern '\(pattern)'")
                break
            }
        }

        guard !suspiciousReasons.isEmpty else { return nil }

        return Anomaly(
            type: .unusualProcess,
            severity: process.userId == 0 ? .critical : .high,
            title: "Unusual Process: \(process.name)",
            description: "Detected unusual process: \(suspiciousReasons.joined(separator: ", "))",
            details: .process(ProcessAnomalyDetails(
                processName: process.name,
                pid: process.id,
                currentValue: 0,
                baselineValue: 0,
                threshold: 0,
                userId: process.userId
            )),
            relatedPid: process.id
        )
    }

    // MARK: - Network Anomaly Detection

    private func detectNetworkAnomalies(_ connections: [NetworkConnection], stats: NetworkStats?) -> [Anomaly] {
        var anomalies: [Anomaly] = []

        // Traffic spike detection
        if let stats = stats {
            if let trafficAnomaly = detectTrafficSpike(stats) {
                anomalies.append(trafficAnomaly)
            }
        }

        // Connection flood detection
        var connectionsByProcess: [String: [NetworkConnection]] = [:]
        for conn in connections {
            if let name = conn.processName {
                connectionsByProcess[name, default: []].append(conn)
            }
        }

        for (processName, conns) in connectionsByProcess {
            if conns.count > config.connectionFloodThreshold {
                let previousCount = previousConnectionsByProcess[processName] ?? 0
                // Only alert if significant increase
                if conns.count > previousCount + 20 {
                    anomalies.append(Anomaly(
                        type: .connectionFlood,
                        severity: .high,
                        title: "Connection Flood: \(processName)",
                        description: "\(processName) has \(conns.count) active connections",
                        details: .network(NetworkAnomalyDetails(
                            connectionCount: conns.count,
                            processName: processName
                        )),
                        relatedPid: conns.first?.pid
                    ))
                }
            }
        }

        // Suspicious connection detection
        for conn in connections {
            if let suspiciousAnomaly = detectSuspiciousConnection(conn) {
                anomalies.append(suspiciousAnomaly)
            }
        }

        return anomalies
    }

    private func detectTrafficSpike(_ stats: NetworkStats) -> Anomaly? {
        guard networkBaseline.bytesInSamples.count >= config.minSamplesForBaseline else {
            return nil
        }

        let totalBytesPerSec = stats.bytesInPerSecond + stats.bytesOutPerSecond
        let avgTotal = networkBaseline.avgBytesIn + networkBaseline.avgBytesOut
        let threshold = max(avgTotal * config.trafficSpikeMultiplier, config.minBytesForSpike)

        guard totalBytesPerSec > threshold else { return nil }

        let severity: AnomalySeverity
        let ratio = totalBytesPerSec / max(avgTotal, 1)
        if ratio > 10 {
            severity = .critical
        } else if ratio > 7 {
            severity = .high
        } else {
            severity = .medium
        }

        return Anomaly(
            type: .trafficSpike,
            severity: severity,
            title: "Network Traffic Spike",
            description: "Traffic at \(LimenCore.formatBytesPerSecond(totalBytesPerSec)) (baseline: \(LimenCore.formatBytesPerSecond(avgTotal)))",
            details: .network(NetworkAnomalyDetails(
                bytesPerSecond: totalBytesPerSec,
                baselineBytesPerSecond: avgTotal,
                connectionCount: stats.activeConnections
            ))
        )
    }

    private func detectSuspiciousConnection(_ conn: NetworkConnection) -> Anomaly? {
        // Check for suspicious ports (skip if port is 0, which means no remote connection)
        if conn.remotePort > 0 && config.suspiciousPorts.contains(conn.remotePort) {
            return Anomaly(
                type: .suspiciousPort,
                severity: .high,
                title: "Suspicious Port Connection",
                description: "Connection to suspicious port \(conn.remotePort) from \(conn.processName ?? "unknown")",
                details: .network(NetworkAnomalyDetails(
                    remoteAddress: conn.remoteAddress,
                    remotePort: conn.remotePort,
                    processName: conn.processName
                )),
                relatedPid: conn.pid,
                relatedPort: conn.remotePort,
                relatedAddress: conn.remoteAddress
            )
        }

        // Check for unusual protocols (non-standard ports with high traffic potential)
        // Could be expanded with more sophisticated protocol analysis

        return nil
    }

    // MARK: - Port Anomaly Detection

    private func detectPortAnomalies(_ ports: [Port]) -> [Anomaly] {
        var anomalies: [Anomaly] = []

        for port in ports {
            // New listening port detection
            if config.alertOnNewListeningPorts && port.state == .listening {
                if portBaseline.isNewPort(port.number, protocol: port.protocol.rawValue) {
                    let severity: AnomalySeverity = port.number < config.privilegedPortThreshold ? .high : .medium

                    anomalies.append(Anomaly(
                        type: .newListeningPort,
                        severity: severity,
                        title: "New Listening Port: \(port.number)",
                        description: "New \(port.protocol.rawValue) port \(port.number) opened by \(port.processName ?? "unknown")",
                        details: .port(PortAnomalyDetails(
                            port: port.number,
                            protocol: port.protocol.rawValue,
                            processName: port.processName,
                            pid: port.pid,
                            isPrivileged: port.number < config.privilegedPortThreshold
                        )),
                        relatedPid: port.pid,
                        relatedPort: port.number
                    ))
                }
            }

            // Privileged port opened by non-system process
            if port.number < config.privilegedPortThreshold && port.state == .listening {
                if let processName = port.processName {
                    let systemProcesses = ["launchd", "kernel_task", "mDNSResponder", "httpd", "nginx", "apache"]
                    if !systemProcesses.contains(where: { processName.lowercased().contains($0.lowercased()) }) {
                        // Check if this is a known service
                        let knownServices: [UInt16] = [22, 80, 443, 53, 67, 68, 123, 5353]
                        if !knownServices.contains(port.number) {
                            anomalies.append(Anomaly(
                                type: .privilegedPort,
                                severity: .critical,
                                title: "Privileged Port: \(port.number)",
                                description: "Non-system process \(processName) listening on privileged port \(port.number)",
                                details: .port(PortAnomalyDetails(
                                    port: port.number,
                                    protocol: port.protocol.rawValue,
                                    processName: processName,
                                    pid: port.pid,
                                    isPrivileged: true
                                )),
                                relatedPid: port.pid,
                                relatedPort: port.number
                            ))
                        }
                    }
                }
            }

            // Suspicious port detection
            if config.suspiciousPorts.contains(port.number) && port.state == .listening {
                anomalies.append(Anomaly(
                    type: .unusualPortActivity,
                    severity: .high,
                    title: "Suspicious Port Listening: \(port.number)",
                    description: "Process \(port.processName ?? "unknown") listening on suspicious port \(port.number)",
                    details: .port(PortAnomalyDetails(
                        port: port.number,
                        protocol: port.protocol.rawValue,
                        processName: port.processName,
                        pid: port.pid,
                        isPrivileged: port.number < config.privilegedPortThreshold
                    )),
                    relatedPid: port.pid,
                    relatedPort: port.number
                ))
            }
        }

        return anomalies
    }

    // MARK: - Baseline Management

    private func updateProcessBaselines(_ processes: [Process]) {
        for process in processes {
            if var baseline = processBaselines[process.id] {
                baseline.addSample(
                    cpu: process.cpuUsage,
                    memory: process.memoryPercent,
                    maxSamples: config.baselineWindowSize
                )
                processBaselines[process.id] = baseline
            } else {
                var baseline = ProcessBaseline(pid: process.id, name: process.name)
                baseline.addSample(
                    cpu: process.cpuUsage,
                    memory: process.memoryPercent,
                    maxSamples: config.baselineWindowSize
                )
                processBaselines[process.id] = baseline
            }
        }

        // Clean up old baselines for processes that no longer exist
        let currentPids = Set(processes.map { $0.id })
        let stalePids = processBaselines.keys.filter { !currentPids.contains($0) }
        for pid in stalePids {
            processBaselines.removeValue(forKey: pid)
        }
    }

    private func updateNetworkBaseline(_ stats: NetworkStats?, connectionCount: Int) {
        guard let stats = stats else { return }
        networkBaseline.addSample(
            bytesIn: stats.bytesInPerSecond,
            bytesOut: stats.bytesOutPerSecond,
            connections: connectionCount,
            maxSamples: config.baselineWindowSize
        )
    }

    // MARK: - Known Processes

    private func initializeKnownProcesses() {
        // Common macOS system processes
        knownProcessNames = Set([
            "kernel_task", "launchd", "loginwindow", "windowserver", "finder",
            "dock", "systemuiserver", "notificationcenterui", "cfprefsd",
            "distnoted", "coreaudiod", "coreservicesd", "mdworker", "mds",
            "spotlight", "usermanagerd", "diskarbitrationd", "securityd",
            "powerd", "trustd", "opendirectoryd", "networkd", "nsurlsessiond",
            "usernotificationcenter", "sharedfilelistd", "quicklook",
            "syncdefaultsd", "imagent", "callservicesd", "identityservicesd",
            "apsd", "locationd", "cloudd", "bird", "assistantd",
            "mediaremoted", "mediaanalysisd", "photoanalysisd", "photolibraryd",
            "softwareupdated", "appstoreagent", "storedownloadd",
            "sandboxd", "symptomsd", "analyticsd", "diagnosticd",
            "ctkd", "containermanagerd", "biomesyncd", "duetexpertd",
            "airplayuiagent", "controlcenter", "syspolicyd", "thermald",
            "amfid", "logd", "syslogd", "iconservicesagent", "lsd",
            "revisiond", "secinitd", "contextstored", "bluetoothd",
            "audioaccessoryd", "airportd", "wifi-network-cm", "wifip2pd",
            "xpc_service", "com.apple", "safari", "chrome", "firefox",
            "code", "terminal", "iterm", "xcode", "simulator"
        ])
    }
}

// MARK: - Convenience Extensions

extension AnomalyDetectionService {
    /// Check if a specific process is anomalous
    public func isProcessAnomalous(_ pid: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeAnomalies.contains { $0.relatedPid == pid }
    }

    /// Get anomalies for a specific process
    public func getAnomaliesForProcess(_ pid: Int32) -> [Anomaly] {
        lock.lock()
        defer { lock.unlock() }
        return activeAnomalies.filter { $0.relatedPid == pid }
    }

    /// Check if a specific port is anomalous
    public func isPortAnomalous(_ port: UInt16) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeAnomalies.contains { $0.relatedPort == port }
    }

    /// Get anomalies for a specific port
    public func getAnomaliesForPort(_ port: UInt16) -> [Anomaly] {
        lock.lock()
        defer { lock.unlock() }
        return activeAnomalies.filter { $0.relatedPort == port }
    }

    /// Filter anomalies by category
    public func getAnomalies(category: AnomalyCategory) -> [Anomaly] {
        lock.lock()
        defer { lock.unlock() }
        return activeAnomalies.filter { $0.category == category }
    }

    /// Filter anomalies by severity
    public func getAnomalies(minimumSeverity: AnomalySeverity) -> [Anomaly] {
        lock.lock()
        defer { lock.unlock() }
        return activeAnomalies.filter { $0.severity >= minimumSeverity }
    }
}
