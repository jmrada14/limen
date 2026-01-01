//
//  ProcessSafety.swift
//  limen
//
//  Defines process safety levels and provides kill protection.
//

import Foundation

/// Safety level for a process - determines how hard it is to kill
public enum ProcessSafetyLevel: Int, Comparable, Sendable {
    /// Critical system process - killing will crash/freeze the system
    /// These processes should NEVER be killed under any circumstances
    case critical = 0

    /// Core system process - killing may cause system instability
    /// Requires explicit confirmation and displays strong warning
    case system = 1

    /// Important user process - killing may cause data loss
    /// Shows warning about potential consequences
    case important = 2

    /// Regular user process - can be killed with single confirmation
    case normal = 3

    /// Background/helper process - can be killed easily
    case background = 4

    public static func < (lhs: ProcessSafetyLevel, rhs: ProcessSafetyLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var description: String {
        switch self {
        case .critical: return "Critical System Process"
        case .system: return "System Process"
        case .important: return "Important Process"
        case .normal: return "Normal Process"
        case .background: return "Background Process"
        }
    }

    public var warningMessage: String? {
        switch self {
        case .critical:
            return "This is a critical system process. Killing it WILL crash or freeze your Mac. This action is blocked for your protection."
        case .system:
            return "This is a core system process. Killing it may cause system instability, application crashes, or require a restart. Are you absolutely sure?"
        case .important:
            return "This process may have unsaved data. Killing it could result in data loss. Continue?"
        case .normal:
            return "Are you sure you want to quit this process?"
        case .background:
            return nil
        }
    }
}

/// Result of attempting to kill a process
public enum KillResult: Sendable {
    case success
    case blocked(reason: String)
    case requiresConfirmation(level: ProcessSafetyLevel, message: String)
    case failed(error: String)
    case accessDenied
    case processNotFound
}

/// Manages process safety classifications
public struct ProcessSafety: Sendable {

    // MARK: - Critical Processes (NEVER kill)

    /// Processes that will crash/freeze the system if killed
    /// These are absolutely protected - no override possible
    public static let criticalProcessNames: Set<String> = [
        // Kernel and core
        "kernel_task",
        "launchd",

        // Window server - killing freezes display
        "WindowServer",

        // Core system daemons
        "configd",
        "diskarbitrationd",
        "securityd",
        "trustd",
        "syspolicyd",

        // File system
        "fseventsd",
        "mds",
        "mds_stores",
        "notifyd",

        // Power management
        "powerd",
        "thermald",

        // Core frameworks
        "cfprefsd",
        "coreservicesd",
        "lsd",

        // Login/session
        "loginwindow",
        "logd",
        "syslogd",

        // Memory management
        "kernel",
        "memorystatus",
    ]

    /// PIDs that are always critical
    public static let criticalPIDs: Set<Int32> = [
        0,  // kernel
        1,  // launchd
    ]

    // MARK: - System Processes (Warn strongly)

    /// System processes that can technically be killed but may cause issues
    public static let systemProcessNames: Set<String> = [
        // Finder and Dock
        "Finder",
        "Dock",

        // System UI
        "SystemUIServer",
        "ControlCenter",
        "NotificationCenter",
        "Spotlight",

        // Core services
        "coreaudiod",
        "coreduetd",
        "distnoted",
        "runningboardd",

        // Network
        "mDNSResponder",
        "networkd",
        "symptomsd",
        "WiFiAgent",

        // Bluetooth
        "bluetoothd",
        "BTServer",

        // Input
        "hidd",

        // Time
        "timed",

        // Printing
        "cupsd",

        // Spotlight
        "corespotlightd",

        // User session
        "sharedfilelistd",
        "CoreServicesUIAgent",

        // System extensions
        "sysextd",
        "endpointsecurityd",
    ]

    // MARK: - Important Processes (Warn about data loss)

    /// Processes that commonly have unsaved data
    public static let importantProcessPatterns: [String] = [
        // Document editors
        "TextEdit",
        "Pages",
        "Numbers",
        "Keynote",
        "Microsoft Word",
        "Microsoft Excel",
        "Microsoft PowerPoint",

        // IDEs and editors
        "Xcode",
        "Visual Studio",
        "Code",  // VS Code
        "Sublime",
        "Atom",
        "IntelliJ",
        "PyCharm",
        "WebStorm",

        // Creative apps
        "Photoshop",
        "Illustrator",
        "Premiere",
        "Final Cut",
        "Logic Pro",
        "GarageBand",
        "Sketch",
        "Figma",

        // Browsers (may have forms/work)
        "Safari",
        "Google Chrome",
        "Firefox",
        "Arc",
        "Brave",

        // Communication
        "Mail",
        "Messages",
        "Slack",
        "Discord",
        "Zoom",
        "Teams",

        // Notes/Writing
        "Notes",
        "Obsidian",
        "Notion",
        "Bear",
        "Ulysses",

        // Database tools
        "TablePlus",
        "Sequel",
        "MongoDB",
        "Postgres",
    ]

    // MARK: - Classification

    /// Classify a process by its safety level
    public static func classify(name: String, pid: Int32, userId: UInt32) -> ProcessSafetyLevel {
        // Check critical PIDs first
        if criticalPIDs.contains(pid) {
            return .critical
        }

        // Check critical process names
        if criticalProcessNames.contains(name) {
            return .critical
        }

        // Check system processes
        if systemProcessNames.contains(name) {
            return .system
        }

        // Check if it's a root process (potential system process)
        if userId == 0 && !isKnownUserProcess(name) {
            // Unknown root processes are treated as system level
            return .system
        }

        // Check important processes (pattern matching)
        for pattern in importantProcessPatterns {
            if name.localizedCaseInsensitiveContains(pattern) {
                return .important
            }
        }

        // Check for helper/agent processes
        if name.hasSuffix("Helper") ||
           name.hasSuffix("Agent") ||
           name.hasSuffix("_service") ||
           name.contains("XPC") {
            return .background
        }

        return .normal
    }

    /// Check if a process name is a known user application
    private static func isKnownUserProcess(_ name: String) -> Bool {
        let userProcesses: Set<String> = [
            "iTerm2",
            "Terminal",
            "Safari",
            "Google Chrome",
            "Firefox",
            "Finder",
            "Mail",
            "Messages",
            "Calendar",
            "Reminders",
            "Notes",
            "Photos",
            "Music",
            "Podcasts",
            "News",
            "Stocks",
            "Home",
            "FaceTime",
        ]
        return userProcesses.contains(name)
    }

    // MARK: - Kill Validation

    /// Validate if a process can be killed and what confirmation is needed
    public static func validateKill(
        name: String,
        pid: Int32,
        userId: UInt32,
        force: Bool = false
    ) -> KillResult {
        let level = classify(name: name, pid: pid, userId: userId)

        switch level {
        case .critical:
            return .blocked(reason: """
                Cannot kill '\(name)' (PID: \(pid)).

                This is a critical system process. Killing it would crash or freeze your Mac.

                If this process is causing problems, please restart your computer instead.
                """)

        case .system:
            if force {
                return .requiresConfirmation(level: level, message: """
                    ⚠️ DANGER: You are about to force quit a system process.

                    Process: \(name) (PID: \(pid))

                    This may cause:
                    • System instability
                    • Application crashes
                    • Loss of unsaved work
                    • Need to restart your Mac

                    Only proceed if you understand the risks.
                    """)
            } else {
                return .requiresConfirmation(level: level, message: """
                    ⚠️ Warning: '\(name)' is a system process.

                    Quitting it may cause system instability or require a restart.

                    Consider restarting your Mac instead if you're experiencing issues.
                    """)
            }

        case .important:
            return .requiresConfirmation(level: level, message: """
                '\(name)' may have unsaved work.

                Any unsaved changes will be lost if you quit this application.
                """)

        case .normal:
            return .requiresConfirmation(level: level, message: """
                Quit '\(name)'?
                """)

        case .background:
            return .success
        }
    }
}

// MARK: - Process Extension

public extension Process {
    /// Get the safety level for this process
    var safetyLevel: ProcessSafetyLevel {
        ProcessSafety.classify(name: name, pid: id, userId: userId)
    }

    /// Check if this process can be safely killed
    var canBeKilled: Bool {
        safetyLevel != .critical
    }

    /// Get kill validation result
    func validateKill(force: Bool = false) -> KillResult {
        ProcessSafety.validateKill(name: name, pid: id, userId: userId, force: force)
    }
}
