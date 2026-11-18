import Foundation
import Observation

enum AppPowerMode: String, CaseIterable, Sendable {
    case performance
    case batteryEconomy

    var dashboardLiveCellsPerHost: Int {
        switch self {
        case .performance: 4
        case .batteryEconomy: 2
        }
    }

    var dashboardPreviewInterval: Duration {
        switch self {
        case .performance: .seconds(3)
        case .batteryEconomy: .seconds(15)
        }
    }
}

/// One choice for every window, remembered across launches. Existing installs
/// keep Performance until Battery Economy is selected.
@MainActor
@Observable
final class PowerModeSettings {
    private static let defaultsKey = "app.power-mode"

    private(set) var mode: AppPowerMode
    @ObservationIgnored private nonisolated(unsafe) let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        mode = defaults.string(forKey: Self.defaultsKey)
            .flatMap(AppPowerMode.init(rawValue:)) ?? .performance
    }

    func select(_ mode: AppPowerMode) {
        guard mode != self.mode else { return }
        self.mode = mode
        defaults.set(mode.rawValue, forKey: Self.defaultsKey)
    }
}
