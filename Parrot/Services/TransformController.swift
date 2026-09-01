import AppKit
import Foundation

@MainActor
@Observable
final class TransformController {
    enum Phase: Equatable {
        case idle
        case working
        case copied
        case inserted
        case failed(String)

        var hud: String {
            switch self {
            case .idle: ""
            case .working: "Rewriting…"
            case .copied: "Copied — press ⌘V"
            case .inserted: "In the field"
            case .failed(let message): message
            }
        }
    }

    private(set) var phase: Phase = .idle
    private var inFlight = false
    private var hideTask: Task<Void, Never>?

    var itemID: String = TransformKind.polish.rawValue

    var kind: TransformKind {
        get { TransformKind(rawValue: itemID) ?? .polish }
        set { itemID = newValue.rawValue }
    }

    var instruction: String {
        TransformCatalog.item(id: itemID)?.instruction ?? TransformKind.polish.instruction
    }

    /// Harness hook — pretends a rewrite is already in flight.
    func beginInFlight() { inFlight = true }

    func run(destination: TextRewriter.Destination) {
        if inFlight {
            phase = .failed("A rewrite is already running.")
            scheduleHide()
            return
        }
        let source = FocusText.resolveSource(
            selected: FocusText.selectedText(),
            clipboard: NSPasteboard.general.string(forType: .string)
        ) ?? ""
        guard !source.isEmpty else {
            phase = .failed("Select text in a field, or copy it, then try again.")
            scheduleHide()
            return
        }
        inFlight = true
        phase = .working
        Task {
            defer { self.inFlight = false }
            do {
                let out = try await TextRewriter.rewrite(
                    source, instruction: instruction, destination: destination)
                self.phase = FocusText.deliver(out) == .inserted ? .inserted : .copied
            } catch {
                self.phase = .failed(error.localizedDescription)
            }
            self.scheduleHide()
        }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(3.5))
            guard !Task.isCancelled else { return }
            self.phase = .idle
        }
    }
}
