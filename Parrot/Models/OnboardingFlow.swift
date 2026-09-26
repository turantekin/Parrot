import Foundation

/// One screen of the setup sheet. Raw values are what `onboardingStepName`
/// stores, so renaming a case strands saved progress.
enum OnboardingStep: String, CaseIterable {
    case welcome, permissions, meetCopilot, copilotPath, speechModel, copilotSetup, automatic, ready
}

/// How Copilot runs, picked on "How should Copilot work?".
enum CopilotPath: String, CaseIterable {
    case `private`, balanced, cloud, later
    static let defaultsKey = "onboardingCopilotPath"
}

/// The full first-run tour, or the short "Set up Copilot" one from Home or
/// Settings.
enum OnboardingMode: String {
    case full, copilot
    static let defaultsKey = "onboardingMode"
}

enum OnboardingFlow {
    static let stepKey = "onboardingStepName"
    /// The old Int index (0 welcome … 4 ready), read once and removed.
    static let legacyStepKey = "onboardingStep"

    static func steps(mode: OnboardingMode, path: CopilotPath?) -> [OnboardingStep] {
        switch mode {
        case .copilot:
            let setup: [OnboardingStep] = (path == nil || path == .later) ? [] : [.copilotSetup]
            return [.meetCopilot, .copilotPath] + setup + [.ready]
        case .full:
            let middle: [OnboardingStep]
            switch path {
            case .private?, .balanced?: middle = [.speechModel, .copilotSetup]
            case .cloud?: middle = [.copilotSetup]
            case .later?, nil: middle = [.speechModel]
            }
            return [.welcome, .permissions, .meetCopilot, .copilotPath] + middle + [.automatic, .ready]
        }
    }

    /// The step `offset` away, clamped to the list.
    static func step(_ offset: Int, from step: OnboardingStep, in steps: [OnboardingStep]) -> OnboardingStep {
        let index = steps.firstIndex(of: resolve(step, in: steps))! + offset
        return steps[min(max(index, 0), steps.count - 1)]
    }

    /// A saved step that no longer belongs to the list (the path changed
    /// under it) lands on the path choice.
    static func resolve(_ step: OnboardingStep, in steps: [OnboardingStep]) -> OnboardingStep {
        if steps.contains(step) { return step }
        return steps.contains(.copilotPath) ? .copilotPath : steps[0]
    }

    /// Moves the old Int step to a name, once. Anyone past permissions lands
    /// on Meet Copilot, so nobody mid-tour during an update skips it.
    static func migrateLegacyStep(in defaults: UserDefaults) {
        guard defaults.string(forKey: stepKey) == nil,
              let old = defaults.object(forKey: legacyStepKey) as? Int else { return }
        let step: OnboardingStep = old <= 0 ? .welcome : old == 1 ? .permissions : .meetCopilot
        defaults.set(step.rawValue, forKey: stepKey)
        defaults.removeObject(forKey: legacyStepKey)
    }
}

/// Defaults that fit this Mac's memory.
enum MachineFit {
    static func memoryGB(_ bytes: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Int {
        Int((Double(bytes) / 1_073_741_824).rounded())
    }

    // ponytail: one threshold for both models; split it if a 12 GB Mac
    // proves too tight for turbo plus gemma together.
    private static func isLarge(_ memoryGB: Int) -> Bool { memoryGB >= 12 }

    static func whisperModel(memoryGB: Int) -> String { isLarge(memoryGB) ? "large-v3-turbo" : "base" }
    static func ollamaModel(memoryGB: Int) -> String { isLarge(memoryGB) ? "gemma3:4b" : "llama3.2:3b" }
}
