import SwiftUI

struct MenuBarView: View {
    @Bindable var monitor: SystemMonitor
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
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

            HStack(spacing: 8) {
                Button(action: {
                    openWindow(id: "settings")
                    NSApp.activate(ignoringOtherApps: true)
                }) {
                    Label("Settings…", systemImage: "gearshape")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                Button(action: {
                    NSApplication.shared.terminate(nil)
                }) {
                    Label("Quit Antler", systemImage: "power")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 280)
    }
}
