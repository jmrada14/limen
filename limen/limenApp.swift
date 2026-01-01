//
//  limenApp.swift
//  limen
//
//  A menubar application for process and network monitoring.
//

import SwiftUI

@main
struct LimenApp: App {
    @State private var isDetached = false

    var body: some Scene {
        MenuBarExtra {
            PopoverContentView(isDetached: $isDetached)
                .frame(width: 320, height: 400)
        } label: {
            Image(systemName: "network")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
    }
}

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            ProcessSettingsView()
                .tabItem {
                    Label("Processes", systemImage: "cpu")
                }

            NetworkSettingsView()
                .tabItem {
                    Label("Network", systemImage: "network")
                }
        }
        .frame(width: 450, height: 300)
    }
}

struct GeneralSettingsView: View {
    @AppStorage("launchAtLogin") private var launchAtLogin = false

    var body: some View {
        Form {
            Toggle("Launch at Login", isOn: $launchAtLogin)
        }
        .padding()
    }
}

struct ProcessSettingsView: View {
    @AppStorage("refreshInterval") private var refreshInterval = 2.0

    var body: some View {
        Form {
            Slider(value: $refreshInterval, in: 1...10, step: 1) {
                Text("Refresh Interval: \(Int(refreshInterval))s")
            }
        }
        .padding()
    }
}

struct NetworkSettingsView: View {
    @AppStorage("monitorAllConnections") private var monitorAllConnections = true

    var body: some View {
        Form {
            Toggle("Monitor All Connections", isOn: $monitorAllConnections)
        }
        .padding()
    }
}
