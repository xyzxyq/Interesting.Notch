import Cocoa
import Defaults
import Foundation
import IOKit.ps
import SwiftUI

/// A view model that manages and monitors the battery status of the device
@MainActor
class BatteryStatusViewModel: ObservableObject {

    private let coordinator = BoringViewCoordinator.shared

    @Published private(set) var levelBattery: Float = 0.0
    @Published private(set) var maxCapacity: Float = 0.0
    @Published private(set) var isPluggedIn: Bool = false
    @Published private(set) var isCharging: Bool = false
    @Published private(set) var isInLowPowerMode: Bool = false
    @Published private(set) var isInitial: Bool = false
    @Published private(set) var timeToFullCharge: Int = 0
    @Published private(set) var statusText: String = ""

    private let managerBattery = BatteryActivityManager.shared
    private var managerBatteryId: Int?

    static let shared = BatteryStatusViewModel()

    /// Initializes the view model with a given BoringViewModel instance
    /// - Parameter vm: The BoringViewModel instance
    private init() {
        setupPowerStatus()
        setupMonitor()
    }

    /// Sets up the initial power status by fetching battery information
    private func setupPowerStatus() {
        let batteryInfo = managerBattery.initializeBatteryInfo()
        updateBatteryInfo(batteryInfo)
    }

    private func setupMonitor() {
        managerBatteryId = managerBattery.addObserver { [weak self] info in
            self?.updateBatteryInfo(info, notify: true)
        }
    }

    private func updateBatteryInfo(_ info: BatteryInfo, notify: Bool = false) {
        let importantChange = isPluggedIn != info.isPluggedIn || isCharging != info.isCharging
            || isInLowPowerMode != info.isInLowPowerMode
        let powerModeChanged = isInLowPowerMode != info.isInLowPowerMode
        withAnimation(NotchMotionEnvironment.transientAnimation) {
            if levelBattery != info.currentCapacity { levelBattery = info.currentCapacity }
            if maxCapacity != info.maxCapacity { maxCapacity = info.maxCapacity }
            if isPluggedIn != info.isPluggedIn { isPluggedIn = info.isPluggedIn }
            if isCharging != info.isCharging { isCharging = info.isCharging }
            if isInLowPowerMode != info.isInLowPowerMode { isInLowPowerMode = info.isInLowPowerMode }
            if timeToFullCharge != info.timeToFullCharge { timeToFullCharge = info.timeToFullCharge }
            if importantChange || !notify {
                statusText = powerModeChanged && notify
                    ? "Low Power: \(info.isInLowPowerMode ? "On" : "Off")"
                    : !info.isPluggedIn ? "Unplugged"
                    : info.isCharging ? "Charging battery"
                    : info.maxCapacity > 0 && info.currentCapacity >= info.maxCapacity ? "Full charge"
                    : "Not charging"
            }
            if notify && importantChange && Defaults[.showPowerStatusNotifications] {
                coordinator.toggleExpandingView(status: true, type: .battery)
            }
        }
    }

    deinit {
        print("🔌 Cleaning up battery monitoring...")
        if let managerBatteryId: Int = managerBatteryId {
            managerBattery.removeObserver(byId: managerBatteryId)
        }
    }

}
