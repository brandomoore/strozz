import Darwin
import Foundation

struct PlaybackResourceSample: Sendable {
  let observedAt: Double
  var cpuSeconds: Double?
  var snapshot = PlaybackTelemetrySnapshot()

  func since(_ previous: Self?) -> PlaybackTelemetrySnapshot {
    var result = snapshot
    result.metrics["resource_sample_uptime_seconds"] = observedAt
    if let previous, let cpuSeconds, let priorCPU = previous.cpuSeconds,
      observedAt > previous.observedAt, cpuSeconds >= priorCPU {
      let interval = observedAt - previous.observedAt
      result.metrics["process_cpu_interval_seconds"] = interval
      result.metrics["process_cpu_core_equivalents"] = (cpuSeconds - priorCPU) / interval
    }
    return result
  }
}

#if DEBUG
/// Confined to the scheduler probe's background queue; no AVFoundation or main-actor reads.
struct PlaybackResourceSampler {
  private let directory: URL
  private var disk = PlaybackTelemetrySnapshot()
  private var nextDiskRead = -Double.infinity

  init(directory: URL = .cachesDirectory) {
    self.directory = directory
  }
  #endif

  mutating func sample(at now: Double = ProcessInfo.processInfo.systemUptime) -> PlaybackResourceSample {
    let started = ProcessInfo.processInfo.systemUptime
    var result = PlaybackResourceSample(observedAt: now)
    var usage = rusage()
    if getrusage(RUSAGE_SELF, &usage) == 0 {
      result.cpuSeconds = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
        + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
    } else {
      result.snapshot.counters["resource_cpu_error_code"] = Int(errno)
    }

    var memory = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let status = withUnsafeMutablePointer(to: &memory) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    if status == KERN_SUCCESS {
      result.snapshot.metrics["process_resident_bytes"] = Double(memory.resident_size)
      result.snapshot.metrics["process_footprint_bytes"] = Double(memory.phys_footprint)
    } else {
      result.snapshot.counters["resource_memory_error_code"] = Int(status)
    }

    if now >= nextDiskRead {
      nextDiskRead = now + 15
      disk = PlaybackTelemetrySnapshot(metrics: ["disk_sample_uptime_seconds": now])
      do {
        let values = try FileManager.default.attributesOfFileSystem(forPath: directory.path)
        guard let free = values[.systemFreeSize] as? NSNumber,
          let total = values[.systemSize] as? NSNumber else { throw CocoaError(.fileReadUnknown) }
        disk.metrics["volume_free_bytes"] = free.doubleValue
        disk.metrics["volume_total_bytes"] = total.doubleValue
      } catch {
        disk.counters["resource_disk_error_code"] = (error as NSError).code
      }
    }
    result.snapshot.metrics.merge(disk.metrics) { _, new in new }
    result.snapshot.counters.merge(disk.counters) { _, new in new }
    result.snapshot.metrics["resource_sample_duration_seconds"] = ProcessInfo.processInfo.systemUptime - started
    return result
  }
}
