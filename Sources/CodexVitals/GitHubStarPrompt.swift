import Combine
import Foundation

@MainActor
final class GitHubStarPromptModel: ObservableObject {
    static let completedKey = "githubStarPromptCompleted"

    @Published private(set) var isPresented = false

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func presentIfNeeded() {
        guard !defaults.bool(forKey: Self.completedKey) else { return }
        isPresented = true
    }

    func complete() {
        defaults.set(true, forKey: Self.completedKey)
        isPresented = false
    }
}
