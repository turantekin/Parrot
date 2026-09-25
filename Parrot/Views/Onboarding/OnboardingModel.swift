import SwiftUI

/// State shared by the setup sheet's steps. Mode, path and step persist, so
/// the quit-and-reopen macOS can require after a permission grant lands the
/// user back where they were.
@MainActor
@Observable
final class OnboardingModel {
    private let defaults: UserDefaults
    let mode: OnboardingMode
    private(set) var step: OnboardingStep
    var path: CopilotPath? {
        didSet {
            defaults.set(path?.rawValue, forKey: CopilotPath.defaultsKey)
            pathError = nil
        }
    }
    var pathError: String?
    /// The Copilot card's switch: consent to turn Copilot on.
    var copilotOn = true
    var claudeCheck: ProviderKeyCheck.Outcome?
    var deepgramCheck: ProviderKeyCheck.Outcome?
    var ollamaModel: String
    /// Kept current by the private setup step's polling.
    var ollamaModelReady = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        OnboardingFlow.migrateLegacyStep(in: defaults)
        let mode = OnboardingMode(rawValue: defaults.string(forKey: OnboardingMode.defaultsKey) ?? "") ?? .full
        var saved = CopilotPath(rawValue: defaults.string(forKey: CopilotPath.defaultsKey) ?? "")
        if mode == .copilot, saved == .later { saved = nil }  // the short tour asks again
        self.mode = mode
        path = saved
        ollamaModel = defaults.string(forKey: "copilotOllamaModel")
            ?? MachineFit.ollamaModel(memoryGB: MachineFit.memoryGB())
        let steps = OnboardingFlow.steps(mode: mode, path: saved)
        let stored = OnboardingStep(rawValue: defaults.string(forKey: OnboardingFlow.stepKey) ?? "")
        step = OnboardingFlow.resolve(stored ?? steps[0], in: steps)
    }

    var steps: [OnboardingStep] { OnboardingFlow.steps(mode: mode, path: path) }
    var isFirst: Bool { step == steps.first }
    var isLast: Bool { step == steps.last }

    /// Continue (+1) and Back (-1). Continue on the path choice needs a pick;
    /// leaving the Copilot setup writes the settings it implies.
    func move(_ offset: Int) {
        if offset > 0, step == .copilotPath, path == nil {
            pathError = "Pick one to continue"
            return
        }
        if offset > 0, step == .copilotSetup { applyChoices() }
        go(to: OnboardingFlow.step(offset, from: step, in: steps))
    }

    func go(to newStep: OnboardingStep) {
        step = newStep
        defaults.set(newStep.rawValue, forKey: OnboardingFlow.stepKey)
    }

    func decideLater() {
        path = .later
        applyChoices()
        move(1)
    }

    func applyChoices() {
        guard let path else { return }
        CopilotPathSettings.apply(CopilotChoices(
            path: path, ollamaModel: ollamaModel, copilotSwitchOn: copilotOn,
            claudeKeyWorks: claudeCheck == .works, deepgramKeyWorks: deepgramCheck == .works,
            ollamaModelReady: ollamaModelReady), to: defaults)
    }

    /// Let's start / Done: the next tour starts clean.
    func finish() {
        defaults.removeObject(forKey: OnboardingFlow.stepKey)
        defaults.set(OnboardingMode.full.rawValue, forKey: OnboardingMode.defaultsKey)
    }
}
