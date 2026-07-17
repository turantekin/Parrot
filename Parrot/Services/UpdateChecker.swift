import Foundation

/// Knows whether a newer Parrot release exists on GitHub. Deliberately no
/// framework: one API call per day (or on demand), a numeric version compare
/// against the running bundle, and the DMG one click away. In-place silent
/// updates (Sparkle) are the upgrade path if the beta outgrows this.
@Observable @MainActor
final class UpdateChecker {
    static let shared = UpdateChecker()

    struct Release: Equatable {
        let version: String   // "0.12.0"
        let pageURL: String   // release page
        let dmgURL: String?   // direct DMG asset when present
    }

    /// Set when a newer, non-skipped release exists — drives the in-app banner.
    var available: Release?

    /// "dev" when running an unbundled `swift build` binary — those never nag.
    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    /// Launch-time check, throttled to once a day so the app never becomes
    /// a GitHub API client of note.
    func checkIfDue() {
        let last = UserDefaults.standard.double(forKey: "lastUpdateCheck")
        guard Date().timeIntervalSince1970 - last > 86_400 else { return }
        Task { await check() }
    }

    /// Fetches the newest non-draft release (prereleases count — every Parrot
    /// release is one right now). Returns it when newer than the running
    /// version, else nil. Also updates `available` for the banner, honoring
    /// "Skip this version".
    @discardableResult
    func check() async -> Release? {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastUpdateCheck")

        struct GHRelease: Decodable {
            struct Asset: Decodable {
                let name: String
                let browserDownloadUrl: String
            }
            let tagName: String
            let htmlUrl: String
            let draft: Bool
            let assets: [Asset]
        }

        var request = URLRequest(
            url: URL(string: "https://api.github.com/repos/turantekin/Parrot/releases?per_page=5")!)
        request.timeoutInterval = 10
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let releases = try? decoder.decode([GHRelease].self, from: data),
              let newest = releases.first(where: { !$0.draft }) else { return nil }

        let version = newest.tagName.hasPrefix("v")
            ? String(newest.tagName.dropFirst()) : newest.tagName
        guard Self.isNewer(version, than: Self.currentVersion) else {
            available = nil
            return nil
        }

        let release = Release(
            version: version,
            pageURL: newest.htmlUrl,
            dmgURL: newest.assets.first { $0.name.hasSuffix(".dmg") }?.browserDownloadUrl)

        // The banner respects "Skip this version"; the menu's explicit check
        // still returns the release so Check for Updates… always works.
        if UserDefaults.standard.string(forKey: "skippedVersion") != version {
            available = release
        }
        return release
    }

    /// Banner's "Skip" — stop showing this particular version.
    func skipAvailable() {
        if let version = available?.version {
            UserDefaults.standard.set(version, forKey: "skippedVersion")
        }
        available = nil
    }

    /// Numeric dotted compare ("0.11.2" style). Dev builds never update.
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard current != "dev" else { return false }
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
