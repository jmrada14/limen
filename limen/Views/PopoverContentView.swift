//
//  PopoverContentView.swift
//  limen
//
//  Main content view displayed in the menubar popover.
//

import SwiftUI

struct PopoverContentView: View {
    @Binding var isDetached: Bool
    @StateObject private var monitor = LimenMonitor()
    @State private var selectedTab: Tab = .processes

    enum Tab: String, CaseIterable {
        case processes = "Processes"
        case network = "Network"
        case ports = "Ports"
        case settings = "Settings"

        var icon: String {
            switch self {
            case .processes: return "cpu"
            case .network: return "network"
            case .ports: return "door.left.hand.open"
            case .settings: return "gear"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            tabContent
            Divider()
            footer
        }
        .frame(minWidth: 300, minHeight: 350)
        .onAppear {
            monitor.startMonitoring(interval: 2.0)
        }
        .onDisappear {
            monitor.stopMonitoring()
        }
    }

    private var header: some View {
        HStack {
            Text("Limen")
                .font(.headline)
                .fontWeight(.semibold)

            Spacer()

            if let stats = monitor.networkStats {
                HStack(spacing: 8) {
                    Label(LimenCore.formatBytesPerSecond(stats.bytesInPerSecond), systemImage: "arrow.down")
                    Label(LimenCore.formatBytesPerSecond(stats.bytesOutPerSecond), systemImage: "arrow.up")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var tabContent: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedTab) {
                ForEach(Tab.allCases, id: \.self) { tab in
                    Label(tab.rawValue, systemImage: tab.icon)
                        .tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            switch selectedTab {
            case .processes:
                ProcessesView(processes: monitor.processes, monitor: monitor)
            case .network:
                NetworkView(connections: monitor.connections, stats: monitor.networkStats)
            case .ports:
                PortsView(ports: monitor.ports)
            case .settings:
                SettingsTabView()
            }
        }
    }

    private var footer: some View {
        HStack {
            Circle()
                .fill(monitor.isMonitoring ? .green : .red)
                .frame(width: 8, height: 8)

            if let lastUpdated = monitor.lastUpdated {
                Text("Updated \(lastUpdated.formatted(.relative(presentation: .numeric)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(monitor.isMonitoring ? "Monitoring..." : "Stopped")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - Processes View

struct ProcessesView: View {
    let processes: [Process]
    let monitor: LimenMonitor
    @State private var searchText = ""
    @State private var sortOrder: SortOrder = .cpu
    @StateObject private var killState = KillConfirmationState()
    @State private var showingResult: Bool = false
    @State private var resultMessage: String = ""
    @State private var resultIsError: Bool = false

    enum SortOrder: String, CaseIterable {
        case cpu = "CPU"
        case memory = "Memory"
        case name = "Name"
    }

    private var filteredProcesses: [Process] {
        var result = processes

        if !searchText.isEmpty {
            result = result.filter {
                $0.name.localizedCaseInsensitiveContains(searchText)
            }
        }

        switch sortOrder {
        case .cpu:
            result.sort { $0.cpuUsage > $1.cpuUsage }
        case .memory:
            result.sort { $0.memoryBytes > $1.memoryBytes }
        case .name:
            result.sort { $0.name.lowercased() < $1.name.lowercased() }
        }

        return Array(result.prefix(50))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search processes...", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)

                Picker("Sort", selection: $sortOrder) {
                    ForEach(SortOrder.allCases, id: \.self) { order in
                        Text(order.rawValue).tag(order)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            if processes.isEmpty {
                ContentUnavailableView("Loading...", systemImage: "cpu")
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(filteredProcesses, id: \.id) { process in
                            ProcessRow(
                                process: process,
                                onQuit: { requestKill(process: process, force: false) },
                                onForceQuit: { requestKill(process: process, force: true) }
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
            }
        }
        .sheet(isPresented: $killState.isPresented) {
            KillConfirmationSheet(
                state: killState,
                onConfirm: executeKill,
                onCancel: { killState.reset() }
            )
        }
        .alert(resultIsError ? "Error" : "Success", isPresented: $showingResult) {
            Button("OK") { showingResult = false }
        } message: {
            Text(resultMessage)
        }
    }

    private func requestKill(process: Process, force: Bool) {
        Task {
            await killState.presentKill(for: process, forceQuit: force)

            // If it's a background process (no confirmation needed), execute immediately
            if case .success = killState.killResult {
                await executeKill(process, force)
            }
        }
    }

    private func executeKill(_ process: Process, _ forceQuit: Bool) async {
        let result = await monitor.executeKill(pid: process.id, forceQuit: forceQuit)

        killState.reset()

        switch result {
        case .success:
            resultMessage = "'\(process.name)' has been terminated."
            resultIsError = false
            showingResult = true
        case .accessDenied:
            resultMessage = "Access denied. You may need administrator privileges."
            resultIsError = true
            showingResult = true
        case .processNotFound:
            resultMessage = "Process no longer exists."
            resultIsError = false
            showingResult = true
        case .failed(let error):
            resultMessage = "Failed: \(error)"
            resultIsError = true
            showingResult = true
        case .blocked(let reason):
            resultMessage = reason
            resultIsError = true
            showingResult = true
        case .requiresConfirmation:
            // Shouldn't happen here
            break
        }
    }
}

struct ProcessRow: View {
    let process: Process
    let onQuit: () -> Void
    let onForceQuit: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack {
            // Safety indicator
            Circle()
                .fill(safetyColor)
                .frame(width: 6, height: 6)
                .help(process.safetyLevel.description)

            VStack(alignment: .leading, spacing: 2) {
                Text(process.name)
                    .font(.system(.caption, design: .monospaced))
                    .fontWeight(.medium)
                    .lineLimit(1)

                Text("PID: \(process.id) • \(process.user)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isHovering && process.canBeKilled {
                HStack(spacing: 4) {
                    Button {
                        onQuit()
                    } label: {
                        Image(systemName: "xmark.circle")
                            .font(.system(size: 14))
                    }
                    .buttonStyle(.borderless)
                    .help("Quit")

                    Button {
                        onForceQuit()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.borderless)
                    .help("Force Quit")
                }
            } else {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(LimenCore.formatBytes(process.memoryBytes))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)

                    Text(LimenCore.formatPercent(process.memoryPercent))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.blue)
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(isHovering ? Color.primary.opacity(0.08) : Color.primary.opacity(0.03))
        .cornerRadius(6)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .contextMenu {
            if process.canBeKilled {
                Button("Quit") {
                    onQuit()
                }
                Button("Force Quit") {
                    onForceQuit()
                }
                Divider()
            }
            Button("Copy PID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("\(process.id)", forType: .string)
            }
            Button("Copy Name") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(process.name, forType: .string)
            }
            if process.safetyLevel == .critical {
                Divider()
                Text("Critical system process - cannot be terminated")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var safetyColor: Color {
        switch process.safetyLevel {
        case .critical: return .red
        case .system: return .orange
        case .important: return .yellow
        case .normal: return .green
        case .background: return .gray
        }
    }
}

// MARK: - Network View

struct NetworkView: View {
    let connections: [NetworkConnection]
    let stats: NetworkStats?
    @State private var filterState: NetworkConnection.ConnectionState? = nil

    private var filteredConnections: [NetworkConnection] {
        guard let state = filterState else { return connections }
        return connections.filter { $0.state == state }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let stats = stats {
                HStack(spacing: 16) {
                    StatBadge(label: "Connections", value: "\(stats.activeConnections)")
                    StatBadge(label: "In", value: LimenCore.formatBytes(stats.totalBytesIn))
                    StatBadge(label: "Out", value: LimenCore.formatBytes(stats.totalBytesOut))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }

            HStack {
                Text("Filter:")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("State", selection: $filterState) {
                    Text("All").tag(nil as NetworkConnection.ConnectionState?)
                    Text("Established").tag(NetworkConnection.ConnectionState.established as NetworkConnection.ConnectionState?)
                    Text("Listen").tag(NetworkConnection.ConnectionState.listen as NetworkConnection.ConnectionState?)
                }
                .pickerStyle(.menu)
                .fixedSize()

                Spacer()
            }
            .padding(.horizontal, 16)

            if connections.isEmpty {
                ContentUnavailableView("Loading...", systemImage: "network")
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(filteredConnections.prefix(50), id: \.id) { connection in
                            ConnectionRow(connection: connection)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
            }
        }
    }
}

struct ConnectionRow: View {
    let connection: NetworkConnection

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(connection.processName ?? "Unknown")
                    .font(.system(.caption, design: .monospaced))
                    .fontWeight(.medium)

                Spacer()

                Text(connection.state.rawValue)
                    .font(.system(size: 9))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(stateColor.opacity(0.2))
                    .foregroundStyle(stateColor)
                    .cornerRadius(4)
            }

            HStack {
                Text("\(connection.localEndpoint)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)

                if !connection.remoteAddress.isEmpty && connection.remoteAddress != "*" {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)

                    Text("\(connection.remoteEndpoint)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(connection.protocol.rawValue)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(Color.primary.opacity(0.03))
        .cornerRadius(6)
    }

    private var stateColor: Color {
        switch connection.state {
        case .established: return .green
        case .listen: return .blue
        case .timeWait, .closeWait: return .orange
        case .closed: return .red
        default: return .secondary
        }
    }
}

// MARK: - Ports View

struct PortsView: View {
    let ports: [Port]
    @State private var showOnlyListening = true

    private var filteredPorts: [Port] {
        if showOnlyListening {
            return ports.filter { $0.state == .listening }
        }
        return ports
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Toggle("Listening only", isOn: $showOnlyListening)
                    .font(.caption)
                    .toggleStyle(.checkbox)

                Spacer()

                Text("\(filteredPorts.count) ports")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            if ports.isEmpty {
                ContentUnavailableView("Loading...", systemImage: "door.left.hand.open")
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(filteredPorts, id: \.id) { port in
                            PortRow(port: port)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
            }
        }
    }
}

struct PortRow: View {
    let port: Port

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("\(port.number)")
                        .font(.system(.caption, design: .monospaced))
                        .fontWeight(.semibold)

                    Text(port.protocol.rawValue)
                        .font(.system(size: 9, design: .monospaced))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.blue.opacity(0.15))
                        .foregroundStyle(.blue)
                        .cornerRadius(3)

                    if let service = port.serviceName {
                        Text(service)
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                    }
                }

                if let processName = port.processName {
                    Text("\(processName) (PID: \(port.pid ?? 0))")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if port.connectionCount > 1 {
                Text("\(port.connectionCount) conn")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(Color.primary.opacity(0.03))
        .cornerRadius(6)
    }
}

// MARK: - Settings Tab View

struct SettingsTabView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "gear")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)

            Text("Settings")
                .font(.headline)

            Text("Use ⌘, to open settings window")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Open Settings") {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

// MARK: - Helper Views

struct StatBadge: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .fontWeight(.medium)
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.05))
        .cornerRadius(6)
    }
}

#Preview {
    PopoverContentView(isDetached: .constant(false))
        .frame(width: 360, height: 450)
}
