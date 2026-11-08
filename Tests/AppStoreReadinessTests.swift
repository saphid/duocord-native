import XCTest
@testable import DuocordNative

@MainActor
final class AppStoreReadinessTests: XCTestCase {
    func testDemoUsesFictionalTransportWithoutCredentials() async {
        let model = AppModel()
        model.startDemo()
        XCTAssertTrue(model.isMock)
        XCTAssertEqual(model.phase, .signedIn)
        XCTAssertNil(model.credentials)
        XCTAssertTrue(model.api is MockDiscord)
        XCTAssertEqual(model.selectedChannel, MockDiscord.generalChannel)
        for _ in 0..<30 where !model.store.isReady {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(model.store.isReady)
        XCTAssertEqual(model.store.me?.id, MockDiscord().me.id)
        model.signOut()
    }

    func testDemoExitPreservesStoredRealSession() {
        let model = AppModel()
        var cleared = false
        model.storedSessionClearer = { cleared = true }
        model.startDemo()
        model.signOut()
        XCTAssertFalse(cleared)
        XCTAssertFalse(model.isMock)
        XCTAssertNil(model.credentials)
        XCTAssertFalse(model.api is MockDiscord)
        XCTAssertNil(model.selectedChannel)
    }

    func testDemoNavigationDoesNotOverwriteRealNavigation() {
        let defaults = UserDefaults.standard
        let guild = defaults.object(forKey: "nav.guild")
        let channel = defaults.object(forKey: "nav.channel")
        defer {
            defaults.set(guild, forKey: "nav.guild")
            defaults.set(channel, forKey: "nav.channel")
        }
        defaults.set("12345", forKey: "nav.guild")
        defaults.set("67890", forKey: "nav.channel")
        let model = AppModel()
        model.startDemo()
        model.select(channel: MockDiscord.imageChannel)
        XCTAssertEqual(defaults.string(forKey: "nav.guild"), "12345")
        XCTAssertEqual(defaults.string(forKey: "nav.channel"), "67890")
        model.signOut()
    }

    func testStartingDemoAgainDoesNotReplaceSignedInSession() {
        let mock = MockDiscord()
        let model = AppModel(peopleAPI: mock)
        model.start()
        model.startDemo()
        XCTAssertTrue(model.api as? MockDiscord === mock)
        model.signOut()
    }
}
