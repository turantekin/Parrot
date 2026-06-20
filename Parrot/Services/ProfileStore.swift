import Foundation
import SwiftData
import Observation

@MainActor
@Observable
final class ProfileStore {
    var activeProfile: CallProfile?

    private let lastUsedKey = "lastUsedProfileID"

    func seedAndMigrateIfNeeded(context: ModelContext, knowledgeBase: KnowledgeBaseService) {
        let existing = (try? context.fetch(FetchDescriptor<CallProfile>())) ?? []
        guard existing.isEmpty else {
            setActiveFromLastUsed(existing)
            return
        }
        // First run: seed presets. Default absorbs today's global settings.
        let instructions = UserDefaults.standard.string(forKey: "copilotInstructions") ?? ""
        let fallback = UserDefaults.standard.object(forKey: "copilotGeneralFallback") as? Bool ?? true
        var presets = ProfilePresets.all()
        if let defIndex = presets.firstIndex(where: { $0.id == ProfilePresets.defaultProfileID }) {
            presets[defIndex] = ProfilePresets.makeDefault(
                persona: presets[defIndex].persona, tone: instructions, allowGeneralKnowledge: fallback)
        }
        for p in presets { context.insert(p) }
        try? context.save()
        // Tag all existing KB docs into Default so today's knowledge keeps working.
        knowledgeBase.tagAllDocuments(into: ProfilePresets.defaultProfileID)
        setActiveFromLastUsed(presets)
    }

    func profiles(in context: ModelContext) -> [CallProfile] {
        let all = (try? context.fetch(FetchDescriptor<CallProfile>())) ?? []
        return all.sorted { $0.sortOrder < $1.sortOrder }
    }

    func setActive(_ profile: CallProfile) {
        activeProfile = profile
        UserDefaults.standard.set(profile.id.uuidString, forKey: lastUsedKey)
    }

    private func setActiveFromLastUsed(_ profiles: [CallProfile]) {
        let sorted = profiles.sorted { $0.sortOrder < $1.sortOrder }
        if let raw = UserDefaults.standard.string(forKey: lastUsedKey),
           let id = UUID(uuidString: raw),
           let match = sorted.first(where: { $0.id == id }) {
            activeProfile = match
        } else {
            activeProfile = sorted.first
        }
    }

    @discardableResult
    func duplicate(_ profile: CallProfile, in context: ModelContext) -> CallProfile {
        let maxOrder = profiles(in: context).map(\.sortOrder).max() ?? 0
        let copy = CallProfile(
            name: profile.name + " copy", iconSystemName: profile.iconSystemName,
            summary: profile.summary, isBuiltIn: false, sortOrder: maxOrder + 1,
            persona: profile.persona, tone: profile.tone,
            allowGeneralKnowledge: profile.allowGeneralKnowledge,
            kinds: profile.kinds, gauges: profile.gauges)
        context.insert(copy)
        try? context.save()
        return copy
    }

    func delete(_ profile: CallProfile, in context: ModelContext) {
        guard !profile.isBuiltIn else { return }
        context.delete(profile)
        try? context.save()
    }
}
