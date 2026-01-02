# Limen

A lightweight macOS menubar application for real-time system monitoring. Limen provides visibility into running processes, network connections, and open ports with built-in anomaly detection to help identify unusual system behavior.

## Features

### Process Monitoring
- View all running processes sorted by CPU or memory usage
- See process details including PID, user, CPU%, memory usage, and thread count
- Terminate or force-quit processes with safety checks for critical system processes
- Process tree visualization showing parent-child relationships

### Network Monitoring
- Monitor active network connections (TCP/UDP, IPv4/IPv6)
- View connection states (ESTABLISHED, LISTEN, TIME_WAIT, etc.)
- Track bytes in/out and throughput per second
- List network interfaces with IP addresses and statistics

### Port Management
- List all listening ports with associated processes
- Close ports by terminating the process using them
- Bulk close non-critical ports
- Safety classification prevents closing system-critical ports

### Anomaly Detection
Limen continuously monitors system activity and alerts on:

**Process Anomalies**
- CPU and memory spikes compared to baseline
- Unusual or suspicious processes
- Rapid process spawning
- Zombie processes

**Network Anomalies**
- Traffic spikes above normal baseline
- Connection floods from a single process
- Connections to known suspicious ports

**Port Anomalies**
- Newly opened listening ports
- Non-system processes on privileged ports (< 1024)
- Activity on known backdoor ports

## Architecture

Limen is built with a modular, protocol-driven architecture:

```
┌─────────────────────────────────┐
│     UI Layer (SwiftUI)          │
│     MenuBar + Popover           │
└───────────────┬─────────────────┘
                │
┌───────────────▼─────────────────┐
│     LimenMonitor                │
│     Observable State            │
└───────────────┬─────────────────┘
                │
┌───────────────▼─────────────────┐
│     LimenCore                   │
│     Main Facade                 │
└───────────────┬─────────────────┘
                │
┌───────────────▼─────────────────┐
│     Providers                   │
│  Process │ Network │ Port       │
└───────────────┬─────────────────┘
                │
┌───────────────▼─────────────────┐
│     Anomaly Detection           │
│     Baselines + Analysis        │
└─────────────────────────────────┘
```

## Requirements

- macOS 13.0 or later
- Xcode 15.0 or later

## Building and Running

### Clone the Repository

```bash
git clone https://github.com/yourusername/limen.git
cd limen
```

### Build with Xcode

1. Open the project in Xcode:
   ```bash
   open limen.xcodeproj
   ```

2. Select the `limen` scheme and your Mac as the destination.

3. Build and run with `Cmd + R`.

### Build from Command Line

```bash
xcodebuild -scheme limen -destination 'platform=macOS' build
```

The built application will be in:
```
~/Library/Developer/Xcode/DerivedData/limen-*/Build/Products/Debug/limen.app
```

### Running the App

After building, Limen appears as a network icon in your menubar. Click it to open the monitoring popover.

## Project Structure

```
limen/
├── Core/
│   ├── LimenCore.swift           # Main facade and LimenMonitor
│   ├── ProcessSafety.swift       # Process safety classification
│   ├── PortSafety.swift          # Port safety classification
│   ├── Models/
│   │   └── Anomaly.swift         # Anomaly detection models
│   ├── Protocols/
│   │   ├── ProcessProviding.swift
│   │   ├── NetworkProviding.swift
│   │   ├── PortProviding.swift
│   │   └── AnomalyProviding.swift
│   ├── Providers/
│   │   ├── ProcessProvider.swift  # libproc-based implementation
│   │   ├── NetworkProvider.swift  # lsof/netstat implementation
│   │   └── PortProvider.swift
│   └── Services/
│       └── AnomalyDetectionService.swift
├── Views/
│   ├── PopoverContentView.swift
│   ├── KillConfirmationView.swift
│   ├── PortCloseConfirmationView.swift
│   └── BulkCloseConfirmationView.swift
└── limenApp.swift                # App entry point
```

## Safety Features

Limen includes multiple safety mechanisms to prevent accidental system damage:

- **Critical Process Protection**: Cannot kill kernel_task, launchd, WindowServer, or other essential processes
- **System Process Warnings**: Requires confirmation before terminating system processes
- **Port Safety Levels**: Classifies ports as Critical, System, Important, Normal, or Ephemeral
- **Defense in Depth**: Safety checks at validation, execution, and confirmation stages

## Configuration

Access settings via the menubar icon > Settings, or press `Cmd + ,`:

- **General**: Launch at login
- **Processes**: Refresh interval (1-10 seconds)
- **Network**: Monitor all connections toggle

Anomaly detection thresholds can be configured programmatically through `AnomalyDetectionConfig`.

## License

MIT License
