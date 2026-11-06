import Foundation
import IOKit
import Darwin

// Read-only telemetry: never changes playback, brightness, charging or app settings.
@main struct FocusPowerProbe {
    static let secondsPerTick: Double = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }()
    static func cpu(_ pid: Int32) -> Double? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return nil }
        return Double(info.pti_total_user + info.pti_total_system) * secondsPerTick
    }

    static func hostTicks() -> [UInt32] {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        precondition(result == KERN_SUCCESS)
        return [info.cpu_ticks.0, info.cpu_ticks.1, info.cpu_ticks.2, info.cpu_ticks.3]
    }

    static func main() throws {
        let args = CommandLine.arguments
        guard args.count >= 5, let seconds = Int(args[3]), (1...600).contains(seconds) else {
            fatalError("Usage: FocusPowerProbe label output.json seconds role=pid ...")
        }
        let pids = Dictionary(uniqueKeysWithValues: args.dropFirst(4).map { value -> (String, Int32) in
            let pair = value.split(separator: "=", maxSplits: 1)
            guard pair.count == 2, let pid = Int32(pair[1]), pid > 0 else { fatalError("Invalid PID argument") }
            return (String(pair[0]), pid)
        })
        setbuf(stdout, nil)
        let beforeCheck = cpu(getpid())!, beganCheck = ProcessInfo.processInfo.systemUptime
        var digest = 0.0
        repeat { for i in 1...1000 { digest += sin(Double(i)) } }
        while ProcessInfo.processInfo.systemUptime - beganCheck < 0.08
        let ratio = (cpu(getpid())! - beforeCheck) / (ProcessInfo.processInfo.systemUptime - beganCheck)
        print("CPU clock calibration: \(ratio), seconds/tick: \(secondsPerTick)")
        precondition((0.4...1.5).contains(ratio) && digest.isFinite, "CPU counter time units failed calibration")

        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { fatalError("No whole-system power telemetry on this hardware") }
        defer { IOObjectRelease(service) }
        func property(_ name: String) -> Any? {
            IORegistryEntryCreateCFProperty(service, name as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }
        print("Warmup 15 seconds; then \(seconds) samples for \(args[1])")
        Thread.sleep(forTimeInterval: 15)
        var previousCPU = pids.mapValues { cpu($0) }
        var previousTicks = hostTicks()
        var previousTime = ProcessInfo.processInfo.systemUptime
        var rows = [[String: Any]]()
        for index in 0..<seconds {
            Thread.sleep(forTimeInterval: max(0, previousTime + 1 - ProcessInfo.processInfo.systemUptime))
            let now = ProcessInfo.processInfo.systemUptime
            let elapsed = now - previousTime
            guard let telemetry = property("PowerTelemetryData") as? [String: Any],
                  let power = telemetry["SystemPowerIn"] as? NSNumber,
                  let volts = telemetry["SystemVoltageIn"] as? NSNumber,
                  let amps = telemetry["SystemCurrentIn"] as? NSNumber else {
                fatalError("Required power fields disappeared")
            }
            let inputWatts = power.doubleValue / 1000
            let electricalWatts = volts.doubleValue * amps.doubleValue / 1_000_000
            var row: [String: Any] = ["unix_time": Date().timeIntervalSince1970, "seconds": elapsed,
                "input_watts": inputWatts, "voltage_current_watts": electricalWatts,
                "power_units_consistent": abs(inputWatts - electricalWatts) < max(0.5, inputWatts * 0.1),
                "ac": property("ExternalConnected") as? Bool ?? false,
                "charging": property("IsCharging") as? Bool ?? false,
                "battery_watts": (telemetry["BatteryPower"] as? NSNumber).map { $0.doubleValue / 1000 as Any } ?? NSNull(),
                "thermal_state": ProcessInfo.processInfo.thermalState.rawValue]
            #if SMC_PROBE
            let totalPower = SMC.shared.getValue("PSTR")
            row["smc_system_watts"] = totalPower.map { $0 as Any } ?? NSNull()
            precondition(totalPower.map { $0.isFinite && $0 > 0 && $0 < 250 } ?? false, "Invalid SMC system power")
            #endif
            let ticks = hostTicks()
            let delta = zip(ticks, previousTicks).map { Double($0 &- $1) }
            let total = delta.reduce(0, +)
            row["system_cpu_percent"] = total > 0 ? (total - delta[Int(CPU_STATE_IDLE)]) / total * 100 : 0
            previousTicks = ticks
            for (role, pid) in pids {
                let current = cpu(pid)
                if let current, let old = previousCPU[role] ?? nil {
                    row[role + "_cpu_percent"] = max(0, current - old) / elapsed * 100
                } else { row[role + "_cpu_percent"] = NSNull() }
                previousCPU[role] = current
            }
            rows.append(row)
            previousTime = now
            if (index + 1) % 15 == 0 { print("\(args[1]): \(index + 1)/\(seconds)") }
        }
        let result: [String: Any] = ["label": args[1], "pids": pids, "samples": rows,
            "logical_cpus": ProcessInfo.processInfo.processorCount,
            "metric": "SMC PSTR when compiled with SMC_PROBE; cached AppleSmartBattery SystemPowerIn retained as diagnostic only; neither is a wall meter"]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: args[2]), options: .atomic)
        print("Saved \(args[2])")
    }
}
