import SwiftUI

struct SettingsView: View {
    @Bindable var monitor: SystemMonitor

    private let options: [TimeInterval] = [1, 2, 3, 5, 10, 20, 30, 60]

    var body: some View {
        Form {
            Section {
                IntervalRow(title: "CPU usage",       systemImage: "cpu",         selection: $monitor.cpuInterval,         options: options)
                IntervalRow(title: "CPU temperature", systemImage: "thermometer", selection: $monitor.temperatureInterval, options: options)
                IntervalRow(title: "Memory",          systemImage: "memorychip",  selection: $monitor.memoryInterval,      options: options)
                IntervalRow(title: "Ping",            systemImage: "network",     selection: $monitor.pingInterval,        options: options)
            } header: {
                Text("Refresh intervals")
            } footer: {
                Text("CPU temperature is the most expensive metric to sample — a longer interval keeps background CPU low. Settings are saved in ~/Library/Preferences.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent {
                    TextField("", text: $monitor.pingHost, prompt: Text(SystemMonitor.defaultPingHost))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 200)
                } label: {
                    Label("Ping destination", systemImage: "network")
                }
            } header: {
                Text("Ping")
            } footer: {
                Text("IP address or hostname. Default is \(SystemMonitor.defaultPingHost).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 400)
        .navigationTitle("Antler Settings")
    }
}

private struct IntervalRow: View {
    let title: String
    let systemImage: String
    @Binding var selection: TimeInterval
    let options: [TimeInterval]

    var body: some View {
        Picker(selection: $selection) {
            ForEach(options, id: \.self) { v in
                Text(format(v)).tag(v)
            }
        } label: {
            Label(title, systemImage: systemImage)
        }
    }

    private func format(_ v: TimeInterval) -> String {
        v < 60 ? "\(Int(v))s" : "\(Int(v / 60))m"
    }
}
