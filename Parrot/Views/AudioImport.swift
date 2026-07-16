import SwiftUI
import UniformTypeIdentifiers

/// Shared bits for importing an existing recording as a new meeting: the file
/// types we accept, a window-wide drag-and-drop target with a drop overlay, and
/// the small "Transcribing…" banner shown while an import runs.
enum AudioImport {
    /// `.audio` is the umbrella UTI covering m4a/mp3/wav/aac/caf/aiff; WhisperKit
    /// decodes and resamples all of them on-device.
    static let contentTypes: [UTType] = [.audio]
}

extension URL {
    /// True when a dropped file looks like something we can transcribe.
    var isImportableAudio: Bool {
        guard let type = UTType(filenameExtension: pathExtension) else { return false }
        return type.conforms(to: .audio)
    }
}

// MARK: - Drag & drop

/// Full-window drag-and-drop for audio import. Highlights with an accent-tinted
/// drop overlay while a file hovers. `enabled` is false during a live recording (both
/// share one WhisperKit) so we don't invite a drop we'd have to refuse.
struct AudioImportDrop: ViewModifier {
    var enabled: Bool = true
    let onImport: (URL) -> Void
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .dropDestination(for: URL.self) { urls, _ in
                guard enabled, let url = urls.first(where: { $0.isImportableAudio }) else { return false }
                onImport(url)
                return true
            } isTargeted: { targeted = enabled && $0 }
            .overlay {
                if targeted { DropOverlay() }
            }
            .animation(.easeOut(duration: 0.15), value: targeted)
    }
}

extension View {
    func audioImportDrop(enabled: Bool = true, onImport: @escaping (URL) -> Void) -> some View {
        modifier(AudioImportDrop(enabled: enabled, onImport: onImport))
    }
}

private struct DropOverlay: View {
    var body: some View {
        ZStack {
            Theme.Colors.canvas.opacity(0.9)
            VStack(spacing: 12) {
                Image(systemName: "waveform.badge.plus")
                    .font(.system(size: 52, weight: .light))
                    .foregroundStyle(Theme.Colors.accent)
                Text("Drop to transcribe")
                    .font(Theme.Typography.title())
                    .foregroundStyle(Theme.Colors.ink)
                Text("Turns an audio file into a new meeting, transcribed on-device")
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(Theme.Colors.ink2)
            }
            .padding(44)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: Theme.Metrics.radius).fill(Theme.Colors.panel.opacity(0.6)))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Metrics.radius)
                    .strokeBorder(Theme.Colors.accent,
                                  style: StrokeStyle(lineWidth: 2, dash: [9, 7]))
            )
        }
        .padding(24)
        .transition(.opacity)
        .allowsHitTesting(false)
    }
}

// MARK: - Progress banner

/// Compact status pill shown while a file import transcribes/analyzes, so the
/// work is visible even from the dashboard (the meeting itself already shows a
/// "Processing" state in the list/detail).
struct ImportingBanner: View {
    let progress: RecordingManager.ImportProgress

    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 1) {
                Text(progress.fileName)
                    .font(Theme.Typography.cardTitle)
                    .foregroundStyle(Theme.Colors.ink)
                    .lineLimit(1)
                Text(progress.phase.label)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.ink2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: 320, alignment: .leading)
        .background(Theme.Colors.panel, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.Colors.line))
    }
}
