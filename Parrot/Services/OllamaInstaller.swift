import AppKit
import Security

/// Installs the official Ollama app from inside Parrot. The sandbox lets us
/// write to Downloads and open apps, not write to /Applications, so: fetch
/// the zip into Downloads, unpack it there, check it's really signed by
/// Ollama, and open it. Files a sandboxed app writes are quarantined, so
/// macOS asks "downloaded from the Internet. Open?" once. That's the right
/// place for the decision.
@MainActor
@Observable
final class OllamaInstaller {
    enum State: Equatable {
        case idle, downloading(progress: Double?), unpacking, verifying, opening, opened, failed(String)
    }

    private(set) var state: State = .idle

    static let downloadURL = URL(string: "https://ollama.com/download/Ollama-darwin.zip")!
    static let websiteURL = URL(string: "https://ollama.com/download")!
    /// From `codesign -dv` on the official download (plan Task 6, Step 1).
    nonisolated static let bundleID = "com.electron.ollama"
    nonisolated static let teamID = "3MU9H2V9Y9"
    nonisolated static var requirement: String {
        "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\""
    }

    var isBusy: Bool {
        switch state {
        case .downloading, .unpacking, .verifying, .opening: true
        default: false
        }
    }

    /// Ollama.app wherever Launch Services knows it: Applications, Downloads…
    static func installedAppURL() -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    func openInstalled() async {
        guard let app = Self.installedAppURL() else { return }
        await open(app)
    }

    func install() async {
        guard !isBusy else { return }
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let zip = downloads.appendingPathComponent("Ollama-darwin.zip")
        let app = downloads.appendingPathComponent("Ollama.app")
        do {
            state = .downloading(progress: nil)
            try await download(to: zip)
            state = .unpacking
            try? FileManager.default.removeItem(at: app)
            try await Task.detached { try Self.unzip(zip, into: downloads) }.value
            try? FileManager.default.removeItem(at: zip)
            state = .verifying
            guard Self.isSignedByOllama(app) else {
                try? FileManager.default.removeItem(at: app)
                state = .failed("That download didn't look right. Get it from ollama.com instead.")
                return
            }
            await open(app)
        } catch {
            try? FileManager.default.removeItem(at: zip)
            state = .failed("Couldn't install Ollama. Get it from ollama.com instead.")
        }
    }

    private func open(_ app: URL) async {
        state = .opening
        do {
            _ = try await NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
            state = .opened
        } catch {
            state = .failed("Couldn't open Ollama. Open it from your Downloads folder.")
        }
    }

    private func download(to file: URL) async throws {
        let relay = ProgressRelay { [weak self] fraction in
            Task { @MainActor in self?.state = .downloading(progress: fraction) }
        }
        let (temporary, response) = try await URLSession.shared.download(from: Self.downloadURL, delegate: relay)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: temporary, to: file)
    }

    nonisolated private static func unzip(_ zip: URL, into directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zip.path, directory.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    /// True only for a valid signature from Ollama's Developer ID team.
    nonisolated static func isSignedByOllama(_ app: URL) -> Bool {
        var code: SecStaticCode?
        var requirementRef: SecRequirement?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(requirement as CFString, [], &requirementRef) == errSecSuccess,
              let requirementRef else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures)
        return SecStaticCodeCheckValidity(code, flags, requirementRef) == errSecSuccess
    }
}

/// Forwards a download task's progress. The async download API hands the
/// task to its delegate once, on creation; we watch its Progress from there.
private final class ProgressRelay: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Double) -> Void
    private var observation: NSKeyValueObservation?

    init(_ onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        observation = task.progress.observe(\.fractionCompleted) { [onProgress] progress, _ in
            onProgress(progress.fractionCompleted)
        }
    }
}
