//
//  ProcessInfo.swift
//  limen
//
//  Data model for process information.
//

import Foundation

struct ProcessItem: Identifiable, Hashable {
    let id: Int32  // PID
    let name: String
    let user: String
    let cpuUsage: Double
    let memoryUsage: UInt64
    let status: ProcessStatus
    let startTime: Date?

    enum ProcessStatus: String {
        case running = "Running"
        case sleeping = "Sleeping"
        case stopped = "Stopped"
        case zombie = "Zombie"
        case unknown = "Unknown"
    }
}

struct NetworkConnection: Identifiable, Hashable {
    let id: UUID
    let localAddress: String
    let localPort: UInt16
    let remoteAddress: String
    let remotePort: UInt16
    let state: ConnectionState
    let processId: Int32?
    let processName: String?

    enum ConnectionState: String {
        case established = "Established"
        case listen = "Listen"
        case timeWait = "Time Wait"
        case closeWait = "Close Wait"
        case closed = "Closed"
        case unknown = "Unknown"
    }
}
