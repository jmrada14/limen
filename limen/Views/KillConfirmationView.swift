//
//  KillConfirmationView.swift
//  limen
//
//  Confirmation dialogs for terminating processes with appropriate warnings.
//

import SwiftUI
import Combine

/// State for managing kill confirmation flow
@MainActor
class KillConfirmationState: ObservableObject {
    @Published var isPresented: Bool = false
    @Published var process: Process?
    @Published var killResult: KillResult?
    @Published var forceQuit: Bool = false
    @Published var isExecuting: Bool = false
    @Published var confirmationText: String = ""

    // For system-level processes, require typing confirmation
    var requiresTextConfirmation: Bool {
        guard let process = process else { return false }
        return process.safetyLevel == .system
    }

    var textConfirmationValid: Bool {
        confirmationText.lowercased() == "kill"
    }

    func reset() {
        isPresented = false
        process = nil
        killResult = nil
        forceQuit = false
        isExecuting = false
        confirmationText = ""
    }

    func presentKill(for process: Process, forceQuit: Bool = false) async {
        self.process = process
        self.forceQuit = forceQuit
        self.confirmationText = ""
        self.isExecuting = false

        // Get the kill validation result
        let result = ProcessSafety.validateKill(
            name: process.name,
            pid: process.id,
            userId: process.userId,
            force: forceQuit
        )

        self.killResult = result

        switch result {
        case .blocked:
            // Show blocked message
            self.isPresented = true
        case .requiresConfirmation:
            // Show confirmation dialog
            self.isPresented = true
        case .success:
            // Background process - no confirmation needed
            // But we still set isPresented so caller knows to proceed
            self.isPresented = false
        default:
            self.isPresented = true
        }
    }
}

/// Main kill confirmation sheet
struct KillConfirmationSheet: View {
    @ObservedObject var state: KillConfirmationState
    let onConfirm: (Process, Bool) async -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if let process = state.process, let result = state.killResult {
                switch result {
                case .blocked(let reason):
                    BlockedView(processName: process.name, reason: reason, onDismiss: onCancel)

                case .requiresConfirmation(let level, let message):
                    ConfirmationView(
                        state: state,
                        process: process,
                        level: level,
                        message: message,
                        onConfirm: onConfirm,
                        onCancel: onCancel
                    )

                case .accessDenied:
                    AccessDeniedView(processName: process.name, onDismiss: onCancel)

                case .processNotFound:
                    ProcessNotFoundView(processName: process.name, onDismiss: onCancel)

                case .failed(let error):
                    FailedView(processName: process.name, error: error, onDismiss: onCancel)

                case .success:
                    // Shouldn't happen in sheet, but handle gracefully
                    EmptyView()
                }
            }
        }
        .frame(width: 380)
    }
}

// MARK: - Blocked View

struct BlockedView: View {
    let processName: String
    let reason: String
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 48))
                .foregroundStyle(.red)

            Text("Action Blocked")
                .font(.headline)

            Text(reason)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Divider()

            Button("OK") {
                onDismiss()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(24)
    }
}

// MARK: - Confirmation View

struct ConfirmationView: View {
    @ObservedObject var state: KillConfirmationState
    let process: Process
    let level: ProcessSafetyLevel
    let message: String
    let onConfirm: (Process, Bool) async -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            // Icon based on severity
            warningIcon

            Text(state.forceQuit ? "Force Quit Process?" : "Quit Process?")
                .font(.headline)

            // Process info
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(process.name)
                        .font(.system(.body, design: .monospaced))
                        .fontWeight(.medium)
                    Text("PID: \(process.id) • \(process.user)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                SafetyLevelBadge(level: level)
            }
            .padding()
            .background(Color.primary.opacity(0.05))
            .cornerRadius(8)

            // Warning message
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            // Text confirmation for system processes
            if state.requiresTextConfirmation {
                VStack(spacing: 8) {
                    Text("Type \"kill\" to confirm:")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextField("", text: $state.confirmationText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 8)
            }

            Divider()

            // Buttons
            HStack(spacing: 12) {
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                if state.forceQuit {
                    Button("Force Quit") {
                        performKill()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(!canProceed)
                } else {
                    Button("Quit") {
                        performKill()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canProceed)
                    .keyboardShortcut(.defaultAction)
                }
            }

            if state.isExecuting {
                ProgressView()
                    .scaleEffect(0.8)
            }
        }
        .padding(24)
        .disabled(state.isExecuting)
    }

    private var warningIcon: some View {
        Group {
            switch level {
            case .critical:
                Image(systemName: "xmark.octagon.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.red)
            case .system:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.red)
            case .important:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.orange)
            case .normal:
                Image(systemName: "questionmark.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.blue)
            case .background:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.green)
            }
        }
    }

    private var canProceed: Bool {
        if state.requiresTextConfirmation {
            return state.textConfirmationValid
        }
        return true
    }

    private func performKill() {
        state.isExecuting = true
        Task {
            await onConfirm(process, state.forceQuit)
        }
    }
}

// MARK: - Access Denied View

struct AccessDeniedView: View {
    let processName: String
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.fill")
                .font(.system(size: 48))
                .foregroundStyle(.orange)

            Text("Access Denied")
                .font(.headline)

            Text("You don't have permission to quit '\(processName)'.\n\nThis process may be owned by another user or require administrator privileges.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Divider()

            Button("OK") {
                onDismiss()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(24)
    }
}

// MARK: - Process Not Found View

struct ProcessNotFoundView: View {
    let processName: String
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "questionmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("Process Not Found")
                .font(.headline)

            Text("'\(processName)' is no longer running.\n\nIt may have already quit or been terminated by another process.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Divider()

            Button("OK") {
                onDismiss()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(24)
    }
}

// MARK: - Failed View

struct FailedView: View {
    let processName: String
    let error: String
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.red)

            Text("Failed to Quit Process")
                .font(.headline)

            Text("Could not quit '\(processName)'.\n\nError: \(error)")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Divider()

            Button("OK") {
                onDismiss()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(24)
    }
}

// MARK: - Safety Level Badge

struct SafetyLevelBadge: View {
    let level: ProcessSafetyLevel

    var body: some View {
        Text(level.description)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(backgroundColor.opacity(0.2))
            .foregroundStyle(backgroundColor)
            .cornerRadius(4)
    }

    private var backgroundColor: Color {
        switch level {
        case .critical: return .red
        case .system: return .red
        case .important: return .orange
        case .normal: return .blue
        case .background: return .green
        }
    }
}

#Preview("Confirmation - System") {
    let state = KillConfirmationState()
    state.process = Process(id: 123, name: "WindowServer", user: "root", userId: 0)
    state.killResult = .requiresConfirmation(level: .system, message: "This is a system process.")
    state.forceQuit = false

    return KillConfirmationSheet(state: state, onConfirm: { _, _ in }, onCancel: {})
}

#Preview("Blocked") {
    let state = KillConfirmationState()
    state.process = Process(id: 1, name: "launchd", user: "root", userId: 0)
    state.killResult = .blocked(reason: "This is a critical system process.")

    return KillConfirmationSheet(state: state, onConfirm: { _, _ in }, onCancel: {})
}
