import Foundation

#if canImport(Darwin)
import Darwin
#endif

struct ProcessMemorySnapshot {
  let residentBytes: UInt64
  let physicalFootprintBytes: UInt64?
  let virtualBytes: UInt64?

  var bestCurrentBytes: UInt64 {
    physicalFootprintBytes ?? residentBytes
  }
}

#if canImport(Darwin)
func currentProcessMemorySnapshot() -> ProcessMemorySnapshot? {
  var info = task_vm_info_data_t()
  var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
  let kr: kern_return_t = withUnsafeMutablePointer(to: &info) { ptr in
    ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebounded in
      task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebounded, &count)
    }
  }
  guard kr == KERN_SUCCESS else {
    // Fall back to basic info if TASK_VM_INFO is unavailable.
    var basic = mach_task_basic_info()
    var basicCount = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
    let basicKr: kern_return_t = withUnsafeMutablePointer(to: &basic) { ptr in
      ptr.withMemoryRebound(to: integer_t.self, capacity: Int(basicCount)) { rebounded in
        task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebounded, &basicCount)
      }
    }
    guard basicKr == KERN_SUCCESS else { return nil }
    return ProcessMemorySnapshot(
      residentBytes: UInt64(basic.resident_size),
      physicalFootprintBytes: nil,
      virtualBytes: UInt64(basic.virtual_size)
    )
  }

  return ProcessMemorySnapshot(
    residentBytes: UInt64(info.resident_size),
    physicalFootprintBytes: UInt64(info.phys_footprint),
    virtualBytes: UInt64(info.virtual_size)
  )
}
#else
func currentProcessMemorySnapshot() -> ProcessMemorySnapshot? {
  nil
}
#endif

final class ProcessMemorySampler {
  private let interval: TimeInterval
  private let queue = DispatchQueue(label: "lexical.tests.memory-sampler")
  private var timer: DispatchSourceTimer?

  private(set) var maxResidentBytes: UInt64 = 0
  private(set) var maxPhysicalFootprintBytes: UInt64 = 0

  init(interval: TimeInterval = 0.01) {
    self.interval = interval
  }

  func start() {
    maxResidentBytes = 0
    maxPhysicalFootprintBytes = 0

    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now(), repeating: interval)
    timer.setEventHandler { [weak self] in
      guard let self else { return }
      guard let snapshot = currentProcessMemorySnapshot() else { return }
      self.maxResidentBytes = max(self.maxResidentBytes, snapshot.residentBytes)
      if let footprint = snapshot.physicalFootprintBytes {
        self.maxPhysicalFootprintBytes = max(self.maxPhysicalFootprintBytes, footprint)
      }
    }
    self.timer = timer
    timer.resume()
  }

  func stop() {
    timer?.cancel()
    timer = nil
  }
}

func formatBytesMB(_ bytes: UInt64) -> String {
  let mb = Double(bytes) / (1024.0 * 1024.0)
  return String(format: "%.1fMB", mb)
}

