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

    // Per-metric refresh intervals (seconds). Each has its own Timer, so
    // changing one doesn't reset the others. Temperature defaults slower
    // because it's the most expensive metric to sample (~24 IOHID sensors).
    // `memoryInterval` governs memory used, memory pressure, and swap.
    var cpuInterval:         TimeInterval = SystemMonitor.loadInterval(SystemMonitor.cpuIntervalKey,         default: 5)  { didSet { SystemMonitor.saveInterval(SystemMonitor.cpuIntervalKey, cpuInterval);                 restart(.cpu) } }
    var temperatureInterval: TimeInterval = SystemMonitor.loadInterval(SystemMonitor.temperatureIntervalKey, default: 20) { didSet { SystemMonitor.saveInterval(SystemMonitor.temperatureIntervalKey, temperatureInterval); restart(.temperature) } }
    var memoryInterval:      TimeInterval = SystemMonitor.loadInterval(SystemMonitor.memoryIntervalKey,      default: 5)  { didSet { SystemMonitor.saveInterval(SystemMonitor.memoryIntervalKey, memoryInterval);           restart(.memory); restart(.memoryPressure); restart(.swap) } }
    var pingInterval:        TimeInterval = SystemMonitor.loadInterval(SystemMonitor.pingIntervalKey,        default: 5)  { didSet { SystemMonitor.saveInterval(SystemMonitor.pingIntervalKey, pingInterval);               restart(.ping) } }

    /// Destination for ping. Accepts IPv4 address or hostname.
    var pingHost: String = SystemMonitor.loadPingHost() {
        didSet {
            let trimmed = pingHost.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed != pingHost { pingHost = trimmed; return }
            UserDefaults.standard.set(pingHost, forKey: SystemMonitor.pingHostKey)
            restart(.ping)
        }
    }

    static let defaultPingHost = "1.1.1.1"

    private static let cpuIntervalKey         = "cpuInterval"
    private static let temperatureIntervalKey = "temperatureInterval"
    private static let memoryIntervalKey      = "memoryInterval"
    private static let pingIntervalKey        = "pingInterval"
    private static let pingHostKey            = "pingHost"

    private static func loadPingHost() -> String {
        let stored = UserDefaults.standard.string(forKey: pingHostKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return stored.isEmpty ? defaultPingHost : stored
    }

    private static func loadInterval(_ key: String, default defaultValue: TimeInterval) -> TimeInterval {
        let stored = UserDefaults.standard.double(forKey: key)
        return stored > 0 ? stored : defaultValue
    }

    private static func saveInterval(_ key: String, _ value: TimeInterval) {
        UserDefaults.standard.set(value, forKey: key)
    }

    enum Metric: String, CaseIterable, Identifiable {
        case cpu, temperature, memory, memoryPressure, swap, ping
        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .cpu:             return "CPU usage"
            case .temperature:     return "CPU temperature"
            case .memory:          return "Memory"
            case .memoryPressure:  return "Memory pressure"
            case .swap:            return "Swap"
            case .ping:            return "Ping"
            }
        }

        var systemImage: String {
            switch self {
            case .cpu:             return "cpu"
            case .temperature:     return "thermometer"
            case .memory:          return "memorychip"
            case .memoryPressure:  return "gauge.with.dots.needle.50percent"
            case .swap:            return "externaldrive"
            case .ping:            return "network"
            }
        }
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

    private var timers: [Metric: Timer] = [:]
    private var previousCPUTicks: (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)?
    private var pingTask: Task<Void, Never>?
    private var thermalClient: AnyObject?
    private var thermalServices: [AnyObject] = []

    // MARK: - Lifecycle

    init() {
        memoryTotal = ProcessInfo.processInfo.physicalMemory
        setupThermalClient()
        updateAll()
        for metric in Metric.allCases { restart(metric) }
    }

    /// Maximum thermal sensors to poll. Apple Silicon exposes ~24 per-cluster
    /// `tdie` sensors; each `IOHIDServiceClientCopyEvent` is an IOKit
    /// round-trip (~0.8 ms), so sampling them all costs ~20 ms/tick. Since
    /// the die temps across a single CPU complex are closely correlated and
    /// we only use the max, a strided sample of ~6 gives a near-identical
    /// reading at ~75% less cost.
    private static let maxThermalSensors = 6

    /// One-time setup: create the IOHID client, apply the match dict,
    /// filter the service list down to CPU-temperature sensors, and sample
    /// a strided subset. The client and services are reused for the
    /// lifetime of the app.
    private func setupThermalClient() {
        guard let client = IOHIDEventSystemClientCreate(kCFAllocatorDefault) else { return }

        let matchDict = [
            "PrimaryUsagePage": 0xff00,
            "PrimaryUsage": 0x5
        ] as CFDictionary
        IOHIDEventSystemClientSetMatching(client, matchDict)

        guard let servicesUnmanaged = IOHIDEventSystemClientCopyServices(client) else { return }
        let allServices = servicesUnmanaged.takeRetainedValue() as [AnyObject]

        var cpuServices: [AnyObject] = []
        for service in allServices {
            guard let nameUnmanaged = IOHIDServiceClientCopyProperty(service, "Product" as CFString) else { continue }
            guard let name = nameUnmanaged.takeRetainedValue() as? String else { continue }
            let lower = name.lowercased()
            if lower.contains("tdie") || lower.contains("cpu") {
                cpuServices.append(service)
            }
        }

        let step = max(1, cpuServices.count / Self.maxThermalSensors)
        let sampled = stride(from: 0, to: cpuServices.count, by: step)
            .prefix(Self.maxThermalSensors)
            .map { cpuServices[$0] }

        self.thermalClient = client
        self.thermalServices = Array(sampled)
    }

    deinit {
        for t in timers.values { t.invalidate() }
        pingTask?.cancel()
    }

    // MARK: - Per-metric timers

    private func interval(for metric: Metric) -> TimeInterval {
        switch metric {
        case .cpu:             return cpuInterval
        case .temperature:     return temperatureInterval
        case .memory:          return memoryInterval
        case .memoryPressure:  return memoryInterval
        case .swap:            return memoryInterval
        case .ping:            return pingInterval
        }
    }

    private func update(_ metric: Metric) {
        switch metric {
        case .cpu:             updateCPU()
        case .temperature:     updateTemperature()
        case .memory:          updateMemory()
        case .memoryPressure:  updateMemoryPressure()
        case .swap:            updateSwap()
        case .ping:            updatePing()
        }
    }

    private func restart(_ metric: Metric) {
        timers[metric]?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: interval(for: metric), repeats: true) { [weak self] _ in
            self?.update(metric)
        }
        timers[metric] = timer
    }

    /// Runs every metric once. Called at init so the menu bar isn't blank.
    private func updateAll() {
        for metric in Metric.allCases { update(metric) }
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
        var maxTemp: Double = 0.0
        for service in thermalServices {
            guard let eventUnmanaged = IOHIDServiceClientCopyEvent(service, kIOHIDEventTypeTemperature, 0, 0) else { continue }
            let event = eventUnmanaged.takeRetainedValue()
            let temp = IOHIDEventGetFloatValue(event, IOHIDEventFieldBase(kIOHIDEventTypeTemperature))
            if temp > maxTemp { maxTemp = temp }
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
        let host = pingHost
        pingTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let latency = Self.measurePingLatency(host: host)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.pingLatency = latency
            }
        }
    }

    /// Sends a single ICMP echo request to `host` (IPv4 address or hostname)
    /// over a SOCK_DGRAM ICMP socket (no root required on macOS) and returns
    /// the round-trip time in milliseconds. Times out after 1s.
    private static func measurePingLatency(host: String) -> Double? {
        guard let resolved = resolveIPv4(host: host) else { return nil }

        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        let tvSize = socklen_t(MemoryLayout<timeval>.size)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, tvSize)
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, tvSize)

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = resolved

        let identifier = UInt16(truncatingIfNeeded: getpid())
        let sequence: UInt16 = 1

        // 8-byte ICMP header + 56-byte payload (matches default ping packet size).
        var packet = [UInt8](repeating: 0, count: 64)
        packet[0] = 8  // type: echo request
        packet[1] = 0  // code
        packet[4] = UInt8(identifier >> 8)
        packet[5] = UInt8(identifier & 0xff)
        packet[6] = UInt8(sequence   >> 8)
        packet[7] = UInt8(sequence   & 0xff)

        let checksum = internetChecksum(packet)
        packet[2] = UInt8(checksum >> 8)
        packet[3] = UInt8(checksum & 0xff)

        let start = CFAbsoluteTimeGetCurrent()

        let sent: ssize_t = packet.withUnsafeBufferPointer { buf in
            withUnsafePointer(to: &addr) { addrPtr in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                    sendto(fd, buf.baseAddress, buf.count, 0, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent == packet.count else { return nil }

        var recvBuf = [UInt8](repeating: 0, count: 1500)
        let received: ssize_t = recvBuf.withUnsafeMutableBufferPointer { buf in
            recvfrom(fd, buf.baseAddress, buf.count, 0, nil, nil)
        }
        guard received > 0 else { return nil }

        return (CFAbsoluteTimeGetCurrent() - start) * 1000
    }

    /// 16-bit Internet checksum (RFC 1071) over an even- or odd-length buffer.
    private static func internetChecksum(_ data: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var i = 0
        while i + 1 < data.count {
            sum &+= UInt32(data[i]) << 8 | UInt32(data[i + 1])
            i += 2
        }
        if i < data.count {
            sum &+= UInt32(data[i]) << 8
        }
        while sum >> 16 != 0 {
            sum = (sum & 0xffff) + (sum >> 16)
        }
        return ~UInt16(sum & 0xffff)
    }

    /// Resolves `host` to an IPv4 address in network byte order. Accepts a
    /// dotted-quad literal or a hostname (DNS lookup via getaddrinfo).
    private static func resolveIPv4(host: String) -> in_addr_t? {
        let literal = inet_addr(host)
        if literal != INADDR_NONE { return literal }

        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_DGRAM

        var result: UnsafeMutablePointer<addrinfo>?
        defer { if let r = result { freeaddrinfo(r) } }
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return nil }

        return first.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
            $0.pointee.sin_addr.s_addr
        }
    }

    // MARK: - Formatting Helpers

    var cpuUsageFormatted: String {
        String(format: "%.0f%%", cpuUsage)
    }

    private static let bytesPerGB: Double = 1_073_741_824

    var memoryUsageFormatted: String {
        let usedGB = Double(memoryUsed) / Self.bytesPerGB
        let totalGB = Double(memoryTotal) / Self.bytesPerGB
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
        let gb = Double(swapUsed) / Self.bytesPerGB
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
