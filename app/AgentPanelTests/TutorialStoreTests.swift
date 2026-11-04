import XCTest
@testable import AgentPanel

/// N311: `tutorial.v1` in UserDefaults: read, write, the format, a changed tour version, reset.
final class TutorialStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var store: TutorialStore!
    override func setUp() { defaults = makeTestDefaults(prefix: "tutorial-store"); store = TutorialStore(defaults: defaults) }

    func testEmptyIsNotStartedWithTheOfferOn() {
        let save = store.load()
        XCTAssertEqual(save.progress(.dashboard).state, .notStarted)
        XCTAssertTrue(save.offerOnNewScreen)
        XCTAssertEqual(save.seenScreens, [])
    }

    func testWriteAndRead() {
        var save = TutorialSave()
        save.tours[.tasks] = TutorialProgress(state: .inProgress, step: 3, version: 1)
        save.tours[.dashboard] = TutorialProgress(state: .finished, step: 0, version: 1)
        save.offerOnNewScreen = false
        save.seenScreens = ["plan"]
        store.save(save)
        XCTAssertEqual(store.load(), save)
    }

    func testFormatIsTheSpecs() throws {
        var save = TutorialSave()
        save.tours[.plan] = TutorialProgress(state: .skipped, step: 1, version: 1)
        save.seenScreens = ["plan"]
        store.save(save)
        let data = try XCTUnwrap(defaults.data(forKey: "tutorial.v1"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["offerOnNewScreen"] as? Bool, true)
        XCTAssertEqual(json["seenScreens"] as? [String], ["plan"])
        let plan = try XCTUnwrap(json["plan"] as? [String: Any])
        XCTAssertEqual(plan["state"] as? String, "skipped")
        XCTAssertEqual(plan["step"] as? Int, 1)
        XCTAssertEqual(plan["version"] as? Int, 1)
    }

    func testAnOlderVersionStartsThatTourOver() throws {
        let json: [String: Any] = ["dashboard": ["state": "finished", "step": 0, "version": 0], "tasks": ["state": "finished", "step": 0, "version": 1]]
        defaults.set(try JSONSerialization.data(withJSONObject: json), forKey: TutorialStore.key)
        let save = store.load()
        XCTAssertEqual(save.progress(.dashboard).state, .notStarted)
        XCTAssertEqual(save.progress(.tasks).state, .finished)
    }

    func testBadDataAndOutOfRangeSteps() throws {
        defaults.set(Data("nope".utf8), forKey: TutorialStore.key)
        XCTAssertEqual(store.load(), TutorialSave())
        let json: [String: Any] = ["plan": ["state": "inProgress", "step": 99, "version": 1]]
        defaults.set(try JSONSerialization.data(withJSONObject: json), forKey: TutorialStore.key)
        XCTAssertEqual(store.load().progress(.plan).step, 3)
    }

    func testResetKeepsTheOfferSetting() {
        var save = TutorialSave()
        save.tours[.tasks] = TutorialProgress(state: .finished, step: 0, version: 1)
        save.offerOnNewScreen = false
        save.seenScreens = ["tasks"]
        store.save(save)
        store.reset()
        let after = store.load()
        XCTAssertEqual(after.progress(.tasks).state, .notStarted)
        XCTAssertEqual(after.seenScreens, [])
        XCTAssertFalse(after.offerOnNewScreen)
    }
}
