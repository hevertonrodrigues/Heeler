import Foundation
import Testing

@testable import Heeler

@Suite struct EphemeralTmuxServerTests {
    private let prefixes = ["session-"]

    @Test func ephemeralSocketsShortenToTheirFirstCharacters() {
        #expect(HostServerKey.shortName("session-0123456789abcdef", kind: .tmux, prefixes: prefixes) == "01234")
        #expect(EphemeralTmuxServerSweeper.prefix(of: "session-01", among: prefixes) == "session-")
    }

    @Test func otherNamesStayWhole() {
        #expect(HostServerKey.shortName("work", kind: .tmux, prefixes: prefixes) == "work")
        #expect(HostServerKey.shortName("session-", kind: .tmux, prefixes: prefixes) == "session-")
        #expect(HostServerKey.shortName("session-0123", kind: .herdrCore, prefixes: prefixes) == "session-0123")
        #expect(EphemeralTmuxServerSweeper.prefix(of: "work", among: prefixes) == nil)
        #expect(HostServerKey(kind: .tmux, name: "default").label == "tmux")
    }

    @Test func herdrCoreReadsShort() {
        #expect(ServerKind.herdrCore.displayName == "hc")
    }

    private static let stopped = TransportError.tmuxServerNotRunning(socketName: "work")

    private func session() -> TmuxHostSession {
        TmuxHostSession(
            storedPaths: nil,
            connect: { _ in throw Self.stopped },
            reconnectPolicy: ReconnectPolicy(initialDelay: .milliseconds(5), multiplier: 1, maxDelay: .milliseconds(5)),
            keepalive: nil)
    }

    @Test func aClosedServerStopsTheRunAfterAFewLooks() async throws {
        let session = session()
        var updates = session.updates.makeAsyncIterator()
        await session.resume()
        var reconnects = 0
        while let update = await updates.next() {
            guard case .status(let status) = update else { continue }
            if case .reconnecting = status { reconnects += 1 }
            if case .failed(let failure) = status {
                #expect(failure == Self.stopped)
                break
            }
        }
        #expect(reconnects == TmuxHostSession.notRunningLookLimit - 1)
        #expect(EventsSessionStatus.failed(Self.stopped).isStoppedTmuxServer)
        #expect(EventsSessionStatus.failed(Self.stopped).findsTmuxServerNotRunning)
        await session.end()
    }

    @Test func stopConnectingOnAClosedServerLeavesItStoppedNotPaused() async throws {
        let session = TmuxHostSession(
            storedPaths: nil,
            connect: { _ in throw Self.stopped },
            reconnectPolicy: ReconnectPolicy(initialDelay: .seconds(30), multiplier: 1, maxDelay: .seconds(30)),
            keepalive: nil)
        var updates = session.updates.makeAsyncIterator()
        await session.resume()
        while let update = await updates.next() {
            if case .status(.reconnecting) = update { break }
        }
        await session.cancelConnecting()
        var next: EventsSessionStatus?
        while let update = await updates.next() {
            if case .status(let status) = update { next = status; break }
        }
        #expect(next == .failed(Self.stopped))
        await session.end()
    }
}
