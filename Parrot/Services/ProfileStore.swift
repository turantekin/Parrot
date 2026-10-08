import Foundation
import SwiftData
import Observation

@MainActor
@Observable
final class ProfileStore {
    var activeProfile: CallProfile?

    private let lastUsedKey = "lastUsedProfileID"

    /// Where the migration keeps its flags and backups. The harness swaps
    /// both, so a test run never touches real settings or files.
    var defaults: UserDefaults = .standard
    var backupFolder: URL = ProfileStore.defaultBackupFolder

    static let migrationDoneKey = "profiles2MigrationDone"
    static let screenShownKey = "profiles2ScreenShown"
    static let restorePointLabel = "Before Profiles 2.0"

    nonisolated static var defaultBackupFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Parrot/Backups/profiles-before-2.0", isDirectory: true)
    }

    /// The one-time "Reports can now match each call type" screen is due.
    var profiles2ScreenDue: Bool {
        defaults.bool(forKey: Self.migrationDoneKey) && !defaults.bool(forKey: Self.screenShownKey)
    }

    /// Observed by ContentView, which shows the screen once.
    var showProfiles2Screen = false

    func markProfiles2ScreenShown() { defaults.set(true, forKey: Self.screenShownKey) }

    func seedAndMigrateIfNeeded(context: ModelContext, knowledgeBase: KnowledgeBaseService) {
        let existing = (try? context.fetch(FetchDescriptor<CallProfile>())) ?? []
        guard existing.isEmpty else {
            // Before the refresh: it bumps presetVersion and adds new built-ins,
            // and the migration must see the store as the old version left it.
            migrateToProfiles2IfNeeded(existing, context: context)
            refreshBuiltInsIfStale(existing, context: context, knowledgeBase: knowledgeBase)
            setActiveFromLastUsed(existing)
            showProfiles2Screen = profiles2ScreenDue
            return
        }
        // A fresh install starts on Profiles 2.0: nothing to move, no screen.
        defaults.set(true, forKey: Self.migrationDoneKey)
        defaults.set(true, forKey: Self.screenShownKey)
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

    /// Profiles 2.0, once per install that had profiles before it (the plan's
    /// Task M). Every step is idempotent, so a crash part-way just runs it
    /// again next launch. Copilot fields (persona, custom rules, counterpart,
    /// kinds, gauges, on-device only, document tags) are never touched.
    func migrateToProfiles2IfNeeded(_ profiles: [CallProfile], context: ModelContext) {
        guard !defaults.bool(forKey: Self.migrationDoneKey) else { return }
        // 1. Backup first. Without one, change nothing and try next launch.
        guard backUp(profiles) else { return }
        for p in profiles {
            // 2. Sharing ids: built-ins are known by their preset id.
            if p.sharedID == nil { p.sharedID = p.isBuiltIn ? p.id : UUID() }
            if p.sharedVersion == 0 { p.sharedVersion = 1 }
            if p.sharedSource == nil { p.sharedSource = p.isBuiltIn ? "builtin" : "user" }
            // 3. Restore point, as the profile was (classic report).
            if !p.versions.contains(where: { $0.label == Self.restorePointLabel }) {
                p.saveVersion(label: Self.restorePointLabel)
            }
            // 4. Report: only built-ins nobody tuned switch. Tuned ones get
            // an offer, unless their built-in report is the classic one anyway.
            if p.isBuiltIn && !p.isUserModified {
                p.reportChoice = .preset
            } else {
                p.reportChoice = .classic
                p.reportOfferPending = p.isBuiltIn && p.presetReportTemplate?.isStandard == false
            }
        }
        do {
            try context.save()
            defaults.set(true, forKey: Self.migrationDoneKey)
        } catch {
            NSLog("Parrot: Profiles 2.0 migration didn't save, will retry: \(error.localizedDescription)")
        }
    }

    /// Every profile as a `.parrotprofile` in the backup folder, never
    /// deleted automatically. A file already there is kept, so a re-run
    /// can't replace the pre-2.0 copy. Restoring = Import.
    private func backUp(_ profiles: [CallProfile]) -> Bool {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: backupFolder, withIntermediateDirectories: true)
            for p in profiles {
                let url = backupFolder.appendingPathComponent(Self.backupFileName(for: p))
                guard !fm.fileExists(atPath: url.path) else { continue }
                try ProfileFile.encode(p).write(to: url, options: .atomic)
            }
            return true
        } catch {
            NSLog("Parrot: profile backup failed, Profiles 2.0 waits: \(error.localizedDescription)")
            return false
        }
    }

    /// "Sales discovery 0000C1.parrotprofile": the name to read, the id's
    /// tail to keep two profiles with one name apart.
    static func backupFileName(for p: CallProfile) -> String {
        let name = p.name.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>\n\r"))
            .joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        return "\((name.isEmpty ? "Profile" : String(name.prefix(60)))) \(p.id.uuidString.suffix(6)).parrotprofile"
    }

    /// Refresh built-in profiles whose stored preset version is older than the current
    /// presets. Overwrites the AI-behavior fields (persona, counterpart, kinds, gauges)
    /// so existing installs get prompt/category improvements, while preserving the
    /// user-owned fields (custom rules `tone`, summary, name, icon, toggle, order).
    /// Profiles the user has tuned (isUserModified) are never overwritten — only
    /// their version is bumped so they aren't re-checked every launch.
    private func refreshBuiltInsIfStale(_ existing: [CallProfile], context: ModelContext,
                                        knowledgeBase: KnowledgeBaseService) {
        let presetsByID = Dictionary(uniqueKeysWithValues: ProfilePresets.all().map { ($0.id, $0) })
        var changed = false
        // A built-in added after this install first seeded (v4: Vendor call) is
        // inserted, and inherits the documents tagged into Default so today's
        // knowledge works there from the first call.
        let existingIDs = Set(existing.map(\.id))
        for preset in ProfilePresets.all() where !existingIDs.contains(preset.id) {
            context.insert(preset)
            knowledgeBase.copyProfileTags(from: ProfilePresets.defaultProfileID, to: preset.id)
            changed = true
        }
        for p in existing where p.isBuiltIn && p.presetVersion < ProfilePresets.presetVersion {
            guard let preset = presetsByID[p.id] else { continue }
            if p.isUserModified {
                p.presetVersion = ProfilePresets.presetVersion
                changed = true
                continue
            }
            p.persona = preset.persona
            p.counterpart = preset.counterpart
            p.kinds = preset.kinds
            p.gauges = preset.gauges
            p.presetVersion = ProfilePresets.presetVersion
            changed = true
        }
        if changed { try? context.save() }
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
            counterpart: profile.counterpart,
            allowGeneralKnowledge: profile.allowGeneralKnowledge,
            kinds: profile.kinds, gauges: profile.gauges)
        // A copy can't follow a built-in's report, so it keeps its own copy.
        copy.setCustomReport(profile.reportTemplate)
        copy.sharedID = UUID()
        copy.sharedVersion = 1
        copy.sharedSource = "user"
        context.insert(copy)
        try? context.save()
        return copy
    }

    // MARK: - Import, suggestions, restore (Profiles 2.0)

    /// The profile a file would update: a suggestion's target, else the
    /// profile with the same sharing id. nil = it's a new profile.
    static func target(for file: ProfileFile, in profiles: [CallProfile]) -> CallProfile? {
        guard let id = file.suggestion?.targetSharedID ?? file.sharedID else { return nil }
        return profiles.first { $0.sharedID == id }
    }

    /// A new profile from a file: never a built-in, no documents yet, the
    /// name made unique. `freshIdentity` for "Keep both", so the copy and
    /// the original never answer to the same updates.
    @discardableResult
    func add(_ file: ProfileFile, source: String, freshIdentity: Bool = false, in context: ModelContext) -> CallProfile {
        let all = profiles(in: context)
        let f = file.profile
        let p = CallProfile(name: f.name, iconSystemName: f.icon, summary: f.summary,
                            isBuiltIn: false, sortOrder: (all.map(\.sortOrder).max() ?? 0) + 1,
                            persona: f.persona, tone: f.tone, counterpart: f.counterpart,
                            allowGeneralKnowledge: f.allowGeneralKnowledge, kinds: [], gauges: [])
        Self.write(file, into: p)
        // After write, which copies the file's own name.
        p.name = Self.uniqueName(f.name, among: all.map(\.name))
        p.sharedID = freshIdentity ? UUID() : (file.sharedID ?? UUID())
        p.sharedVersion = max(file.version, 1)
        p.sharedSource = source
        context.insert(p)
        try? context.save()
        return p
    }

    /// Applies a file to a profile. The current state is saved first (the
    /// editor's "Restore previous version" undoes it). Applying counts as
    /// the user's own change, so preset refreshes keep it.
    func apply(_ file: ProfileFile, to p: CallProfile, label: String, in context: ModelContext) {
        p.saveVersion(label: label)
        Self.write(file, into: p)
        p.isUserModified = true
        p.sharedVersion = max(p.sharedVersion + 1, file.version)
        try? context.save()
    }

    /// Puts a saved version back, saving the current state first so the
    /// restore can be undone too. Privacy still only tightens.
    func restore(_ version: ProfileVersion, of p: CallProfile, in context: ModelContext) {
        guard let file = try? ProfileFile.decode(version.file) else { return }
        p.saveVersion(label: "Before restoring")
        Self.write(file, into: p)
        switch ReportChoice(rawValue: version.reportChoice) ?? .classic {
        case .classic: p.setCustomReport(.standard)
        case .preset: p.reportChoice = .preset; p.reportData = nil
        case .custom: p.setCustomReport(file.profile.report ?? .standard)
        }
        try? context.save()
    }

    /// The fields a file carries, onto a profile. Never document tags, never
    /// ids, and on-device only can be switched on, never off.
    private static func write(_ file: ProfileFile, into p: CallProfile) {
        let f = file.profile
        p.name = f.name
        p.iconSystemName = f.icon
        p.summary = f.summary
        p.persona = f.persona
        p.tone = f.tone
        p.counterpart = f.counterpart
        p.allowGeneralKnowledge = f.allowGeneralKnowledge
        p.kinds = f.kinds.map {
            ProfileKind(id: UUID(), key: $0.key, label: $0.label, colorHex: $0.color, iconSystemName: $0.icon,
                        triggerDescription: $0.trigger, isPinned: $0.pinned, priority: $0.priority)
        }
        p.gauges = f.gauges.map {
            SentimentGauge(id: UUID(), key: $0.key, label: $0.label, lowLabel: $0.low, highLabel: $0.high, colorHex: $0.color)
        }
        if file.privacy?.recommendOnDeviceOnly == true { p.onDeviceOnly = true }
        // A report equal to the built-in's own follows it again (editReport).
        let report = f.report ?? .standard
        p.editReport { $0 = report }
    }

    /// "Investor pitch", then "Investor pitch 2", "Investor pitch 3"…
    static func uniqueName(_ name: String, among names: [String]) -> String {
        guard names.contains(name) else { return name }
        var n = 2
        while names.contains("\(name) \(n)") { n += 1 }
        return "\(name) \(n)"
    }

    func delete(_ profile: CallProfile, in context: ModelContext) {
        guard !profile.isBuiltIn else { return }
        context.delete(profile)
        try? context.save()
    }
}
