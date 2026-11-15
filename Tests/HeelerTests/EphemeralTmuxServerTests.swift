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
}
