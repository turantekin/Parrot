import AVFoundation
import Foundation
import SwiftData

@MainActor
@Observable
final class DictationController {
    enum Phase: Equatable {
        case idle
        case listening
        case working
        case copied
        case inserted
        case refinedReady
        case failed(String)

        var hud: String {
            switch self {
            case .idle: ""
            case .listening: "Listening…"
            case .working: "Transcribing…"
            case .copied: "Copied — press ⌘V"
            case .inserted: "Pasted"
            case .refinedReady: "Refined copy ready — press ⌘V again"
            case .failed(let message): message
            }
        }
    }

    private(set) var phase: Phase = .idle
    private var recorder: AVAudioRecorder?
    private var fileURL: URL?
    private var startedAt: Date?
    private var copiedAt: Date?
    private var pasteboardAtCopy = 0
    private var hideTask: Task<Void, Never>?
    /// On-device file transcribe. Set from RecordingManager so we reuse WhisperKit.
    var transcribeLocal: ((URL) async throws -> String)?
    /// Call capture already owns the mic — dictation must wait.
    var isCallRecording: () -> Bool = { false }
    weak var modelContext: ModelContext?
    private var lastSaved: DictationNote?
    private var lastTranscript: String?
    private var session: Session = .none

    private enum Session {
        case none
        case hold
        case handsFree
    }

    var isActive: Bool {
        if case .idle = phase { return false }
        return true
    }

    var isHolding: Bool { session == .hold }

    func toggle() { toggleHandsFree() }

    /// Wispr Flow hands-free: press once to listen, press again to stop and paste.
    func toggleHandsFree() {
        switch phase {
        case .listening:
            session = .none
            Task { await stopAndTranscribe() }
        case .working:
            return
        default:
            session = .handsFree
            start()
        }
    }

    /// Wispr Flow push-to-talk: hold to listen, release to stop and paste.
    func beginHold() {
        if case .working = phase { return }
        if case .listening = phase { return }
        session = .hold
        start()
    }

    func endHold() {
        guard session == .hold, case .listening = phase else { return }
        session = .none
        Task { await stopAndTranscribe() }
    }

    func pasteLast() {
        let text = (lastTranscript ?? lastSaved?.text ?? storedLast())?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else {
            phase = .failed("Nothing to paste yet.")
            scheduleHide()
            return
        }
        phase = FocusText.deliver(text) == .inserted ? .inserted : .copied
        scheduleHide()
    }

    private func storedLast() -> String? {
        UserDefaults.standard.string(forKey: FeatureProcessing.lastDictationKey)
    }

    private func start() {
        if isCallRecording() {
            session = .none
            phase = .failed("Dictation waits until the call stops — the mic is in the meeting.")
            scheduleHide()
            return
        }
        guard recorder == nil else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parrot-dictation-\(UUID().uuidString).caf")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        do {
            let rec = try AVAudioRecorder(url: url, settings: settings)
            rec.record()
            recorder = rec
            fileURL = url
            startedAt = .now
            lastSaved = nil
            phase = .listening
        } catch {
            session = .none
            phase = .failed("Couldn't start dictation — \(error.localizedDescription)")
            scheduleHide()
        }
    }

    private func stopAndTranscribe() async {
        recorder?.stop()
        recorder = nil
        guard let url = fileURL else {
            phase = .idle
            return
        }
        phase = .working
        let mode = FeatureProcessing.dictation
        do {
            let first = try await transcribe(
                url: url, preferCloud: mode == .cloud, allowLocal: mode.runsLocalModel)
            pasteboardAtCopy = ClipboardOut.changeCount
            copiedAt = .now
            phase = FocusText.deliver(first) == .inserted ? .inserted : .copied
            pasteboardAtCopy = ClipboardOut.changeCount
            persist(text: first)
            if mode == .hybrid {
                Task { await self.refineIfStillOurs(url: url, original: first) }
            }
            scheduleHide()
        } catch {
            phase = .failed(error.localizedDescription)
            scheduleHide()
        }
    }

    private func refineIfStillOurs(url: URL, original: String) async {
        do {
            let refined = try await transcribe(url: url, preferCloud: true, allowLocal: false)
            guard refined != original, !refined.isEmpty else { return }
            let withinGrace = Date.now.timeIntervalSince(copiedAt ?? .now) < 3
            let untouched = ClipboardOut.changeCount == pasteboardAtCopy
            if withinGrace && untouched {
                phase = FocusText.deliver(refined) == .inserted ? .inserted : .copied
                persist(text: refined)
            } else {
                phase = .refinedReady
            }
            scheduleHide()
        } catch {
            NSLog("Parrot: dictation refine failed — \(error.localizedDescription)")
        }
    }

    private func transcribe(url: URL, preferCloud: Bool, allowLocal: Bool = true) async throws -> String {
        if preferCloud {
            guard CloudVendor.selected != .custom, CloudVendor.selected.speechKey() != nil else {
                throw TextRewriter.RewriteError.notConfigured("Add a cloud vendor key in Settings → API Keys.")
            }
            let polished = try await HybridRefiner.polishTracks(
                systemPath: nil, micPath: url.path, smart: true)
            let text = polished.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return text }
            throw TextRewriter.RewriteError.badResponse("Cloud dictation returned empty text.")
        }
        if allowLocal, let transcribeLocal {
            return try await transcribeLocal(url)
        }
        throw TextRewriter.RewriteError.notConfigured("On-device dictation needs a loaded Whisper model.")
    }

    private func persist(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lastTranscript = trimmed
        UserDefaults.standard.set(trimmed, forKey: FeatureProcessing.lastDictationKey)
        guard let modelContext else { return }
        let duration = Date.now.timeIntervalSince(startedAt ?? .now)
        if let lastSaved {
            lastSaved.text = trimmed
            lastSaved.duration = max(0, duration)
        } else {
            let note = DictationNote(text: trimmed, duration: max(0, duration))
            modelContext.insert(note)
            lastSaved = note
        }
        try? modelContext.save()
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            if case .listening = self.phase { return }
            self.phase = .idle
        }
    }
}
