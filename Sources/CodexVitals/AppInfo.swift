import Foundation

enum AppInfo {
    static let name = "Codex Vitals"
    static let homepageURL = URL(string: "https://ramterstudio.com/codex-vitals/")!
    static let repositoryURL = URL(string: "https://github.com/Joowonoil/Codex-Vitals")!
    static let releasesURL = URL(string: "https://github.com/Joowonoil/Codex-Vitals/releases")!
    static let studioURL = URL(string: "https://ramterstudio.com")!
    static let feedbackURL = URL(string: "mailto:ramterstudio@gmail.com?subject=Codex%20Vitals%20Feedback")!

    static var versionText: String {
        guard let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              !version.isEmpty else {
            return "Unknown"
        }
        return version.hasPrefix("v") ? version : "v\(version)"
    }
}
