import Foundation

/// Personal build. Some tools start one tmux server per short-lived session,
/// on a socket named `<prefix><id>` that goes away for good when the session
/// ends. A Server record for one would then read "Reconnecting…" forever, so
/// once its server has been found not running on two looks in a row, the
/// sweeper turns the record off as the Servers switch does (ADR 0047): the
/// record goes and its Host stays. The prefixes come from the build's
/// `HeelerEphemeralTmuxSocketPrefixes` Info.plist array; with none, it does
/// nothing.
@MainActor
final class EphemeralTmuxServerSweeper {
    nonisolated static let infoKey = "HeelerEphemeralTmuxSocketPrefixes"
    nonisolated static let socketPrefixes: [String] =
        (Bundle.main.object(forInfoDictionaryKey: infoKey) as? [String])?.filter { !$0.isEmpty } ?? []

    /// The prefix `socketName` starts with, nil when it is not ephemeral.
    nonisolated static func prefix(of socketName: String, among prefixes: [String] = socketPrefixes) -> String? {
        prefixes.first { socketName.hasPrefix($0) && socketName.count > $0.count }
    }

    private let hostStore: HostStore
    private let console: ConsoleStore
    private let dependencies: HostRemovalDependencies
    private let removal: HostRemovalStore
    /// Found not running on the last look; gone for good if still so now.
    private var suspected: Set<Host.ID> = []
    private var task: Task<Void, Never>?

    init(hostStore: HostStore, console: ConsoleStore, dependencies: HostRemovalDependencies) {
        self.hostStore = hostStore
        self.console = console
        self.dependencies = dependencies
        removal = HostRemovalStore(store: hostStore)
    }

    static func isEphemeral(_ host: Host) -> Bool {
        host.serverKind == .tmux && prefix(of: host.tmuxSocketName) != nil
    }

    func start(every interval: Duration = .seconds(20)) {
        guard task == nil, !Self.socketPrefixes.isEmpty else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                await self?.sweep()
            }
        }
    }

    /// One look. Returns the records it turned off.
    @discardableResult
    func sweep() async -> [Host.ID] {
        var notRunning: Set<Host.ID> = []
        for host in hostStore.hosts where Self.isEphemeral(host) {
            if console.hostStatuses[host.id]?.findsTmuxServerNotRunning == true {
                notRunning.insert(host.id)
            }
        }
        let gone = notRunning.intersection(suspected)
        suspected = notRunning.subtracting(gone)
        var removed: [Host.ID] = []
        for id in gone {
            guard let record = hostStore.hosts.first(where: { $0.id == id }), !dependencies.inFlight.contains(id)
            else { continue }
            let hasKey = dependencies.hasNotificationKey(id)
            await removal.confirmRemoval(
                HostRemovalRequest(
                    hosts: [record], deletesNotificationKey: hasKey,
                    leavesNotificationsBehind: hasKey && !dependencies.isConnected(id),
                    turnsOffServer: record.serverKey?.label ?? record.serverKind.displayName),
                dependencies: dependencies)
            if !hostStore.hosts.contains(where: { $0.id == id }) { removed.append(id) }
        }
        return removed
    }
}

extension EventsSessionStatus {
    /// Personal build. A tmux Host whose run stopped because its server was
    /// closed (`TmuxHostSession.notRunningLookLimit`): it reads "Not running",
    /// quietly, rather than Can't Connect.
    var isStoppedTmuxServer: Bool {
        if case .failed(.tmuxServerNotRunning) = self { true } else { false }
    }

    /// Still looking for the tmux server, or stopped after it found none.
    var findsTmuxServerNotRunning: Bool {
        switch self {
        case .reconnecting(_, _, .tmuxServerNotRunning), .failed(.tmuxServerNotRunning): true
        default: false
        }
    }
}
