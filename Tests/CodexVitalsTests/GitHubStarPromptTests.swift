import XCTest
@testable import CodexVitals

@MainActor
final class GitHubStarPromptTests: XCTestCase {
    func testPromptAppearsUntilUserMakesAChoice() {
        let defaults = makeDefaults()
        let model = GitHubStarPromptModel(defaults: defaults)

        model.presentIfNeeded()

        XCTAssertTrue(model.isPresented)
        XCTAssertFalse(defaults.bool(forKey: GitHubStarPromptModel.completedKey))
    }

    func testCompletingPromptPreventsFuturePresentation() {
        let defaults = makeDefaults()
        let model = GitHubStarPromptModel(defaults: defaults)

        model.presentIfNeeded()
        model.complete()
        model.presentIfNeeded()

        XCTAssertFalse(model.isPresented)
        XCTAssertTrue(defaults.bool(forKey: GitHubStarPromptModel.completedKey))
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "GitHubStarPromptTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }
}
