//
//  PortCloseConfirmationView.swift
//  limen
//
//  Confirmation dialogs for closing ports with appropriate warnings.
//

import SwiftUI
import Combine

/// State for managing port close confirmation flow
@MainActor
class PortCloseConfirmationState: ObservableObject {
    @Published var isPresented: Bool = false
    @Published var port: Port?
    @Published var closeResult: PortCloseResult?
    @Published var forceQuit: Bool = false
    @Published var isExecuting: Bool = false
    @Published var confirmationText: String = ""

    // For system-level ports, require typing confirmation
    var requiresTextConfirmation: Bool {
        guard let port = port else { return false }
        return port.safetyLevel == .system
    }

    var textConfirmationValid: Bool {
        confirmationText.lowercased() == "close"
    }

    func reset() {
        isPresented = false
        port = nil
        closeResult = nil
        forceQuit = false
        isExecuting = false
        confirmationText = ""
    }

    func presentClose(for port: Port, forceQuit: Bool = false) async {
        self.port = port
        self.forceQuit = forceQuit
        self.confirmationText = ""
        self.isExecuting = false

        // Get the close validation result
        let result = PortSafety.validateKill(
            port: port.number,
            processName: port.processName,
            processPid: port.pid,
            processUserId: nil,
            force: forceQuit
        )

        self.closeResult = result

        switch result {
        case .blocked:
            self.isPresented = true
        case .requiresConfirmation:
            self.isPresented = true
        case .success:
            // Ephemeral port - minimal confirmation
            self.isPresented = false
        default:
            self.isPresented = true
        }
    }
}

/// Main port close confirmation sheet
struct PortCloseConfirmationSheet: View {
    @ObservedObject var state: PortCloseConfirmationState
    let onConfirm: (Port, Bool) async -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if let port = state.port, let result = state.closeResult {
                switch result {
                case .blocked(let reason):
                    PortBlockedView(port: port, reason: reason, onDismiss: onCancel)

                case .requiresConfirmation(let level, let message, _):
                    PortConfirmationView(
                        state: state,
                        port: port,
                        level: level,
                        message: message,
                        onConfirm: onConfirm,
                        onCancel: onCancel
                    )

                case .accessDenied:
                    PortAccessDeniedView(port: port, onDismiss: onCancel)

                case .portNotInUse:
                    PortNotInUseView(port: port, onDismiss: onCancel)

                case .failed(let error):
                    PortFailedView(port: port, error: error, onDismiss: onCancel)

                case .success:
                    EmptyView()
                }
            }
        }
        .frame(width: 400)
    }
}

// MARK: - Blocked View

struct PortBlockedView: View {
    let port: Port
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

struct PortConfirmationView: View {
    @ObservedObject var state: PortCloseConfirmationState
    let port: Port
    let level: PortSafetyLevel
    let message: String
    let onConfirm: (Port, Bool) async -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            warningIcon

            Text(state.forceQuit ? "Force Close Port?" : "Close Port?")
                .font(.headline)

            // Port info
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("Port \(port.number)")
                            .font(.system(.body, design: .monospaced))
                            .fontWeight(.medium)

                        Text(port.protocol.rawValue)
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue.opacity(0.2))
                            .foregroundStyle(.blue)
                            .cornerRadius(4)

                        if let service = port.serviceName {
                            Text(service)
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }

                    if let processName = port.processName {
                        Text("Process: \(processName) (PID: \(port.pid ?? 0))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                PortSafetyLevelBadge(level: level)
            }
            .padding()
            .background(Color.primary.opacity(0.05))
            .cornerRadius(8)

            // Warning message
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            // Text confirmation for system ports
            if state.requiresTextConfirmation {
                VStack(spacing: 8) {
                    Text("Type \"close\" to confirm:")
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
                    Button("Force Close") {
                        performClose()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(!canProceed)
                } else {
                    Button("Close Port") {
                        performClose()
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
            case .ephemeral:
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

    private func performClose() {
        state.isExecuting = true
        Task {
            await onConfirm(port, state.forceQuit)
        }
    }
}

// MARK: - Access Denied View

struct PortAccessDeniedView: View {
    let port: Port
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.fill")
                .font(.system(size: 48))
                .foregroundStyle(.orange)

            Text("Access Denied")
                .font(.headline)

            Text("You don't have permission to close port \(port.number).\n\nThe process using this port may be owned by another user or require administrator privileges.")
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

// MARK: - Port Not In Use View

struct PortNotInUseView: View {
    let port: Port
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)

            Text("Port Already Closed")
                .font(.headline)

            Text("Port \(port.number) is no longer in use.\n\nThe process may have already terminated.")
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

struct PortFailedView: View {
    let port: Port
    let error: String
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.red)

            Text("Failed to Close Port")
                .font(.headline)

            Text("Could not close port \(port.number).\n\nError: \(error)")
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

// MARK: - Port Safety Level Badge

struct PortSafetyLevelBadge: View {
    let level: PortSafetyLevel

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
        case .ephemeral: return .green
        }
    }
}
