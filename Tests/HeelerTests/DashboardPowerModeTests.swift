import Foundation
import SwiftUI
import Testing
import UIKit

@testable import Heeler

@MainActor
@Suite("Dashboard power modes", .serialized, .timeLimit(.minutes(3)))
struct DashboardPowerModeTests {
    private func ids(host: Host.ID, count: Int) -> [ConsoleTerminal.ID] {
        (0..<count).map { .init(hostID: host, paneID: "pane-\($0)") }
    }

    @Test func eachHostGetsItsOwnLiveCellBudget() {
        let first = ids(host: UUID(), count: 5)
        let second = ids(host: UUID(), count: 5)
        let order = zip(first, second).flatMap { [$0.0, $0.1] }
        let visible = Set(order)

        #expect(ConsoleDashboardView.liveCellIDs(
            order: order, visible: visible, previewOnlyHosts: [], mode: .performance)
            == Set(first.prefix(4) + second.prefix(4)))
        #expect(ConsoleDashboardView.liveCellIDs(
            order: order, visible: visible, previewOnlyHosts: [], mode: .batteryEconomy)
            == Set(first.prefix(2) + second.prefix(2)))
    }

    @Test func offscreenCellsCannotSpendTheEconomyBudget() {
        let order = ids(host: UUID(), count: 6)
        let visible = Set(order.suffix(2))

        #expect(ConsoleDashboardView.liveCellIDs(
            order: order, visible: visible, previewOnlyHosts: [], mode: .batteryEconomy) == visible)
        #expect(ConsoleDashboardView.liveCellIDs(
            order: order, visible: visible, previewOnlyHosts: [], mode: .performance) == Set(order.prefix(4)))
    }

    @Test(arguments: AppPowerMode.allCases)
    func previewOnlyHostsNeverReceiveLiveCells(mode: AppPowerMode) {
        let previewHost = UUID()
        let previewIDs = ids(host: previewHost, count: 3)
        let liveIDs = ids(host: UUID(), count: 2)
        let order = previewIDs + liveIDs

        #expect(ConsoleDashboardView.liveCellIDs(
            order: order, visible: Set(order), previewOnlyHosts: [previewHost], mode: mode) == Set(liveIDs))
    }

    @Test func scrollingReassignsEconomySlotsAndSwitchingModeRestoresThePerformanceBudget() {
        let order = ids(host: UUID(), count: 6)
        let firstViewport = Set(order.prefix(3))
        let nextViewport = Set(order.suffix(3))

        #expect(ConsoleDashboardView.liveCellIDs(
            order: order, visible: firstViewport, previewOnlyHosts: [], mode: .batteryEconomy)
            == Set(order.prefix(2)))
        #expect(ConsoleDashboardView.liveCellIDs(
            order: order, visible: nextViewport, previewOnlyHosts: [], mode: .batteryEconomy)
            == Set(order[3...4]))
        #expect(ConsoleDashboardView.liveCellIDs(
            order: order, visible: nextViewport, previewOnlyHosts: [], mode: .performance)
            == Set(order.prefix(4)))
    }

    @Test func performanceKeepsHiddenAndCoveredCellsRunningWhileEconomyRequiresVisibility() {
        for (visible, covered) in [(false, false), (true, true), (false, true)] {
            #expect(ConsoleDashboardView.shouldRunCell(
                mode: .performance, isVisible: visible, isCovered: covered, isBackground: false))
            #expect(!ConsoleDashboardView.shouldRunCell(
                mode: .batteryEconomy, isVisible: visible, isCovered: covered, isBackground: false))
        }
        #expect(ConsoleDashboardView.shouldRunCell(
            mode: .batteryEconomy, isVisible: true, isCovered: false, isBackground: false))
    }

    @Test(arguments: AppPowerMode.allCases)
    func backgroundAlwaysPausesDashboardCells(mode: AppPowerMode) {
        #expect(!ConsoleDashboardView.shouldRunCell(
            mode: mode, isVisible: true, isCovered: false, isBackground: true))
    }

    @Test func economyEndsOutputWhenTheLastVisibleOwnerLeaves() async throws {
        let state = LiveTerminalState()
        defer { state.stop() }
        let observer = Observer()
        let owner = UUID()
        try await show(state, owner: owner, observer: observer, retainWhenHidden: false)

        state.setVisible(false, owner: owner, retainWhenHidden: false, grid: "80x24", makeStore: observer.makeStore)

        #expect(state.store == nil)
        #expect(!state.hasVisibleOwners)
        try await waitUntil("the hidden observer must close its attach") {
            await !observer.transport.hasLiveAttachSession
        }
        let previousOutput = observer.output.chunks
        #expect(await !observer.transport.emitAttachOutput(Data("hidden-output".utf8)))
        #expect(observer.output.chunks == previousOutput)
        #expect(await observer.transport.attachInputs.isEmpty)
    }

    @Test func anotherVisibleOwnerProtectsTheSharedTransportLease() async throws {
        let state = LiveTerminalState()
        defer { state.stop() }
        let observer = Observer()
        let firstWindow = UUID()
        let secondWindow = UUID()
        try await show(state, owner: firstWindow, observer: observer, retainWhenHidden: false)
        let store = try #require(state.store)
        state.setVisible(
            true, owner: secondWindow, retainWhenHidden: false, grid: "80x24", makeStore: observer.makeStore)

        state.setVisible(
            false, owner: firstWindow, retainWhenHidden: false, grid: "80x24", makeStore: observer.makeStore)

        #expect(state.store === store)
        #expect(state.hasVisibleOwners)
        #expect(await observer.transport.hasLiveAttachSession)
        #expect(await observer.transport.attachRequests.count == 1)

        state.setVisible(
            false, owner: secondWindow, retainWhenHidden: false, grid: "80x24", makeStore: observer.makeStore)
        try await waitUntil("the last window leaving must close the attach") {
            await !observer.transport.hasLiveAttachSession
        }
    }

    @Test func selectingEconomyPrunesAlreadyHiddenObserversAndKeepsVisibleOnes() async throws {
        let suiteName = "dashboard-power-mode-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let console = ConsoleStore(powerSettings: PowerModeSettings(defaults: defaults))
        let host = UUID()
        defer { console.viewOnlyPool.removeHost(host) }
        let terminals = ids(host: host, count: 2)
        let hidden = console.viewOnlyPool.state(for: .init(id: terminals[0], generation: 1, attempt: 0))
        let visible = console.viewOnlyPool.state(for: .init(id: terminals[1], generation: 1, attempt: 0))
        let hiddenObserver = Observer()
        let visibleObserver = Observer()
        let hiddenOwner = UUID()
        try await show(hidden, owner: hiddenOwner, observer: hiddenObserver, retainWhenHidden: true)
        try await show(visible, owner: UUID(), observer: visibleObserver, retainWhenHidden: true)
        hidden.setVisible(
            false, owner: hiddenOwner, retainWhenHidden: true, grid: "80x24", makeStore: hiddenObserver.makeStore)
        #expect(await hiddenObserver.transport.hasLiveAttachSession)

        console.setPowerMode(.batteryEconomy)

        #expect(hidden.store == nil)
        #expect(visible.store != nil)
        try await waitUntil("switching to Economy must close an already hidden observer") {
            await !hiddenObserver.transport.hasLiveAttachSession
        }
        #expect(await visibleObserver.transport.hasLiveAttachSession)
        #expect(await hiddenObserver.transport.attachInputs.isEmpty)
        visible.stop()
        try await waitUntil("the remaining observer must close during cleanup") {
            await !visibleObserver.transport.hasLiveAttachSession
        }
    }

    @Test func reopeningAnEconomyObserverStaysWatchOnlyWithoutInputOrResize() async throws {
        let state = LiveTerminalState()
        defer { state.stop() }
        let observer = Observer()
        let owner = UUID()
        try await show(state, owner: owner, observer: observer, retainWhenHidden: false)
        let firstStore = try #require(state.store)
        state.setVisible(false, owner: owner, retainWhenHidden: false, grid: "80x24", makeStore: observer.makeStore)
        try await waitUntil("the first attach must finish before reopening") {
            await !observer.transport.hasLiveAttachSession
        }

        try await show(state, owner: owner, observer: observer, retainWhenHidden: false)

        #expect(state.store !== firstStore)
        let requests = await observer.transport.attachRequests
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.viewer == .observe && !$0.takeover })
        #expect(await observer.transport.attachInputs.isEmpty)
        state.stop()
        try await waitUntil("the reopened attach must close during cleanup") {
            await !observer.transport.hasLiveAttachSession
        }
        #expect(await observer.transport.attachInputs.isEmpty)
    }

    @Test func consoleResumeRestoresVisibleEconomyObserversWithoutAnotherSceneCallback() async throws {
        let suiteName = "dashboard-power-resume-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let powerSettings = PowerModeSettings(defaults: defaults)
        powerSettings.select(.batteryEconomy)
        let console = ConsoleStore(powerSettings: powerSettings)
        let host = UUID()
        defer { console.viewOnlyPool.removeHost(host) }
        let terminals = ids(host: host, count: 2)
        let visible = console.viewOnlyPool.state(for: .init(id: terminals[0], generation: 1, attempt: 0))
        let hidden = console.viewOnlyPool.state(for: .init(id: terminals[1], generation: 1, attempt: 0))
        let visibleObserver = Observer()
        let hiddenObserver = Observer()
        let hiddenOwner = UUID()
        try await show(visible, owner: UUID(), observer: visibleObserver, retainWhenHidden: false)
        try await show(hidden, owner: hiddenOwner, observer: hiddenObserver, retainWhenHidden: false)
        let previous = try #require(visible.store)
        hidden.setVisible(
            false, owner: hiddenOwner, retainWhenHidden: false, grid: "80x24", makeStore: hiddenObserver.makeStore)

        await console.suspend()

        #expect(visible.store == nil)
        #expect(visible.hasVisibleOwners)
        #expect(hidden.store == nil)
        #expect(!hidden.hasVisibleOwners)
        try await waitUntil("suspension must finish the previous observer") {
            await !visibleObserver.transport.hasLiveAttachSession
        }
        try await waitUntil("the hidden observer must finish closing") {
            await !hiddenObserver.transport.hasLiveAttachSession
        }

        // A queued lifecycle transition may finish after SwiftUI has already
        // reported the foreground phase. No second setVisible arrives here.
        await console.resume()

        let restored = try #require(visible.store)
        #expect(restored !== previous)
        #expect(hidden.store == nil)
        try await start(restored, observer: visibleObserver)
        let requests = await visibleObserver.transport.attachRequests
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.viewer == .observe && !$0.takeover })
        #expect(await hiddenObserver.transport.attachRequests.count == 1)
        #expect(await visibleObserver.transport.attachInputs.isEmpty)
        visible.stop()
        try await waitUntil("the restored observer must close during cleanup") {
            await !visibleObserver.transport.hasLiveAttachSession
        }
    }

    @Test func lateTeardownCannotStopTheObserverOpenedDuringRapidHideAndReturn() async throws {
        let state = LiveTerminalState()
        let previous = Observer()
        let replacement = Observer()
        let endGate = ScriptedTransportCallGate()
        defer {
            Task { await endGate.open() }
            state.stop()
        }
        await previous.transport.gateNextAttachEnd(on: endGate)
        let owner = UUID()
        try await show(state, owner: owner, observer: previous, retainWhenHidden: false)
        state.setVisible(false, owner: owner, retainWhenHidden: false, grid: "80x24", makeStore: previous.makeStore)
        try await waitUntil("old cleanup must reach its blocked channel close") { await endGate.entryCount == 1 }

        // Separate scripted channels model a core's simultaneous Attaches;
        // this replacement paints while the previous channel is still closing.
        try await show(state, owner: owner, observer: replacement, retainWhenHidden: false)
        let replacementStore = try #require(state.store)
        await endGate.open()
        try await waitUntil("the old channel must finish closing") { await !previous.transport.hasLiveAttachSession }

        #expect(state.store === replacementStore)
        #expect(state.hasVisibleOwners)
        #expect(await replacement.transport.hasLiveAttachSession)
        let nextOutput = Data("still-live".utf8)
        #expect(await replacement.transport.emitAttachOutput(nextOutput))
        try await waitUntil("the replacement must keep consuming output after old cleanup") {
            replacement.output.chunks.last == nextOutput
        }
        #expect(await replacement.transport.attachRequests.first?.viewer == .observe)
        #expect(await previous.transport.attachInputs.isEmpty)
        #expect(await replacement.transport.attachInputs.isEmpty)
        state.stop()
        try await waitUntil("the replacement must close during cleanup") { await !replacement.transport.hasLiveAttachSession }
    }

    @Test func performanceEvictsTheLeastRecentlyUsedHiddenObserver() async throws {
        let pool = ViewOnlyPool()
        let host = UUID()
        defer { pool.removeHost(host) }
        let terminalIDs = ids(host: host, count: 4)
        let keys = terminalIDs.map { ViewOnlyPool.Key(id: $0, generation: 1, attempt: 0) }
        var states: [LiveTerminalState] = []
        var observers: [Observer] = []
        for key in keys.prefix(3) {
            let state = pool.state(for: key)
            let observer = Observer()
            let owner = UUID()
            try await show(state, owner: owner, observer: observer, retainWhenHidden: true)
            state.setVisible(false, owner: owner, retainWhenHidden: true, grid: "80x24", makeStore: observer.makeStore)
            states.append(state)
            observers.append(observer)
        }
        #expect(pool.state(for: keys[0]) === states[0])

        _ = pool.state(for: keys[3])

        try await waitUntil("the least recently used hidden observer must close") {
            await !observers[1].transport.hasLiveAttachSession
        }
        #expect(states[1].store == nil)
        #expect(await observers[0].transport.hasLiveAttachSession)
        #expect(await observers[2].transport.hasLiveAttachSession)
        #expect(await observers[1].transport.closedPanes.isEmpty)
        #expect(await observers[1].transport.closedTabs.isEmpty)
    }

    @Test func cachePressureEvictsHiddenObserversBeforeAnOlderVisibleLease() async throws {
        let pool = ViewOnlyPool()
        let host = UUID()
        defer { pool.removeHost(host) }
        let terminalIDs = ids(host: host, count: 4)
        let visible = pool.state(for: .init(id: terminalIDs[0], generation: 1, attempt: 0))
        let visibleObserver = Observer()
        try await show(visible, owner: UUID(), observer: visibleObserver, retainWhenHidden: true)
        var hidden: [(state: LiveTerminalState, observer: Observer)] = []
        for id in terminalIDs[1...2] {
            let state = pool.state(for: .init(id: id, generation: 1, attempt: 0))
            let observer = Observer()
            let owner = UUID()
            try await show(state, owner: owner, observer: observer, retainWhenHidden: true)
            state.setVisible(false, owner: owner, retainWhenHidden: true, grid: "80x24", makeStore: observer.makeStore)
            hidden.append((state, observer))
        }

        _ = pool.state(for: .init(id: terminalIDs[3], generation: 1, attempt: 0))

        try await waitUntil("cache pressure must close the oldest hidden attach") {
            await !hidden[0].observer.transport.hasLiveAttachSession
        }
        #expect(visible.hasVisibleOwners)
        #expect(await visibleObserver.transport.hasLiveAttachSession)
        #expect(await hidden[1].observer.transport.hasLiveAttachSession)
    }

    @Test func removingOneHostClosesOnlyItsObserversAndResumeCannotRestoreThem() async throws {
        let pool = ViewOnlyPool()
        pool.applyPowerMode(.batteryEconomy)
        let firstHost = UUID()
        let otherHost = UUID()
        defer {
            pool.removeHost(firstHost)
            pool.removeHost(otherHost)
        }
        let removed = pool.state(for: .init(id: ids(host: firstHost, count: 1)[0], generation: 1, attempt: 0))
        let kept = pool.state(for: .init(id: ids(host: otherHost, count: 1)[0], generation: 1, attempt: 0))
        let removedObserver = Observer()
        let keptObserver = Observer()
        try await show(removed, owner: UUID(), observer: removedObserver, retainWhenHidden: false)
        try await show(kept, owner: UUID(), observer: keptObserver, retainWhenHidden: false)

        pool.removeHost(firstHost)
        pool.resume()

        try await waitUntil("removing a Host must end its attach") { await !removedObserver.transport.hasLiveAttachSession }
        #expect(removed.store == nil)
        #expect(removedObserver.createdStores == 1)
        #expect(await keptObserver.transport.hasLiveAttachSession)
        #expect(await removedObserver.transport.closedPanes.isEmpty)
        #expect(await removedObserver.transport.closedTabs.isEmpty)
    }

    @Test func aNewConnectionGenerationRetiresThePreviousObserverWithoutStoppingItsReplacement() async throws {
        let pool = ViewOnlyPool()
        let host = UUID()
        defer { pool.removeHost(host) }
        let id = ids(host: host, count: 1)[0]
        let oldState = pool.state(for: .init(id: id, generation: 1, attempt: 0))
        let previous = Observer()
        let oldOwner = UUID()
        try await show(oldState, owner: oldOwner, observer: previous, retainWhenHidden: true)

        let key = ViewOnlyPool.Key(id: id, generation: 2, attempt: 0)
        let newState = pool.state(for: key)
        let replacement = Observer()
        try await show(newState, owner: UUID(), observer: replacement, retainWhenHidden: true)
        oldState.setVisible(false, owner: oldOwner, retainWhenHidden: false, grid: "80x24", makeStore: previous.makeStore)

        try await waitUntil("the old generation's observer must close") { await !previous.transport.hasLiveAttachSession }
        #expect(newState !== oldState)
        #expect(pool.state(for: key) === newState)
        #expect(await replacement.transport.hasLiveAttachSession)
        #expect(await replacement.transport.attachRequests.first?.viewer == .observe)
        #expect(await replacement.transport.attachInputs.isEmpty)
    }

    @Test func hidingDuringRemoteResizeCancelsThePendingReattach() async throws {
        let state = LiveTerminalState()
        defer { state.stop() }
        let initial = Observer()
        let resized = Observer()
        let owner = UUID()
        try await show(state, owner: owner, observer: initial, retainWhenHidden: false)
        state.setVisible(true, owner: owner, retainWhenHidden: false, grid: "100x30", makeStore: resized.makeStore)

        state.setVisible(false, owner: owner, retainWhenHidden: false, grid: "100x30", makeStore: resized.makeStore)
        try await waitUntil("hiding must end the old attach") { await !initial.transport.hasLiveAttachSession }
        // The production resize debounce is 500 ms. A canceled timer must not
        // recreate an observer after the last consumer has left.
        try await Task.sleep(for: .milliseconds(650))

        #expect(state.store == nil)
        #expect(resized.createdStores == 0)
        #expect(await resized.transport.attachRequests.isEmpty)
        #expect(await initial.transport.attachInputs.isEmpty)
    }

    @Test func visibleLeaseAdmissionStaysBoundedThroughSuspendAndRetryAfterASlotIsReleased() async throws {
        let pool = ViewOnlyPool()
        pool.applyPowerMode(.batteryEconomy)
        let host = UUID()
        defer { pool.removeHost(host) }
        let keys = ids(host: host, count: 6).map { ViewOnlyPool.Key(id: $0, generation: 1, attempt: 0) }
        let owners = keys.map { _ in UUID() }
        let observers = keys.map { _ in Observer() }
        var states: [LiveTerminalState] = []
        for index in keys.indices {
            let state = pool.state(for: keys[index])
            states.append(state)
            if index < 3 {
                try await show(state, owner: owners[index], observer: observers[index], retainWhenHidden: false)
                #expect(pool.state(for: keys[index]) === state)
            } else {
                state.setVisible(
                    true, owner: owners[index], retainWhenHidden: false,
                    grid: "80x24", makeStore: observers[index].makeStore)
                #expect(state.isAtCapacity)
                #expect(state.store == nil)
                #expect(observers[index].createdStores == 0)
                #expect(await observers[index].transport.attachRequests.isEmpty)
            }
        }
        #expect(states.filter { $0.store != nil }.count == 3)

        pool.suspend()
        for observer in observers.prefix(3) {
            try await waitUntil("suspension must close each admitted attach") { await !observer.transport.hasLiveAttachSession }
        }
        pool.resume()
        #expect(states.filter { $0.store != nil }.count == 3)
        for index in 0..<3 {
            try await start(try #require(states[index].store), observer: observers[index])
        }
        for index in 3..<6 {
            #expect(states[index].isAtCapacity)
            #expect(observers[index].createdStores == 0)
        }

        states[0].setVisible(
            false, owner: owners[0], retainWhenHidden: false, grid: "80x24", makeStore: observers[0].makeStore)
        try await waitUntil("releasing an Economy lease must free its attach") { await !observers[0].transport.hasLiveAttachSession }
        states[3].resumeIfVisible()
        let admitted = try #require(states[3].store)
        try await start(admitted, observer: observers[3])

        #expect(!states[3].isAtCapacity)
        #expect(observers[3].createdStores == 1)
        #expect(states.filter { $0.store != nil }.count == 3)
        #expect(observers[4].createdStores == 0)
        #expect(observers[5].createdStores == 0)
        #expect(await observers[3].transport.attachRequests.first?.viewer == .observe)
    }

    @Test func anEvictedUnpresentedStateCannotOpenFromALateAppearanceCallback() {
        let pool = ViewOnlyPool()
        let host = UUID()
        defer { pool.removeHost(host) }
        let keys = ids(host: host, count: 4).map { ViewOnlyPool.Key(id: $0, generation: 1, attempt: 0) }
        let stale = pool.state(for: keys[0])
        for key in keys.dropFirst() { _ = pool.state(for: key) }
        let observer = Observer()

        stale.setVisible(true, owner: UUID(), retainWhenHidden: true, grid: "80x24", makeStore: observer.makeStore)

        #expect(stale.isAtCapacity)
        #expect(stale.store == nil)
        #expect(observer.createdStores == 0)
    }

    @Test(arguments: AppPowerMode.allCases)
    func hostedPooledObserverRespectsItsInitialBackgroundPhaseAndReturnsToForeground(mode: AppPowerMode) async throws {
        let fixture = try HostedDashboardFixture(mode: mode, style: .fixed)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let state = LiveTerminalState()
        defer { state.stop() }
        let observer = Observer()
        let phase = HostedObserverPhase()
        let controller = UIHostingController(rootView: HostedObserverView(
            phase: phase, terminal: fixture.terminal, powerSettings: fixture.console.powerSettings,
            state: state, makeStore: observer.makeStore))
        try await withTestWindow(
            frame: CGRect(x: 0, y: 0, width: 700, height: 500), rootViewController: controller
        ) { _ in
            var inputTimeline: [String] = []
            try await waitUntil("the observer must mount with the explicit background environment") {
                controller.view.layoutIfNeeded()
                return phase.applied == .background
            }
            if mode == .performance {
                try await waitUntil("Performance must preserve initial background mounting behavior") {
                    state.store != nil && observer.createdStores == 1
                }
                #expect(state.hasVisibleOwners)
            } else {
                #expect(state.store == nil)
                #expect(!state.hasVisibleOwners)
                #expect(observer.createdStores == 0)
                #expect(await observer.transport.attachRequests.isEmpty)
            }
            inputTimeline.append("initial background: \(Self.attachInputDiagnostics(await observer.transport.attachInputs))")

            phase.value = .active
            try await waitUntil("becoming active must mount the observer without rebuilding its host") {
                controller.view.layoutIfNeeded()
                return phase.applied == .active && state.store != nil && state.hasVisibleOwners
            }
            let first = try #require(state.store)
            inputTimeline.append("active before paint: \(Self.attachInputDiagnostics(await observer.transport.attachInputs))")
            try await paintReadyObserver(first, observer: observer)
            inputTimeline.append("active after paint: \(Self.attachInputDiagnostics(await observer.transport.attachInputs))")
            #expect(observer.createdStores == 1)

            phase.value = .background
            try await waitUntil("the mounted observer must receive its next background transition") {
                phase.applied == .background
                    && (mode == .performance ? state.store === first : state.store == nil)
            }
            if mode == .batteryEconomy {
                try await waitUntil("Economy must close the observer before returning") {
                    await !observer.transport.hasLiveAttachSession
                }
            } else {
                #expect(await observer.transport.hasLiveAttachSession)
            }
            inputTimeline.append("second background: \(Self.attachInputDiagnostics(await observer.transport.attachInputs))")

            phase.value = .active
            try await waitUntil("the same mounted view must restore its observer after background") {
                controller.view.layoutIfNeeded()
                return phase.applied == .active && state.store != nil && state.hasVisibleOwners
            }
            let restored = try #require(state.store)
            if mode == .batteryEconomy {
                #expect(restored !== first)
                try await paintReadyObserver(restored, observer: observer)
                #expect(observer.createdStores == 2)
            } else {
                #expect(restored === first)
                #expect(observer.createdStores == 1)
            }
            #expect(await observer.transport.attachRequests.allSatisfy { $0.viewer == .observe && !$0.takeover })
            let inputs = await observer.transport.attachInputs
            let inputDescription = Self.attachInputDiagnostics(inputs)
            if !inputs.isEmpty {
                let requests = await observer.transport.attachRequests
                let geometries = requests.map { "\($0.cols)x\($0.rows), viewer=\($0.viewer)" }.joined(separator: "; ")
                inputTimeline.append("final active: \(inputDescription)")
                inputTimeline.append("attach requests: \(geometries)")
                Attachment.record(inputTimeline.joined(separator: "\n"), named: "hosted-observer-inputs.txt")
            }
            #expect(inputs.isEmpty, "Watch-only observer sent: \(inputDescription)")
        }
        state.stop()
        try await waitUntil("the hosted observer must close during cleanup") {
            await !observer.transport.hasLiveAttachSession
        }
    }

    @Test(arguments: [ConsoleDashboardView.Style.freeForm, .fixed])
    func hostedEconomyDashboardStartsVisibleCellsAndReassignsThemAfterScrolling(style: ConsoleDashboardView.Style) async throws {
        try await withDashboard(mode: .batteryEconomy, style: style) { fixture, controller, window in
            let expectedLiveCount = style == .fixed ? 2 : 1
            try await waitUntil("initial SwiftUI visibility must open an observer without scrolling") {
                controller.view.layoutIfNeeded()
                let active = await fixture.activeAttaches()
                return active.count == expectedLiveCount
            }
            let initial = Set(await fixture.activeAttaches().map(\.terminal))
            #expect(!initial.isEmpty)
            var readyScroll: UIScrollView?
            do {
                try await waitUntil("the Dashboard must finish laying out its scrollable inventory") {
                    controller.view.layoutIfNeeded()
                    readyScroll = Self.dashboardScroll(in: controller.view)
                    return readyScroll != nil
                }
            } catch {
                Attachment.record(Self.hostedDiagnostics(in: window), named: "dashboard-scroll-layout.txt")
                throw error
            }
            let scroll = try #require(readyScroll)
            let bottom = scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom

            scroll.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
            try await waitUntil("scrolling must close old observers and spend the slots on newly visible cells") {
                controller.view.layoutIfNeeded()
                let active = await fixture.activeAttaches()
                return active.count == expectedLiveCount
                    && Set(active.map(\.terminal)).isDisjoint(with: initial)
            }
            let atBottom = Set(await fixture.activeAttaches().map(\.terminal))

            scroll.setContentOffset(CGPoint(x: 0, y: -scroll.adjustedContentInset.top), animated: false)
            try await waitUntil("scrolling back must restore the initial visible observers") {
                controller.view.layoutIfNeeded()
                let active = await fixture.activeAttaches()
                return active.count == expectedLiveCount && Set(active.map(\.terminal)) == initial
            }
            #expect(initial.isDisjoint(with: atBottom))
            #expect(await fixture.scripted.attaches.allSatisfy { $0.params["observe"] == .bool(true) })
        }
    }

    @Test func hostedDashboardAppliesModeChangesAndPausesCellsUnderItsFullScreenViewer() async throws {
        try await withDashboard(mode: .performance, style: .fixed) { fixture, controller, window in
            try await waitUntil("Performance must open its four-cell budget") {
                controller.view.layoutIfNeeded()
                return await fixture.activeAttaches().count == 4
            }

            fixture.console.setPowerMode(.batteryEconomy)
            try await waitUntil("the mounted Dashboard must reduce its live budget immediately") {
                controller.view.layoutIfNeeded()
                return await fixture.activeAttaches().count == 2
            }
            fixture.console.setPowerMode(.performance)
            try await waitUntil("switching back must restore the live budget without remounting the Dashboard") {
                controller.view.layoutIfNeeded()
                return await fixture.activeAttaches().count == 4
            }
            fixture.console.setPowerMode(.batteryEconomy)
            try await waitUntil("Economy must settle before opening a full-screen viewer") {
                await fixture.activeAttaches().count == 2
            }
            var activationAttempts: [String] = []
            do {
                try await waitUntil("a visible cell must expose its full-screen action") {
                    controller.view.layoutIfNeeded()
                    if controller.presentedViewController != nil { return true }
                    let visibleFrame = UIAccessibility.convertToScreenCoordinates(controller.view.bounds, in: controller.view)
                    for element in accessibleElements(in: window)
                    where element.accessibilityHint == "Opens full screen"
                        && element.accessibilityFrame.intersects(visibleFrame) {
                        let activated: Bool
                        if let control = element as? UIControl {
                            control.sendActions(for: .touchUpInside)
                            activated = true
                        } else {
                            activated = element.accessibilityActivate()
                        }
                        if activationAttempts.count < 30 {
                            activationAttempts.append("\(type(of: element)): frame=\(element.accessibilityFrame), activated=\(activated)")
                        }
                        if activated { return true }
                    }
                    return false
                }
            } catch {
                let diagnostics = Self.hostedDiagnostics(in: window)
                    + "\nActivation attempts:\n" + activationAttempts.joined(separator: "\n")
                Attachment.record(diagnostics, named: "dashboard-fullscreen-accessibility.txt")
                throw error
            }
            try await waitUntil("the full-screen viewer must cover and stop the Dashboard's observers") {
                let active = await fixture.activeAttaches()
                return controller.presentedViewController != nil && active.count == 1
            }
            let presented = try #require(controller.presentedViewController)
            try await waitUntil("the full-screen viewer must offer Close") {
                ChangesViewTests.activate("Close", in: presented.view)
            }
            try await waitUntil("dismissing the viewer must restore the two visible Dashboard observers") {
                let active = await fixture.activeAttaches()
                return controller.presentedViewController == nil && active.count == 2
            }
            #expect(await fixture.scripted.attaches.allSatisfy { $0.params["observe"] == .bool(true) })
            for attach in await fixture.scripted.attaches {
                #expect(await attach.socket.frames(channel: attach.channel, kind: .data).isEmpty)
            }
        }
    }

    private func withDashboard(
        mode: AppPowerMode, style: ConsoleDashboardView.Style,
        body: (HostedDashboardFixture, UIHostingController<AnyView>, UIWindow) async throws -> Void
    ) async throws {
        let fixture = try HostedDashboardFixture(mode: mode, style: style)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        do {
            await fixture.scripted.setAttachPaint(Data("\u{1B}[2Jscreen\u{1B}[?9001l".utf8))
            fixture.console.setHosts([fixture.host])
            await fixture.console.resume()
            try await waitUntil("the scripted core must supply the dashboard inventory") {
                fixture.console.terminals.count == 24
            }
            fixture.layout.commit(Dictionary(uniqueKeysWithValues:
                fixture.console.terminals.enumerated().map { index, terminal in
                    (terminal.id, DashboardGridRect(x: 0, y: index * 20, w: 12, h: 20))
                }))
            let controller = UIHostingController(rootView: AnyView(
                ConsoleDashboardView(
                    console: fixture.console, hosts: fixture.hosts, terminal: fixture.terminal,
                    layout: fixture.layout, onDone: {})
                    .defaultAppStorage(fixture.defaults)
                    .environment(\.scenePhase, .active)
                    .environment(\.locale, Locale(identifier: "en_US"))))
            controller.safeAreaRegions = []
            try await withTestWindow(
                frame: CGRect(x: 0, y: 0, width: 900, height: 700), rootViewController: controller
            ) { window in
                try await body(fixture, controller, window)
            }
        } catch {
            await fixture.console.suspend()
            throw error
        }
        await fixture.console.suspend()
    }

    private static func dashboardScroll(in view: UIView) -> UIScrollView? {
        func all(_ root: UIView) -> [UIScrollView] {
            let own = (root as? UIScrollView).map { [$0] } ?? []
            return own + root.subviews.flatMap(all)
        }
        return all(view).filter {
            $0.contentSize.height + $0.adjustedContentInset.top + $0.adjustedContentInset.bottom > $0.bounds.height + 1
        }
            .max { $0.contentSize.height < $1.contentSize.height }
    }

    private static func attachInputDiagnostics(_ inputs: [TerminalAttachInput]) -> String {
        func bytes(_ data: Data) -> String {
            let hex = data.map { String(format: "%02x", $0) }.joined(separator: " ")
            return "hex=[\(hex)], escaped=\(String(reflecting: String(decoding: data, as: UTF8.self)))"
        }
        return inputs.map { input in
            switch input {
            case .keystrokes(let data): return "keystrokes(\(bytes(data)))"
            case .scroll(let data): return "scroll(\(bytes(data)))"
            case .resize(let cols, let rows): return "resize(\(cols)x\(rows))"
            }
        }.joined(separator: "; ")
    }

    @MainActor @Observable
    fileprivate final class HostedObserverPhase {
        var value: ScenePhase = .background
        var applied: ScenePhase?
    }

    private struct HostedObserverView: View {
        let phase: HostedObserverPhase
        let terminal: TerminalSettings
        let powerSettings: PowerModeSettings
        let state: LiveTerminalState
        let makeStore: () -> AttachTerminalStore

        var body: some View {
            DashboardLiveTerminal(
                terminal: terminal, powerSettings: powerSettings, remoteColumns: 80, remoteRows: 24,
                pooled: state, onReconnect: {}, makeStore: makeStore)
                .environment(\.scenePhase, phase.value)
                .task(id: phase.value) {
                    await Task.yield()
                    phase.applied = phase.value
                }
        }
    }

    private static func hostedDiagnostics(in window: UIWindow) -> String {
        var lines = ["window: frame=\(window.frame), bounds=\(window.bounds)"]
        for element in accessibleElements(in: window) {
            var line = "\(type(of: element)): label=\(element.accessibilityLabel ?? "nil"), hint=\(element.accessibilityHint ?? "nil"), frame=\(element.accessibilityFrame), traits=\(element.accessibilityTraits.rawValue), element=\(element.isAccessibilityElement)"
            if let view = element as? UIView {
                line += ", bounds=\(view.bounds), hidden=\(view.isHidden), alpha=\(view.alpha)"
            }
            if let scroll = element as? UIScrollView {
                line += ", content=\(scroll.contentSize), offset=\(scroll.contentOffset), inset=\(scroll.adjustedContentInset)"
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    @MainActor
    private final class HostedDashboardFixture {
        struct ActiveAttach {
            let terminal: String
        }

        let suiteName: String
        let defaults: UserDefaults
        let host: Host
        let hosts: HostStore
        let console: ConsoleStore
        let scripted: ScriptedCoreHost
        let terminal: TerminalSettings
        let layout: DashboardLayoutStore

        init(mode: AppPowerMode, style: ConsoleDashboardView.Style) throws {
            let suiteName = "dashboard-hosted-power-\(UUID().uuidString)"
            self.suiteName = suiteName
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            self.defaults = defaults
            let host = Host(address: "box.example", username: "dev", serverKind: .herdrCore)
            self.host = host
            defaults.set(style.rawValue, forKey: "dashboard.style")
            defaults.set(ConsoleDashboardView.Filter.all.rawValue, forKey: "dashboard.filter")
            let settings = PowerModeSettings(defaults: defaults)
            settings.select(mode)
            let terminals = (0..<24).map { index in
                JSONValue.object([
                    "address": .string("terminal-\(index)"), "cwd": .string("/work/app"), "state": .string("live"),
                    "argv": .array([.string("/bin/zsh")]), "keep": .bool(false), "title": .string("Terminal \(index)"),
                    "cols": .number(80), "rows": .number(24), "pid": .number(Double(100 + index)),
                ])
            }
            let scripted = ScriptedCoreHost(channel: .core(.init(id: "dashboard-core", terminals: terminals)))
            self.scripted = scripted
            hosts = HostStore(volatileHosts: [host])
            console = ConsoleStore(
                powerSettings: settings,
                makeCoreSession: { _ in
                    HerdrCoreHostSession(connect: { scripted.transport() }, keepalive: nil)
                },
                coreHostMemory: HerdrCoreHostMemory(defaults: defaults), herdrAppRename: false)
            terminal = TerminalSettings(
                themes: TerminalThemeSettings(defaults: defaults), zoom: TerminalZoomSettings(defaults: defaults),
                fonts: TerminalFontSettings(defaults: defaults), snippets: SnippetStore(defaults: defaults),
                edgeDock: EdgeDockSettings(defaults: defaults))
            layout = DashboardLayoutStore(defaults: defaults)
        }

        func activeAttaches() async -> [ActiveAttach] {
            var active: [ActiveAttach] = []
            for attach in await scripted.attaches {
                guard await !attach.socket.isClosed,
                    await attach.socket.frames(channel: attach.channel, kind: .close).isEmpty
                else { continue }
                if let terminal = attach.params["terminal"]?.stringValue {
                    active.append(ActiveAttach(terminal: terminal))
                }
            }
            return active
        }
    }

    private func show(
        _ state: LiveTerminalState, owner: UUID, observer: Observer, retainWhenHidden: Bool
    ) async throws {
        state.setVisible(
            true, owner: owner, retainWhenHidden: retainWhenHidden, grid: "80x24", makeStore: observer.makeStore)
        let store = try #require(state.store)
        try await start(store, observer: observer)
    }

    private func start(_ store: AttachTerminalStore, observer: Observer) async throws {
        store.viewDidResize(cols: 80, rows: 24)
        try await paintReadyObserver(store, observer: observer)
    }

    private func paintReadyObserver(_ store: AttachTerminalStore, observer: Observer) async throws {
        try await waitUntil("the observe attach must open") { await observer.transport.hasLiveAttachSession }
        #expect(await observer.transport.emitAttachOutput(Data("\u{1B}[2Jscreen".utf8)))
        try await waitUntil("first paint must make the observer live") { store.status == .live }
    }

    private func waitUntil(_ comment: Comment, condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(await condition(), comment)
    }

    @MainActor
    private final class Observer {
        let transport = ScriptedTransport()
        let output = CapturedOutput()
        private(set) var createdStores = 0

        func makeStore() -> AttachTerminalStore {
            createdStores += 1
            let transport = transport
            let store = AttachTerminalStore(target: .terminal("pane-0"), takeover: false, viewer: .observe, isViewed: true) {
                request, handler in
                let session = try await transport.attachTerminal(request)
                try await handler.runEndingSession(session)
            }
            store.feed.attach(output)
            return store
        }
    }

    @MainActor
    private final class CapturedOutput: TerminalByteSink {
        var chunks: [Data] = []

        func receive(_ data: Data) {
            chunks.append(data)
        }
    }
}
