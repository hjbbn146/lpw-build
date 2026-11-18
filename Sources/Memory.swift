import Foundation
import Darwin

/// 运行时资源观测：内存脚印 / 可用磁盘。
///
/// 直通大视频时，最容易出现的不是业务崩溃，而是**内存一路涨到被系统
/// 以 Jetsam 直接杀掉**（表现：无崩溃报告、转几圈就退回桌面）。
/// 所以循环里必须能读到实时数值并落盘，出问题时才有证据。
enum Mem {

    /// 当前进程物理脚印（MB）；失败返回 -1
    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { p -> kern_return_t in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { ip in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), ip, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return -1 }
        return Double(info.phys_footprint) / 1_048_576.0
    }

    /// 设备物理内存（MB）
    static var deviceMB: Double {
        Double(ProcessInfo.processInfo.physicalMemory) / 1_048_576.0
    }

    /// 可用磁盘（MB，iOS 给的"重要用途可用容量"）
    static func freeDiskMB() -> Double {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        if let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let b = v.volumeAvailableCapacityForImportantUsage {
            return Double(b) / 1_048_576.0
        }
        return -1
    }

    static func summary() -> String {
        String(format: "内存 %.0fMB / 设备 %.0fMB · 磁盘剩 %.0fMB",
               footprintMB(), deviceMB, freeDiskMB())
    }
}
