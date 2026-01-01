//
//  PopoverContentView.swift
//  limen
//
//  Main content view displayed in the menubar popover.
//

import SwiftUI

struct PopoverContentView: View {
    @Binding var isDetached: Bool
    @State private var selectedTab: Tab = .processes

    enum Tab: String, CaseIterable {
        case processes = "Processes"
        case network = "Network"
        case settings = "Settings"

        var icon: String {
            switch self {
            case .processes: return "cpu"
            case .network: return "network"
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
    }

    private var header: some View {
        HStack {
            Text("Limen")
                .font(.headline)
                .fontWeight(.semibold)

            Spacer()
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

            ScrollView {
                switch selectedTab {
                case .processes:
                    ProcessesPlaceholderView()
                case .network:
                    NetworkPlaceholderView()
                case .settings:
                    SettingsPlaceholderView()
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Circle()
                .fill(.green)
                .frame(width: 8, height: 8)

            Text("Monitoring active")
                .font(.caption)
                .foregroundStyle(.secondary)

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

struct ProcessesPlaceholderView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "cpu")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)

            Text("Process Monitor")
                .font(.headline)

            Text("Process information will be displayed here.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

struct NetworkPlaceholderView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "network")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)

            Text("Network Monitor")
                .font(.headline)

            Text("Network connections will be displayed here.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

struct SettingsPlaceholderView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "gear")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)

            Text("Settings")
                .font(.headline)

            Text("Configuration options will be available here.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

#Preview {
    PopoverContentView(isDetached: .constant(false))
        .frame(width: 320, height: 400)
}
