import Darwin
import Foundation

public enum MemoryPressure: Int, Sendable {
    case normal = 1
    case warning = 2
    case critical = 4
}

/// Machine-wide load, sampled on demand. CPU is measured since the previous sample.
public final class SystemMetrics {
    public struct Sample: Sendable {
        public var cpuUsage: Double
        public var memoryPressure: MemoryPressure
        public var memoryUsedBytes: UInt64
        public var memoryTotalBytes: UInt64
    }

    private var lastTicks: (busy: UInt64, total: UInt64)?

    public init() {}

    public func sample() -> Sample {
        let memory = Self.memoryUse()
        return Sample(
            cpuUsage: cpuUsage(),
            memoryPressure: Self.memoryPressure(),
            memoryUsedBytes: memory.used,
            memoryTotalBytes: memory.total
        )
    }

    public static func freeBytes(at path: String) -> Int64 {
        var info = statfs()
        guard statfs(path, &info) == 0 else { return 0 }
        return Int64(info.f_bavail) * Int64(info.f_bsize)
    }

    private func cpuUsage() -> Double {
        var load = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &load) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let user = UInt64(load.cpu_ticks.0)
        let system = UInt64(load.cpu_ticks.1)
        let idle = UInt64(load.cpu_ticks.2)
        let nice = UInt64(load.cpu_ticks.3)
        let busy = user + system + nice
        let total = busy + idle
        defer { lastTicks = (busy, total) }
        guard let last = lastTicks, total > last.total else { return 0 }
        return Double(busy - last.busy) / Double(total - last.total)
    }

    private static func memoryPressure() -> MemoryPressure {
        var level: Int32 = 1
        var size = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0)
        return MemoryPressure(rawValue: Int(level)) ?? .normal
    }

    private static func memoryUse() -> (used: UInt64, total: UInt64) {
        let total = ProcessInfo.processInfo.physicalMemory
        var statistics = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &statistics) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, total) }
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        let pages = UInt64(statistics.active_count) + UInt64(statistics.wire_count) + UInt64(statistics.compressor_page_count)
        return (pages * UInt64(pageSize), total)
    }
}
