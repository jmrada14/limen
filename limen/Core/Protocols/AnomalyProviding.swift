//
//  AnomalyProviding.swift
//  limen
//
//  Protocol for anomaly detection capabilities.
//

import Foundation

/// Protocol for anomaly detection services
public protocol AnomalyProviding: Sendable {
    /// Analyze system data and detect anomalies
    func analyze(
        processes: [Process],
        connections: [NetworkConnection],
        ports: [Port],
        networkStats: NetworkStats?
    ) -> [Anomaly]

    /// Get currently active anomalies
    func getActiveAnomalies() -> [Anomaly]

    /// Get anomaly history
    func getAnomalyHistory() -> [Anomaly]

    /// Get anomaly summary
    func getSummary() -> AnomalySummary

    /// Clear anomaly history
    func clearHistory()

    /// Reset all baselines
    func resetBaselines()

    /// Update detection configuration
    func updateConfig(_ config: AnomalyDetectionConfig)

    /// Get current configuration
    func getConfig() -> AnomalyDetectionConfig

    /// Check if a specific process is anomalous
    func isProcessAnomalous(_ pid: Int32) -> Bool

    /// Get anomalies for a specific process
    func getAnomaliesForProcess(_ pid: Int32) -> [Anomaly]

    /// Check if a specific port is anomalous
    func isPortAnomalous(_ port: UInt16) -> Bool

    /// Get anomalies for a specific port
    func getAnomaliesForPort(_ port: UInt16) -> [Anomaly]

    /// Filter anomalies by category
    func getAnomalies(category: AnomalyCategory) -> [Anomaly]

    /// Filter anomalies by severity
    func getAnomalies(minimumSeverity: AnomalySeverity) -> [Anomaly]
}

// MARK: - AnomalyDetectionService Conformance

extension AnomalyDetectionService: AnomalyProviding {}
