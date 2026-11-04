import XCTest
@testable import AgentPanel

final class LocalPageFinderTests: XCTestCase {
    private func found(_ text: String) -> String? { LocalPageFinder.find(in: text)?.url.absoluteString }

    func testViteLocalLine() {
        let screen = """
        > shop@0.1.0 dev
        > vite

          VITE v5.4.2  ready in 312 ms

          ➜  Local:   http://localhost:5173/
          ➜  Network: http://192.168.1.20:5173/
          ➜  press h + enter to show help
        """
        XCTAssertEqual(found(screen), "http://localhost:5173/", "the network address is not local")
    }

    func testNextLocalLine() {
        let screen = "$ npm run dev\n   ▲ Next.js 14.2.3\n   - Local:        http://localhost:3000\n   - Network:      http://10.0.0.4:3000\n\n ✓ Ready in 1.8s"
        let page = LocalPageFinder.find(in: screen)
        XCTAssertEqual(page?.url.absoluteString, "http://localhost:3000/")
        XCTAssertEqual(page?.command, "npm run dev")
    }

    func testExpoWebLine() {
        let screen = "npx expo start --web\nStarting Metro Bundler\n› Metro waiting on exp://192.168.1.5:8081\n› Web is waiting on http://localhost:8081"
        let page = LocalPageFinder.find(in: screen)
        XCTAssertEqual(page?.url.absoluteString, "http://localhost:8081/")
        XCTAssertEqual(page?.command, "npx expo start")
    }

    func testTheNewestOfSeveralWins() {
        let screen = "Local: http://localhost:5173/\nPort 5173 is in use, trying another one...\nLocal: http://127.0.0.1:5174/settings\nsomething else"
        XCTAssertEqual(found(screen), "http://127.0.0.1:5174/settings")
        XCTAssertEqual(found("first http://localhost:3000/a then http://localhost:3001/b"), "http://localhost:3001/b", "the last on a line too")
    }

    func testZeroAddressIsReadAsLocalhostAndABareHostNeedsAPort() {
        XCTAssertEqual(found("ready - started server on 0.0.0.0:3000"), "http://localhost:3000/")
        XCTAssertNil(found("listening on localhost"), "a bare host without a port is a word")
        XCTAssertEqual(found("Serving HTTP on 127.0.0.1 port 8000 (http://127.0.0.1:8000/) ..."), "http://127.0.0.1:8000/", "the closing bracket is not part of it")
        XCTAssertEqual(found("Open http://localhost:4321/docs."), "http://localhost:4321/docs", "trailing punctuation is dropped")
    }

    func testNoneFound() {
        XCTAssertNil(LocalPageFinder.find(in: ""))
        XCTAssertNil(LocalPageFinder.find(in: "Building...\nSee https://vitejs.dev/config/ and http://192.168.1.2:5173/"))
        XCTAssertNil(found("mylocalhost:3000 is not localhost"))
    }

    func testANSICodesAreStripped() {
        let screen = "\u{1B}[32m  ➜\u{1B}[39m  \u{1B}[1mLocal\u{1B}[22m:   \u{1B}[36mhttp://localhost:\u{1B}[1m5173\u{1B}[22m/\u{1B}[39m\n\u{1B}]8;;http://x\u{07}link\u{1B}]8;;\u{07}"
        XCTAssertEqual(found(screen), "http://localhost:5173/")
        XCTAssertEqual(LocalPageFinder.stripANSI("\u{1B}[2K\u{1B}[1Gok"), "ok")
    }

    func testCommandIsTheNearestAboveTheAddress() {
        let screen = "pnpm build\ndone\nBash(pnpm dev)\n  ⎿  Local: http://localhost:5173/"
        XCTAssertEqual(LocalPageFinder.find(in: screen)?.command, "pnpm dev")
        XCTAssertNil(LocalPageFinder.find(in: "Local: http://localhost:5173/")?.command)
    }
}

final class LoopbackPortTests: XCTestCase {
    /// Listens on an ephemeral 127.0.0.1 port; returns (fd, port).
    private func listen() -> (Int32, UInt16) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); a.sin_family = sa_family_t(AF_INET); a.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafeMutablePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        Darwin.listen(fd, 4)
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        return (fd, UInt16(bigEndian: a.sin_port))
    }

    func testOpenPortIsSeenAndClosedPortIsNot() async {
        let (fd, port) = listen()
        let url = URL(string: "http://127.0.0.1:\(port)/")!
        let open = await LoopbackPort.isOpen(url)
        XCTAssertTrue(open)
        let viaName = await LoopbackPort.isOpen(URL(string: "http://localhost:\(port)/")!)
        XCTAssertTrue(viaName, "localhost tries 127.0.0.1 too")
        close(fd)
        let after = await LoopbackPort.isOpen(url)
        XCTAssertFalse(after)
    }

    func testOtherHostsAreNeverConnectedTo() async {
        let (fd, port) = listen()
        defer { close(fd) }
        let other = await LoopbackPort.isOpen(URL(string: "http://192.168.1.20:\(port)/")!)
        XCTAssertFalse(other)
    }

    @MainActor func testPageNeedsAnOpenPortAndIsDroppedWhenItCloses() async {
        let (fd, port) = listen()
        let text = "Local: http://127.0.0.1:\(port)/"
        let watch = TerminalPageWatch()
        await watch.consider(pane: "p1", text: "Local: http://127.0.0.1:1/")
        XCTAssertNil(watch.pages["p1"], "a quoted URL whose port is closed is no page")
        await watch.consider(pane: "p1", text: text)
        XCTAssertEqual(watch.pages["p1"]?.url.port, Int(port))
        await watch.consider(pane: "p1", text: "● Update Hero.tsx")
        await watch.recheck()
        XCTAssertNotNil(watch.pages["p1"], "found earlier, port still open: kept")
        close(fd)
        await watch.recheck()
        XCTAssertNil(watch.pages["p1"], "server stopped: dropped on the next cycle")
    }

    @MainActor func testInjectedCheck() async {
        let watch = TerminalPageWatch(isOpen: { $0.port == 5173 })
        await watch.consider(pane: "a", text: "http://localhost:3000/")
        await watch.consider(pane: "b", text: "http://localhost:5173/")
        XCTAssertNil(watch.pages["a"])
        XCTAssertNotNil(watch.pages["b"])
    }
}
