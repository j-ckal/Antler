import Foundation
import Darwin

/// Collects CPU usage, CPU temperature, and memory stats using only native macOS APIs.
@Observable
final class SystemMonitor {

    // MARK: - Published State

    var cpuUsage: Double = 0.0          // 0.0–100.0
    var cpuTemperature: Double = 0.0    // Celsius
    var pingLatency: Double?            // milliseconds
    var memoryUsed: UInt64 = 0          // bytes
    var memoryTotal: UInt64 = 0         // bytes
    var swapUsed: UInt64 = 0            // bytes
    var memoryPressure: MemoryPressureLevel = .nominal
    var refreshInterval: TimeInterval = 3.0 {
        didSet { restartTimer() }
    }

    enum MemoryPressureLevel: Int {
        case nominal  = 1
        case warning  = 2
        case critical = 4

        init(sysctlValue: Int32) {
            switch sysctlValue {
            case 4:  self = .critical
            case 2:  self = .warning
            default: self = .nominal
            }
        }

        var label: String {
            switch self {
            case .nominal:  return "Low"
            case .warning:  return "Medium"
            case .critical: return "High"
            }
        }
    }

    // MARK: - Private State

    private var timer: Timer?
    private var previousCPUTicks: (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)?
    private var pingTask: Task<Void, Never>?

    // MARK: - Lifecycle

    init() {
        memoryTotal = ProcessInfo.processInfo.physicalMemory
        updateAll()
        startTimer()
    }

    deinit {
        timer?.invalidate()
        pingTask?.cancel()
    }

    // MARK: - Timer (only memory pressure + thermal, NOT cpu)

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.updateAll()
        }
    }

    private func restartTimer() {
        timer?.invalidate()
        startTimer()
    }

    /// Updates all stats.
    private func updateAll() {
        updateCPU()
        updateTemperature()
        updateMemoryPressure()
        updateMemory()
        updateSwap()
        updatePing()
    }

    // MARK: - CPU Usage (Mach host_processor_info) — on-demand only

    private func updateCPU() {
        var numCPUs: natural_t = 0
        var cpuInfo: processor_info_array_t?
        var numCPUInfo: mach_msg_type_number_t = 0

        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &numCPUs,
            &cpuInfo,
            &numCPUInfo
        )

        guard result == KERN_SUCCESS, let cpuInfo = cpuInfo else { return }

        var totalUser: UInt64 = 0
        var totalSystem: UInt64 = 0
        var totalIdle: UInt64 = 0
        var totalNice: UInt64 = 0

        for i in 0..<Int(numCPUs) {
            let offset = Int(CPU_STATE_MAX) * i
            totalUser   += UInt64(cpuInfo[offset + Int(CPU_STATE_USER)])
            totalSystem += UInt64(cpuInfo[offset + Int(CPU_STATE_SYSTEM)])
            totalIdle   += UInt64(cpuInfo[offset + Int(CPU_STATE_IDLE)])
            totalNice   += UInt64(cpuInfo[offset + Int(CPU_STATE_NICE)])
        }

        let cpuInfoSize = vm_size_t(numCPUInfo) * vm_size_t(MemoryLayout<integer_t>.stride)
        vm_deallocate(mach_task_self_, vm_address_t(bitPattern: cpuInfo), cpuInfoSize)

        if let prev = previousCPUTicks {
            let deltaUser   = totalUser   - prev.user
            let deltaSystem = totalSystem - prev.system
            let deltaIdle   = totalIdle   - prev.idle
            let deltaNice   = totalNice   - prev.nice
            let totalDelta  = deltaUser + deltaSystem + deltaIdle + deltaNice

            if totalDelta > 0 {
                cpuUsage = Double(deltaUser + deltaSystem + deltaNice) / Double(totalDelta) * 100.0
            }
        }

        previousCPUTicks = (user: totalUser, system: totalSystem, idle: totalIdle, nice: totalNice)
    }

    // MARK: - CPU Temperature

    private func updateTemperature() {
        guard let client = IOHIDEventSystemClientCreate(kCFAllocatorDefault) else { return }
        
        let matchDict = [
            "PrimaryUsagePage": 0xff00,
            "PrimaryUsage": 0x5
        ] as CFDictionary
        
        IOHIDEventSystemClientSetMatching(client, matchDict)
        
        guard let servicesUnmanaged = IOHIDEventSystemClientCopyServices(client) else { return }
        let services = servicesUnmanaged.takeRetainedValue() as [AnyObject]
        
        var maxTemp: Double = 0.0
        
        for service in services {
            guard let nameUnmanaged = IOHIDServiceClientCopyProperty(service, "Product" as CFString) else { continue }
            guard let name = nameUnmanaged.takeRetainedValue() as? String else { continue }
            
            if name.lowercased().contains("tdie") || name.lowercased().contains("cpu") {
                if let eventUnmanaged = IOHIDServiceClientCopyEvent(service, kIOHIDEventTypeTemperature, 0, 0) {
                    let event = eventUnmanaged.takeRetainedValue()
                    let temp = IOHIDEventGetFloatValue(event, IOHIDEventFieldBase(kIOHIDEventTypeTemperature))
                    if temp > maxTemp {
                        maxTemp = temp
                    }
                }
            }
        }
        
        if maxTemp > 0 {
            self.cpuTemperature = maxTemp
        }
    }

    // MARK: - Memory Usage (host_statistics64)

    private func updateMemory() {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)

        let result = withUnsafeMutablePointer(to: &stats) { statsPtr in
            statsPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(
                    mach_host_self(),
                    HOST_VM_INFO64,
                    intPtr,
                    &count
                )
            }
        }

        guard result == KERN_SUCCESS else { return }

        let pageSize = UInt64(vm_kernel_page_size)
        let active     = UInt64(stats.active_count) * pageSize
        let wired      = UInt64(stats.wire_count) * pageSize
        let compressed = UInt64(stats.compressor_page_count) * pageSize

        self.memoryUsed = active + wired + compressed
    }

    // MARK: - Swap Usage (sysctl vm.swapusage)

    private func updateSwap() {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        let result = sysctlbyname("vm.swapusage", &usage, &size, nil, 0)
        if result == 0 {
            self.swapUsed = usage.xsu_used
        }
    }

    // MARK: - Memory Pressure (sysctl — matches Activity Monitor)

    private func updateMemoryPressure() {
        var pressureLevel: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let result = sysctlbyname("kern.memorystatus_vm_pressure_level", &pressureLevel, &size, nil, 0)

        if result == 0 {
            self.memoryPressure = MemoryPressureLevel(sysctlValue: pressureLevel)
        }
    }

    // MARK: - Ping

    private func updatePing() {
        pingTask?.cancel()
        pingTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let latency = Self.measurePingLatency()
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.pingLatency = latency
            }
        }
    }

    private static func measurePingLatency() -> Double? {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/sbin/ping")
        process.arguments = ["-c", "1", "-W", "1000", "1.1.1.1"]
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outputData, encoding: .utf8) ?? ""
        let errorOutput = String(data: errorData, encoding: .utf8) ?? ""
        let combinedOutput = output + "\n" + errorOutput

        guard process.terminationStatus == 0 else { return nil }

        let pattern = #"time=([0-9]+(?:\.[0-9]+)?) ms"#
        guard
            let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(
                in: combinedOutput,
                range: NSRange(combinedOutput.startIndex..., in: combinedOutput)
            ),
            let range = Range(match.range(at: 1), in: combinedOutput)
        else {
            return nil
        }

        return Double(combinedOutput[range])
    }

    // MARK: - Formatting Helpers

    var cpuUsageFormatted: String {
        String(format: "%.0f%%", cpuUsage)
    }

    var memoryUsageFormatted: String {
        let usedGB = Double(memoryUsed) / 1_073_741_824
        let totalGB = Double(memoryTotal) / 1_073_741_824
        return String(format: "%.1f / %.0f GB", usedGB, totalGB)
    }

    var memoryPressureSquare: String {
        switch memoryPressure {
        case .nominal:  return "🟩"
        case .warning:  return "🟨"
        case .critical: return "🟥"
        }
    }

    var swapUsageFormatted: String {
        let gb = Double(swapUsed) / 1_073_741_824
        if gb < 0.05 { return "0GB" }
        let formatted = String(format: "%.1fGB", gb)
        return formatted.replacingOccurrences(of: ".0GB", with: "GB")
    }

    var cpuTempFormatted: String {
        return cpuTemperature > 0 ? String(format: "%.0f°C", cpuTemperature) : "--°C"
    }

    var pingFormatted: String {
        guard let pingLatency else { return "--ms" }
        return String(format: "%.0fms", pingLatency)
    }

    var menuBarTopRow: String {
        "\(cpuUsageFormatted) \(swapUsageFormatted)"
    }

    var menuBarBottomRow: String {
        "\(cpuTempFormatted) \(pingFormatted)"
    }
}

// MARK: - IOHID Private APIs

private let kIOHIDEventTypeTemperature: Int = 15

private func IOHIDEventFieldBase(_ type: Int) -> Int {
    return type << 16
}

@_silgen_name("IOHIDEventSystemClientCreate")
private func IOHIDEventSystemClientCreate(_ allocator: CFAllocator?) -> AnyObject?

@_silgen_name("IOHIDEventSystemClientSetMatching")
private func IOHIDEventSystemClientSetMatching(_ client: AnyObject, _ matches: CFDictionary)

@_silgen_name("IOHIDEventSystemClientCopyServices")
private func IOHIDEventSystemClientCopyServices(_ client: AnyObject) -> Unmanaged<CFArray>?

@_silgen_name("IOHIDServiceClientCopyProperty")
private func IOHIDServiceClientCopyProperty(_ service: AnyObject, _ key: CFString) -> Unmanaged<CFTypeRef>?

@_silgen_name("IOHIDServiceClientCopyEvent")
private func IOHIDServiceClientCopyEvent(_ service: AnyObject, _ type: Int, _ options: Int32, _ unknown: Int64) -> Unmanaged<AnyObject>?

@_silgen_name("IOHIDEventGetFloatValue")
private func IOHIDEventGetFloatValue(_ event: AnyObject, _ field: Int) -> Double
