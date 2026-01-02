//
//  BulkCloseConfirmationView.swift
//  limen
//
//  Confirmation dialog for bulk port close operations.
//

import SwiftUI
import Combine

/// State for managing bulk port close confirmation flow
@MainActor
class BulkCloseConfirmationState: ObservableObject {
    @Published var isPresented: Bool = false
    @Published var closablePorts: [Port] = []
    @Published var skippedCritical: [Port] = []
    @Published var skippedSystem: [Port] = []
    @Published var forceQuit: Bool = false
    @Published var isExecuting: Bool = false
    @Published var result: BulkCloseResult?
    @Published var showingResults: Bool = false

    var totalClosable: Int {
        closablePorts.count
    }

    var totalSkipped: Int {
        skippedCritical.count + skippedSystem.count
    }

    func reset() {
        isPresented = false
        closablePorts = []
        skippedCritical = []
        skippedSystem = []
        forceQuit = false
        isExecuting = false
        result = nil
        showingResults = false
    }

    func present(allPorts: [Port]) {
        // Categorize ports by safety level
        closablePorts = allPorts.filter { port in
            let level = port.safetyLevel
            return level != .critical && level != .system
        }
        skippedCritical = allPorts.filter { $0.safetyLevel == .critical }
        skippedSystem = allPorts.filter { $0.safetyLevel == .system }
        forceQuit = false
        isExecuting = false
        result = nil
        showingResults = false
        isPresented = true
    }

    func showResults(_ result: BulkCloseResult) {
        self.result = result
        self.showingResults = true
        self.isExecuting = false
    }
}

/// Bulk close confirmation sheet
struct BulkCloseConfirmationSheet: View {
    @ObservedObject var state: BulkCloseConfirmationState
    let onConfirm: (Bool) async -> BulkCloseResult
    let onCancel: () -> Void

    var body: some View {
        if state.showingResults, let result = state.result {
            BulkCloseResultsView(result: result, onDismiss: onCancel)
        } else {
            BulkClosePreviewView(
                state: state,
                onConfirm: onConfirm,
                onCancel: onCancel
            )
        }
    }
}

// MARK: - Preview View (before execution)

struct BulkClosePreviewView: View {
    @ObservedObject var state: BulkCloseConfirmationState
    let onConfirm: (Bool) async -> BulkCloseResult
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 12) {
                Image(systemName: "door.left.hand.closed")
                    .font(.system(size: 48))
                    .foregroundStyle(.orange)

                Text("Close All Non-Critical Ports?")
                    .font(.headline)

                Text("This will terminate processes using the following ports.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 24)
            .padding(.horizontal, 24)

            // Summary badges
            HStack(spacing: 16) {
                SummaryBadge(
                    count: state.totalClosable,
                    label: "Will Close",
                    color: .green
                )
                SummaryBadge(
                    count: state.totalSkipped,
                    label: "Protected",
                    color: .orange
                )
            }
            .padding(.vertical, 16)

            Divider()

            // Scrollable port list
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Ports to close
                    if !state.closablePorts.isEmpty {
                        PortGroupSection(
                            title: "Ports to Close",
                            ports: state.closablePorts,
                            icon: "checkmark.circle.fill",
                            iconColor: .green
                        )
                    }

                    // Protected ports
                    if !state.skippedSystem.isEmpty {
                        PortGroupSection(
                            title: "System Ports (Protected)",
                            ports: state.skippedSystem,
                            icon: "exclamationmark.shield.fill",
                            iconColor: .orange
                        )
                    }

                    if !state.skippedCritical.isEmpty {
                        PortGroupSection(
                            title: "Critical Ports (Protected)",
                            ports: state.skippedCritical,
                            icon: "xmark.shield.fill",
                            iconColor: .red
                        )
                    }
                }
                .padding(16)
            }
            .frame(maxHeight: 200)

            Divider()

            // Options and buttons
            VStack(spacing: 16) {
                Toggle(isOn: $state.forceQuit) {
                    HStack {
                        Image(systemName: "bolt.fill")
                            .foregroundStyle(.red)
                        Text("Force quit (SIGKILL)")
                            .font(.callout)
                    }
                }
                .toggleStyle(.checkbox)

                if state.forceQuit {
                    Text("Force quit may cause data loss in affected applications.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                HStack(spacing: 12) {
                    Button("Cancel") {
                        onCancel()
                    }
                    .keyboardShortcut(.cancelAction)

                    Button(state.forceQuit ? "Force Close All" : "Close All") {
                        performBulkClose()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(state.forceQuit ? .red : .accentColor)
                    .disabled(state.totalClosable == 0 || state.isExecuting)
                    .keyboardShortcut(.defaultAction)
                }

                if state.isExecuting {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("Closing ports...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(24)
        }
        .frame(width: 420)
        .disabled(state.isExecuting)
    }

    private func performBulkClose() {
        state.isExecuting = true
        Task {
            let result = await onConfirm(state.forceQuit)
            state.showResults(result)
        }
    }
}

// MARK: - Results View (after execution)

struct BulkCloseResultsView: View {
    let result: BulkCloseResult
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header with success/partial indicator
            VStack(spacing: 12) {
                if result.failed == 0 && result.succeeded > 0 {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.green)
                    Text("Ports Closed Successfully")
                        .font(.headline)
                } else if result.succeeded == 0 && result.failed > 0 {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.red)
                    Text("Failed to Close Ports")
                        .font(.headline)
                } else {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.orange)
                    Text("Partially Completed")
                        .font(.headline)
                }
            }
            .padding(.top, 24)
            .padding(.horizontal, 24)

            // Result summary badges
            HStack(spacing: 12) {
                ResultBadge(count: result.succeeded, label: "Closed", color: .green)
                ResultBadge(count: result.failed, label: "Failed", color: .red)
                ResultBadge(count: result.skippedCritical + result.skippedSystem, label: "Protected", color: .orange)
            }
            .padding(.vertical, 16)

            Divider()

            // Detailed results
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // Successful closes
                    let successItems = result.results.filter { $0.succeeded }
                    if !successItems.isEmpty {
                        ResultSection(
                            title: "Closed (\(successItems.count))",
                            items: successItems,
                            icon: "checkmark.circle.fill",
                            iconColor: .green
                        )
                    }

                    // Failed closes
                    let failedItems = result.results.filter {
                        if case .failed = $0.result { return true }
                        if case .accessDenied = $0.result { return true }
                        return false
                    }
                    if !failedItems.isEmpty {
                        ResultSection(
                            title: "Failed (\(failedItems.count))",
                            items: failedItems,
                            icon: "xmark.circle.fill",
                            iconColor: .red
                        )
                    }

                    // Protected (skipped)
                    let protectedItems = result.results.filter {
                        $0.safetyLevel == .critical || $0.safetyLevel == .system
                    }
                    if !protectedItems.isEmpty {
                        ResultSection(
                            title: "Protected (\(protectedItems.count))",
                            items: protectedItems,
                            icon: "shield.fill",
                            iconColor: .orange
                        )
                    }
                }
                .padding(16)
            }
            .frame(maxHeight: 200)

            Divider()

            Button("Done") {
                onDismiss()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .padding(24)
        }
        .frame(width: 420)
    }
}

// MARK: - Helper Views

struct SummaryBadge: View {
    let count: Int
    let label: String
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Text("\(count)")
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(color)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(width: 80)
        .padding(.vertical, 8)
        .background(color.opacity(0.1))
        .cornerRadius(8)
    }
}

struct ResultBadge: View {
    let count: Int
    let label: String
    let color: Color

    var body: some View {
        VStack(spacing: 2) {
            Text("\(count)")
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(color)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .frame(width: 60)
        .padding(.vertical, 6)
        .background(color.opacity(0.1))
        .cornerRadius(6)
    }
}

struct PortGroupSection: View {
    let title: String
    let ports: [Port]
    let icon: String
    let iconColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(iconColor)
                Text(title)
                    .font(.caption)
                    .fontWeight(.medium)
                Text("(\(ports.count))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            FlowLayout(spacing: 6) {
                ForEach(ports.prefix(20), id: \.id) { port in
                    PortChip(port: port)
                }
                if ports.count > 20 {
                    Text("+\(ports.count - 20) more")
                        .font(.system(size: 10))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.2))
                        .cornerRadius(4)
                }
            }
        }
    }
}

struct PortChip: View {
    let port: Port

    var body: some View {
        HStack(spacing: 4) {
            Text("\(port.number)")
                .font(.system(size: 11, design: .monospaced))
                .fontWeight(.medium)

            if let service = port.serviceName {
                Text(service)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.08))
        .cornerRadius(4)
    }
}

struct ResultSection: View {
    let title: String
    let items: [BulkCloseResult.PortCloseResultItem]
    let icon: String
    let iconColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(iconColor)
                Text(title)
                    .font(.caption)
                    .fontWeight(.medium)
            }

            VStack(spacing: 4) {
                ForEach(items.prefix(10), id: \.id) { item in
                    ResultItemRow(item: item)
                }
                if items.count > 10 {
                    Text("... and \(items.count - 10) more")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
            }
        }
    }
}

struct ResultItemRow: View {
    let item: BulkCloseResult.PortCloseResultItem

    var body: some View {
        HStack {
            Text("\(item.port)")
                .font(.system(size: 11, design: .monospaced))
                .fontWeight(.medium)
                .frame(width: 50, alignment: .leading)

            Text(item.protocol.rawValue)
                .font(.system(size: 9))
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(Color.blue.opacity(0.15))
                .foregroundStyle(.blue)
                .cornerRadius(3)

            if let name = item.processName {
                Text(name)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            resultIndicator
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var resultIndicator: some View {
        switch item.result {
        case .success:
            Image(systemName: "checkmark")
                .font(.system(size: 10))
                .foregroundStyle(.green)
        case .failed(let error):
            Text(error)
                .font(.system(size: 9))
                .foregroundStyle(.red)
                .lineLimit(1)
        case .accessDenied:
            Text("Access Denied")
                .font(.system(size: 9))
                .foregroundStyle(.red)
        case .blocked(let reason):
            Text(reason)
                .font(.system(size: 9))
                .foregroundStyle(.orange)
                .lineLimit(1)
        default:
            EmptyView()
        }
    }
}

// MARK: - Flow Layout for chips

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)

        for (index, position) in result.positions.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: .unspecified
            )
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)

            if currentX + size.width > maxWidth && currentX > 0 {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }

            positions.append(CGPoint(x: currentX, y: currentY))
            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            totalHeight = max(totalHeight, currentY + lineHeight)
        }

        return (CGSize(width: maxWidth, height: totalHeight), positions)
    }
}
