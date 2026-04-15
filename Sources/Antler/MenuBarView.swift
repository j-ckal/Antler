import SwiftUI

struct MenuBarView: View {
    @Bindable var monitor: SystemMonitor

    private let intervals: [(label: String, value: TimeInterval)] = [
        ("1s",  1),
        ("3s",  3),
        ("5s",  5),
        ("10s", 10),
        ("30s", 30),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {

            // CPU
            HStack {
                Label("CPU", systemImage: "cpu")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(monitor.cpuUsageFormatted)
                    .font(.system(.body, design: .monospaced).weight(.semibold))
            }

            HStack {
                Label("CPU Temp", systemImage: "thermometer")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(monitor.cpuTempFormatted)
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                Text("Ping")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 12)
                Text(monitor.pingFormatted)
                    .font(.system(.body, design: .monospaced).weight(.semibold))
            }

            Divider()

            // Memory
            HStack {
                Text("Memory")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(monitor.memoryUsageFormatted)
                    .font(.system(.body, design: .monospaced).weight(.semibold))
            }
            HStack(spacing: 5) {
                Text(monitor.memoryPressureSquare)
                    .font(.caption2)
                Text("Pressure: \(monitor.memoryPressure.label)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Divider()

            // Refresh Interval
            HStack {
                Image(systemName: "arrow.clockwise")
                    .foregroundStyle(.secondary)
                Text("Refresh")
                    .font(.subheadline)
                Spacer()
                Picker("", selection: $monitor.refreshInterval) {
                    ForEach(intervals, id: \.value) { interval in
                        Text(interval.label).tag(interval.value)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
            }

            Divider()

            // Quit
            HStack {
                Spacer()
                Button(action: {
                    NSApplication.shared.terminate(nil)
                }) {
                    Label("Quit Antler", systemImage: "power")
                        .font(.subheadline)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(14)
        .frame(width: 280)
    }
}
