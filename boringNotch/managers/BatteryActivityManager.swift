import Foundation
import IOKit.ps

/// Manages and monitors battery status changes on the device
/// - Note: This class uses the IOKit framework to monitor battery status
class BatteryActivityManager {

    static let shared = BatteryActivityManager()

    private var batterySource: CFRunLoopSource?
    private var observers: [Int: @MainActor (BatteryInfo) -> Void] = [:]
    private var nextObserverID = 0
    private var previousBatteryInfo: BatteryInfo?

    enum BatteryError: Error {
        case powerSourceUnavailable
        case batteryInfoUnavailable(String)
        case batteryParameterMissing(String)
    }

    private let defaultBatteryInfo = BatteryInfo(
        isPluggedIn: false,
        isCharging: false,
        currentCapacity: 0,
        maxCapacity: 0,
        isInLowPowerMode: false,
        timeToFullCharge: 0
    )

    private init() {
        startMonitoring()
        setupLowPowerModeObserver()
    }
    
    /// Setup observer for low power mode changes
    private func setupLowPowerModeObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(lowPowerModeChanged),
            name: NSNotification.Name.NSProcessInfoPowerStateDidChange,
            object: nil
        )
    }

    /// Called when low power mode is enabled or disabled
    @objc private func lowPowerModeChanged() {
        notifyBatteryChanges()
    }
    
    /// Starts monitoring battery changes
    private func startMonitoring() {
        guard let powerSource = IOPSNotificationCreateRunLoopSource({ context in
            guard let context = context else { return }
            let manager = Unmanaged<BatteryActivityManager>.fromOpaque(context).takeUnretainedValue()
            manager.notifyBatteryChanges()
        }, Unmanaged.passUnretained(self).toOpaque())?.takeRetainedValue() else {
            return
        }
        batterySource = powerSource
        CFRunLoopAddSource(CFRunLoopGetCurrent(), powerSource, .defaultMode)
    }

    /// Stops monitoring battery changes
    private func stopMonitoring() {
        if let powerSource = batterySource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), powerSource, .defaultMode)
            batterySource = nil
        }
    }

    private func notifyBatteryChanges() {
        let info = getBatteryInfo()
        guard info != previousBatteryInfo else { return }
        previousBatteryInfo = info
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for observer in self.observers.values { observer(info) }
        }
    }

    /// Initializes the battery information when the manager starts
    /// - Returns: Current battery information
    func initializeBatteryInfo() -> BatteryInfo {
        previousBatteryInfo = getBatteryInfo()
        guard let batteryInfo = previousBatteryInfo else {
            return BatteryInfo(
                isPluggedIn: false,
                isCharging: false,
                currentCapacity: 0,
                maxCapacity: 0,
                isInLowPowerMode: false,
                timeToFullCharge: 0
            )
        }
        return batteryInfo
    }

    /// Get the current battery information
    /// - Returns: The current battery information
    private func getBatteryInfo() -> BatteryInfo {
        do {
            // Get power source information
            guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
                throw BatteryError.powerSourceUnavailable
            }
            
            guard let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef],
                !sources.isEmpty else {
                throw BatteryError.batteryInfoUnavailable("No power sources available")
            }
            
            let source = sources.first!
            
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any] else {
                throw BatteryError.batteryInfoUnavailable("Could not get power source description")
            }
            
            // Extract required battery parameters with error handling
            guard let currentCapacity = description[kIOPSCurrentCapacityKey] as? Float else {
                throw BatteryError.batteryParameterMissing("Current capacity")
            }
            
            guard let maxCapacity = description[kIOPSMaxCapacityKey] as? Float else {
                throw BatteryError.batteryParameterMissing("Max capacity")
            }
            
            guard let isCharging = description["Is Charging"] as? Bool else {
                throw BatteryError.batteryParameterMissing("Charging state")
            }
            
            guard let powerSource = description[kIOPSPowerSourceStateKey] as? String else {
                throw BatteryError.batteryParameterMissing("Power source state")
            }
            
            // Create battery info with the extracted parameters
            var batteryInfo = BatteryInfo(
                isPluggedIn: powerSource == kIOPSACPowerValue,
                isCharging: isCharging,
                currentCapacity: currentCapacity,
                maxCapacity: maxCapacity,
                isInLowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                timeToFullCharge: 0
            )
            
            // Optional parameters
            if let timeToFullCharge = description[kIOPSTimeToFullChargeKey] as? Int {
                batteryInfo.timeToFullCharge = timeToFullCharge
            }
            
            return batteryInfo
            
        } catch BatteryError.powerSourceUnavailable {
            print("⚠️ Error: Power source information unavailable")
            return defaultBatteryInfo
        } catch BatteryError.batteryInfoUnavailable(let reason) {
            print("⚠️ Error: Battery information unavailable - \(reason)")
            return defaultBatteryInfo
        } catch BatteryError.batteryParameterMissing(let parameter) {
            print("⚠️ Error: Battery parameter missing - \(parameter)")
            return defaultBatteryInfo
        } catch {
            print("⚠️ Error: Unexpected error getting battery info - \(error.localizedDescription)")
            return defaultBatteryInfo
        }
    }
    
    func addObserver(_ observer: @escaping @MainActor (BatteryInfo) -> Void) -> Int {
        let id = nextObserverID
        nextObserverID += 1
        observers[id] = observer
        return id
    }

    func removeObserver(byId id: Int) {
        observers.removeValue(forKey: id)
    }

    deinit {
        stopMonitoring()
        NotificationCenter.default.removeObserver(self)
    }
    
}

/// Struct to hold battery information
struct BatteryInfo: Equatable {
    var isPluggedIn: Bool
    var isCharging: Bool
    var currentCapacity: Float
    var maxCapacity: Float
    var isInLowPowerMode: Bool
    var timeToFullCharge: Int
}
