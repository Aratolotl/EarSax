import Foundation
import Observation

/// Checks the public repo on GitHub for a newer EarSax release: at launch, once a day, and on "Check for Updates".
/// It only reports; the download page opens in the browser. Sparkle, which also installs
/// updates, waits for Phase 3 signing and notarization. Each check is one request to GitHub, which sees the Mac's IP.
@Observable @MainActor
final class UpdateChecker {
    static let releasesPage = URL(string: "https://github.com/Aratolotl/EarSax")!
    private static let latestRelease = URL(string: "https://api.github.com/repos/Aratolotl/EarSax/releases/latest")!

    enum Status: Equatable {
        case notChecked, checking, upToDate
        case available(version: String, downloadPage: URL)
        case failed(String)
    }

    private(set) var status: Status = .notChecked
    let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"

    var checksAutomatically: Bool {
        didSet { preferences.set(checksAutomatically, forKey: "checksForUpdatesAutomatically") }
    }

    @ObservationIgnored private let preferences: UserDefaults
    @ObservationIgnored private var dailyCheck: Timer?

    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        checksAutomatically = preferences.object(forKey: "checksForUpdatesAutomatically") as? Bool ?? true
    }

    /// Call once at launch.
    func startAutomaticChecks() {
        dailyCheck?.invalidate()
        if checksAutomatically { Task { await check() } }
        dailyCheck = Timer.scheduledTimer(withTimeInterval: 24 * 60 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.checksAutomatically else { return }
                Task { await self.check() }
            }
        }
    }

    func check() async {
        guard status != .checking else { return }   // one check at a time (code review of Settings, finding 5)
        status = .checking
        var request = URLRequest(url: Self.latestRelease)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else {
                status = .failed(code == 404 ? "No release has been published yet." : "GitHub answered with code \(code).")
                earSaxLog.notice("Update check: GitHub answered \(code)")
                return
            }
            struct Release: Decodable { let tag_name: String; let html_url: URL }
            guard let release = try? JSONDecoder().decode(Release.self, from: data), release.html_url.scheme == "https" else {
                status = .failed("GitHub's answer couldn't be read.")
                earSaxLog.error("Update check: unreadable answer")
                return
            }
            let latest = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
            status = isNewerVersion(latest, than: currentVersion) ? .available(version: latest, downloadPage: release.html_url) : .upToDate
            earSaxLog.notice("Update check: latest \(latest), running \(currentVersion)")
        } catch {
            status = .failed("Couldn't reach GitHub.")
            earSaxLog.error("Update check failed: \(String(describing: error))")
        }
    }
}

/// "1.10.0" is newer than "1.9.2"; missing parts count as 0, anything that isn't a number counts as 0, and a pre-release
/// suffix ("1.2.0-beta.1") is ignored, so it never counts as newer than the release it leads to.
func isNewerVersion(_ candidate: String, than current: String) -> Bool {
    let parts = { (version: String) in
        (version.split(separator: "-").first ?? "").split(separator: ".").map { Int($0) ?? 0 }
    }
    let (a, b) = (parts(candidate), parts(current))
    for index in 0..<max(a.count, b.count) {
        let (x, y) = (index < a.count ? a[index] : 0, index < b.count ? b[index] : 0)
        if x != y { return x > y }
    }
    return false
}
