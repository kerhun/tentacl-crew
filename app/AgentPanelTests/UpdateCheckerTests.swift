import XCTest
import CryptoKit
@testable import AgentPanel

@MainActor
final class UpdateCheckerTests: XCTestCase {
    private final class Net: @unchecked Sendable {
        var files: [String: Data] = [:]
        private let lock = NSLock()
        private var seen: [String] = []
        var urls: [String] { lock.withLock { seen } }
        func get(_ url: URL) async throws -> Data {
            lock.withLock { seen.append(url.absoluteString) }
            guard let d = files[url.absoluteString] else { throw URLError(.notConnectedToInternet) }
            return d
        }
    }
    private let api = "https://api.github.com/repos/kerhun/tentacl-crew/releases"

    private func net(latest tag: String? = nil, list: [(String, Bool)] = []) -> Net {
        let n = Net()
        if let tag { n.files[api + "/latest"] = Data(###"{"tag_name":"\###(tag)","prerelease":false,"body":"## New\n- **Faster** start"}"###.utf8) }
        if !list.isEmpty {
            let items = list.map { #"{"tag_name":"\#($0.0)","prerelease":\#($0.1),"draft":false,"body":""}"# }.joined(separator: ",")
            n.files[api] = Data("[\(items)]".utf8)
        }
        return n
    }

    private func model(own: String?, _ n: Net, betas: Bool? = nil, dir: TempDir? = nil, started: StartLog = StartLog()) throws -> UpdateModel {
        let d = makeTestDefaults(prefix: "update-tests")
        if let betas { d.set(betas, forKey: UpdateModel.betasKey) }
        return UpdateModel(ownTag: own, defaults: d, get: { try await n.get($0) }, appFolder: URL(fileURLWithPath: "/Applications"),
                           workFolder: (try dir ?? TempDir()).url, start: { started.argv = $0 })
    }
    final class StartLog: @unchecked Sendable { var argv: [String]? }

    func testOwnTagFromVersionAndLabel() {
        XCTAssertEqual(UpdateChecker.ownTag(short: "1.0", label: "Beta 1"), "v1.0-beta.1")
        XCTAssertEqual(UpdateChecker.ownTag(short: "1.0", label: ""), "v1.0")
        XCTAssertNil(UpdateChecker.ownTag(short: "dev", label: nil))
    }

    func testNewerSameOlderAndBetaOrdering() async throws {
        for (own, latest, newer) in [("v1.0-beta.1", "v1.0-beta.2", true), ("v1.0-beta.2", "v1.0-beta.2", false), ("v1.0-beta.2", "v1.0-beta.1", false),
                                     ("v1.0-beta.9", "v1.0", true), ("v1.0", "v1.0-beta.9", false), ("v1.0", "v1.1-beta.1", true), ("v1.0-beta.2", "v1.0-beta.10", true)] {
            let m = try model(own: own, net(latest: latest), betas: false)
            await m.check()
            XCTAssertEqual(m.available?.tag, newer ? latest : nil, "\(own) → \(latest)")
        }
    }

    func testBetasOffAsksLatestOnlyAndBetasOnTakesTheFirstPublished() async throws {
        let n = net(latest: "v1.0", list: [("v1.1-beta.1", true), ("v1.0", false)])
        let off = try model(own: "v1.0-beta.1", n, betas: false); await off.check()
        XCTAssertEqual(off.available?.tag, "v1.0"); XCTAssertEqual(n.urls, [api + "/latest"])
        let on = try model(own: "v1.0-beta.1", n, betas: true); await on.check()
        XCTAssertEqual(on.available?.tag, "v1.1-beta.1"); XCTAssertTrue(on.available?.isBeta == true)
    }

    func testDraftsAreSkipped() async throws {
        let n = Net(); n.files[api] = Data(#"[{"tag_name":"v2.0","draft":true},{"tag_name":"v1.1","draft":false,"prerelease":false}]"#.utf8)
        let m = try model(own: "v1.0", n, betas: true); await m.check()
        XCTAssertEqual(m.available?.tag, "v1.1")
    }

    func testNetworkErrorIsQuiet() async throws {
        let m = try model(own: "v1.0", Net())
        var told = 0
        await m.check(onNew: { _ in told += 1 })
        XCTAssertNil(m.available); XCTAssertEqual(m.phase, .idle); XCTAssertNil(m.result); XCTAssertEqual(told, 0)
        await m.check(manual: true)
        XCTAssertEqual(m.result, "Could not check. Try again later.")
    }

    func testOneNotificationPerVersion() async throws {
        let n = net(latest: "v1.1")
        let m = try model(own: "v1.0", n)
        var told: [String] = []
        await m.check(onNew: { told.append($0.tag) }); await m.check(onNew: { told.append($0.tag) })
        XCTAssertEqual(told, ["v1.1"])
        n.files[api + "/latest"] = Data(#"{"tag_name":"v1.2"}"#.utf8)
        await m.check(onNew: { told.append($0.tag) })
        XCTAssertEqual(told, ["v1.1", "v1.2"])
    }

    func testSummaryIsPlainText() async throws {
        let m = try model(own: "v1.0", net(latest: "v1.1")); await m.check()
        XCTAssertEqual(m.available?.summary, "• Faster start")   // the leading "## New" heading is dropped (N340)
    }

    func testNotificationEventHasATitleAndIsOnByDefault() {
        XCTAssertTrue(NotificationPrefs().events.contains(.updateAvailable))
        XCTAssertFalse(NotificationEvent.updateAvailable.title.isEmpty)
    }

    // MARK: install

    private func release(_ n: Net, script: String = "#!/bin/bash\necho hi\n", sum: String? = nil) {
        let base = "https://github.com/kerhun/tentacl-crew/releases/download/v1.1/"
        n.files[base + "install.sh"] = Data(script.utf8)
        let hash = sum ?? SHA256.hash(data: Data(script.utf8)).map { String(format: "%02x", $0) }.joined()
        n.files[base + "SHA256SUMS"] = Data("\(String(repeating: "a", count: 64))  TentaclCrew-1.1.zip\n\(hash)  install.sh\n".utf8)
    }

    func testInstallStartsInstallShDetachedAndQuits() async throws {
        let n = net(latest: "v1.1"); release(n)
        let log = StartLog(); let m = try model(own: "v1.0", n, started: log)
        await m.check()
        var quit = 0
        await m.install(quit: { quit += 1 })
        let argv = try XCTUnwrap(log.argv)
        XCTAssertEqual(argv.prefix(2), ["/usr/bin/nohup", "/bin/bash"])
        XCTAssertEqual(Array(argv.dropFirst(3)), ["--version", "v1.1", "--dir", "/Applications", "--yes", "--open"])
        XCTAssertEqual(try String(contentsOfFile: argv[2], encoding: .utf8), "#!/bin/bash\necho hi\n")
        XCTAssertEqual(quit, 1)
    }

    func testInstallRefusesWhenTheSumDoesNotMatch() async throws {
        let n = net(latest: "v1.1"); release(n, sum: String(repeating: "0", count: 64))
        let log = StartLog(); let m = try model(own: "v1.0", n, started: log)
        await m.check()
        var quit = 0
        await m.install(quit: { quit += 1 })
        XCTAssertNil(log.argv); XCTAssertEqual(quit, 0)
        guard case .failed(let text) = m.phase else { return XCTFail("expected failed") }
        XCTAssertTrue(text.contains("nothing was installed"))
    }

    func testInstallDoesNothingWithoutAnUpdate() async throws {
        let log = StartLog(); let m = try model(own: "v1.0", net(latest: "v1.0"), started: log)
        await m.check(); await m.install(quit: { XCTFail("quit") })
        XCTAssertNil(log.argv)
    }

    /// N340: the last successful check is kept in defaults and shown as "checked … ago"; a failed check says so; none yet says so.
    func testLastCheckTimeIsStoredAndShown() async throws {
        let d = makeTestDefaults(prefix: "update-last-check")
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let n = net(latest: "v1.0")
        let make = { UpdateModel(ownTag: "v1.0", defaults: d, get: { try await n.get($0) }, now: { clock }) }
        let m = make()
        XCTAssertEqual(m.checkedText, "not checked yet")
        await m.check()
        XCTAssertEqual(m.lastCheck, clock)
        XCTAssertEqual(m.checkedText, "checked just now")
        clock += 600
        XCTAssertEqual(m.checkedText, "checked 10 min ago")
        let again = make()   // a restart reads it back
        XCTAssertEqual(again.lastCheck, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(again.checkedText, "checked 10 min ago")
        n.files = [:]
        await again.check()
        XCTAssertEqual(again.checkedText, "could not check")
        XCTAssertEqual(make().checkedText, "could not check")
        XCTAssertEqual(again.lastCheck, Date(timeIntervalSince1970: 1_800_000_000), "a failed check keeps the last good time")
    }

    /// N340: the summary starts with the list, not a repeated "What's new" heading.
    func testSummaryDropsTheLeadingHeading() {
        let r = ReleaseInfo(tag: "v1.0-beta.2", notes: "## What's new\n\n- In-app updates\n- Fewer sounds", isBeta: true)
        XCTAssertFalse(r.summary.contains("What's new"))
        XCTAssertTrue(r.summary.hasPrefix("In-app updates") || r.summary.hasPrefix("• In-app updates") || r.summary.hasPrefix("- In-app updates"), r.summary)
        XCTAssertEqual(ReleaseInfo.withoutLeadingHeading("# Title\n## Sub\ntext\n## Later"), "text\n## Later")
        XCTAssertEqual(ReleaseInfo.withoutLeadingHeading("#hashtag first"), "#hashtag first")
    }
}
