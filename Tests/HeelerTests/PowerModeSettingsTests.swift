import Foundation
import Testing

@testable import Heeler

@MainActor
@Suite("Power mode settings")
struct PowerModeSettingsTests {
    private func makeDefaults() throws -> (UserDefaults, cleanup: () -> Void) {
        let suiteName = "power-mode-settings-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
    }

    @Test func defaultsToPerformanceWithoutWritingAPreference() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }

        #expect(PowerModeSettings(defaults: defaults).mode == .performance)
        #expect(defaults.object(forKey: "app.power-mode") == nil)
    }

    @Test func batteryEconomyIsRememberedAcrossLaunches() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let settings = PowerModeSettings(defaults: defaults)

        settings.select(.batteryEconomy)

        #expect(settings.mode == .batteryEconomy)
        #expect(PowerModeSettings(defaults: defaults).mode == .batteryEconomy)
    }

    @Test func switchingBackToPerformanceIsRemembered() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let settings = PowerModeSettings(defaults: defaults)
        settings.select(.batteryEconomy)

        settings.select(.performance)

        #expect(settings.mode == .performance)
        #expect(PowerModeSettings(defaults: defaults).mode == .performance)
    }

    @Test func unknownStoredModeFallsBackToPerformance() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        defaults.set("future-mode", forKey: "app.power-mode")

        #expect(PowerModeSettings(defaults: defaults).mode == .performance)
    }

    @Test func reselectingTheCurrentModeWritesNothing() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let settings = PowerModeSettings(defaults: defaults)

        settings.select(.performance)

        #expect(defaults.object(forKey: "app.power-mode") == nil)
    }
}
