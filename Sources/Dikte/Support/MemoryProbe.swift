import Darwin
import Foundation

/// Sürecin fiziksel bellek ayak izi (Etkinlik Monitörü'ndeki "Bellek" sütunu).
enum MemoryProbe {
    static func footprintMB() -> Double {
        Double(info()?.phys_footprint ?? 0) / 1_048_576
    }

    /// Süreç boyunca görülen en yüksek ayak izi
    static func peakFootprintMB() -> Double {
        Double(info()?.ledger_phys_footprint_peak ?? 0) / 1_048_576
    }

    private static func info() -> task_vm_info_data_t? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info : nil
    }
}
