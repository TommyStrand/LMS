import Foundation
import Darwin

/// Lightweight runtime diagnostics: a rolling event log plus periodic CPU and
/// memory sampling. Used by `DiagnosticsView` to help troubleshoot audio issues
/// (dropouts, runaway voice counts, sample-load failures) on-device.
///
/// All published state is mutated on the main thread. `log(_:)` is safe to call
/// from any thread EXCEPT the real-time audio render thread — it allocates and
/// hops to main, neither of which is permissible inside the render callback.
final class Diagnostics: ObservableObject {

    static let shared = Diagnostics()

    struct Entry: Identifiable {
        let id = UUID()
        let time: Date
        let message: String
    }

    @Published private(set) var entries: [Entry] = []
    @Published private(set) var cpuPercent: Double = 0
    @Published private(set) var memoryMB:   Double = 0

    private let maxEntries = 200
    private var timer: DispatchSourceTimer?
    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private init() {
        log("Diagnostics started")
    }

    // MARK: - Logging

    func log(_ message: String) {
        let entry = Entry(time: Date(), message: message)
        DispatchQueue.main.async {
            self.entries.append(entry)
            if self.entries.count > self.maxEntries {
                self.entries.removeFirst(self.entries.count - self.maxEntries)
            }
        }
    }

    func clear() {
        DispatchQueue.main.async { self.entries.removeAll() }
    }

    func timestamp(_ entry: Entry) -> String { dateFormatter.string(from: entry.time) }

    // MARK: - Sampling lifecycle

    /// Begin sampling CPU/memory once per second. Call when the diagnostics panel
    /// becomes visible; `stopSampling()` when it is dismissed so we don't burn a
    /// timer in the background.
    func startSampling() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now(), repeating: 1.0)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let cpu = Diagnostics.currentCPUPercent()
            let mem = Diagnostics.currentMemoryMB()
            DispatchQueue.main.async {
                self.cpuPercent = cpu
                self.memoryMB   = mem
            }
        }
        t.resume()
        timer = t
    }

    func stopSampling() {
        timer?.cancel()
        timer = nil
    }

    // MARK: - mach sampling

    /// Process-wide CPU usage as a percentage (can exceed 100 % on multi-core).
    static func currentCPUPercent() -> Double {
        var threadsList: thread_act_array_t?
        var threadsCount = mach_msg_type_number_t(0)
        guard task_threads(mach_task_self_, &threadsList, &threadsCount) == KERN_SUCCESS,
              let threads = threadsList else { return 0 }
        defer {
            vm_deallocate(mach_task_self_,
                          vm_address_t(UInt(bitPattern: threads)),
                          vm_size_t(Int(threadsCount) * MemoryLayout<thread_t>.stride))
        }

        // THREAD_BASIC_INFO_COUNT is a C macro that doesn't import into Swift;
        // compute the field count explicitly.
        let basicInfoCount = mach_msg_type_number_t(
            MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
        let usageScale = 1000.0   // TH_USAGE_SCALE
        let idleFlag: Int32 = 1   // TH_FLAGS_IDLE

        var total = 0.0
        for i in 0..<Int(threadsCount) {
            var info = thread_basic_info()
            var count = basicInfoCount
            let kr = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    thread_info(threads[i], thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
                }
            }
            if kr == KERN_SUCCESS, (info.flags & idleFlag) == 0 {
                total += Double(info.cpu_usage) / usageScale * 100.0
            }
        }
        return total
    }

    /// Resident memory footprint in megabytes (phys_footprint, what iOS uses for
    /// its memory-limit jetsam decisions).
    static func currentMemoryMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size /
                                           MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / 1024.0 / 1024.0
    }
}
