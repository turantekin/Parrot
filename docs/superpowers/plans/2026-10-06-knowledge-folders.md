# Knowledge Folders Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Group knowledge documents into folders, move "Use for" onto folders with a per-document override, make "never used on calls" visible, and turn the unused note field into a one-line About.

**Architecture:** A small `KBScope` value (`all` / `only(ids)` / `off`) lives on `KBFolder` and, optionally, on `KBDocument` (`nil` = Same as folder). One function, `KnowledgeBaseService.isInPlay(_:callType:)`, decides everything the Assistant may quote; search, "documents in play" and the Profiles page all go through it. `index.json` gets `version: 2`; a store without it is upgraded once on load (tags → own scope, no tags → `off`) and backed up on the first save.

**Tech Stack:** Swift 5.9+, SwiftUI (macOS 14), SwiftData (`CallProfile` via `@Query`), JSON `Codable` index. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-10-06-knowledge-folders-design.md`

## Global Constraints

- macOS 14.0+; no new packages; build with `swift build` / the Makefile, never Xcode.
- Tests are `--profile-test` checks in `Parrot/ProfileTest.swift` (no XCTest). Quick loop: `swift build 2>&1 | grep -E "error:|Build complete" && .build/debug/Parrot --profile-test | grep -E "^FAIL|kb|ALL PASS|FAILURES"`. Always `swift build` before running `.build/debug/Parrot` (a stale binary passes old code).
- Views style only through `Theme` (`Theme.Colors`, `Theme.Typography`, `Theme.Metrics`); no hex, no new magic numbers (existing literal idioms like `HStack(spacing: 8)` and `.padding(.leading, 24)` are the house style and may be matched).
- Every new `index.json` key decodes with `decodeIfPresent` and a default; a strict decode failure empties the KB.
- UI copy is exact: "Same as folder", "All call types", "Off, not used on calls", "Not used on calls", "Off", "No folder", "New folder", "Add documents…", "Add documents here…", "Search documents", "Move to folder", "Edit about line", "Remove…", "Rename", "Delete folder…", "Add a line about this document", "Change which documents a call type uses on the Knowledge page."
- No real company, person or meeting names in code, tests or docs: use Acme / Northwind.
- Never run a dev build against the owner's real store; use copies.
- Commit after each task; messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **Relaunch after adding a document to No folder.** It is saved with neither `folderID` nor `scope`; it must reload as Same as folder and stay in play, not be mistaken for a legacy document and switched off. Test: Task 2, `testKnowledgeStoreUpgrade` ("a new document stays in play after relaunch").
2. **Updating a file by adding it again.** Its About line, folder and Use for must survive. Test: Task 2, `testKnowledgeService` ("re-adding keeps About, folder and Use for").
3. **Deleting a folder that was Off.** Its documents must stay off in No folder (No folder is All call types, so a naive delete would switch them on). Test: Task 2, `testKnowledgeService` ("deleting an off folder keeps its documents off").
4. **A call type deleted after being chosen.** A scope naming only deleted ids must read "Not used on calls" and match no live call. Tests: Task 1 ("a deleted call type matches no live call"), Task 3 ("only deleted call types shows not used").
5. **Search with other case or accents.** "SERVICE" and "gorusme" must find "Service agreement" and an About line with "görüşme". Test: Task 3, `testKnowledgeList`.

---

### Task 1: Scope, folder and document model

**Files:**
- Modify: `Parrot/Models/KnowledgeBase.swift`
- Test: `Parrot/ProfileTest.swift` (new `testKnowledgeModel`, add to `run()`)

**Interfaces:**
- Consumes: nothing new.
- Produces:
  - `enum KBScope: Codable, Equatable { case all, only(Set<UUID>), off }` with `func allows(_ callType: UUID?) -> Bool`, `func toggling(_ id: UUID, allTypes: [UUID]) -> KBScope`, `func adding(_ target: UUID, whereHas source: UUID) -> KBScope`.
  - `struct KBFolder: Codable, Identifiable, Equatable { var id: UUID; var name: String; var scope: KBScope }`.
  - `KBDocument` gains `var folderID: UUID?`, `var scope: KBScope?`, `func migrated() -> KBDocument`, `func effectiveScope(in folders: [KBFolder]) -> KBScope`, `var displayName: String`; init gains `folderID: UUID? = nil, scope: KBScope? = nil` after `profileIDs:`. `profileIDs` stays (still encoded) until Task 2.

- [ ] **Step 1: Write the failing test**

Add to `Parrot/ProfileTest.swift` (call `testKnowledgeModel()` at the end of the list in `run()`, before the `print(failures == 0 ...)` line):

```swift
    static func testKnowledgeModel() {
        let sales = UUID(), vendor = UUID()
        check("kb: all allows any call type", KBScope.all.allows(sales) && KBScope.all.allows(nil))
        check("kb: off allows nothing", !KBScope.off.allows(sales) && !KBScope.off.allows(nil))
        check("kb: only allows its types", KBScope.only([sales]).allows(sales) && !KBScope.only([sales]).allows(vendor))
        check("kb: no call type means everything not off", KBScope.only([sales]).allows(nil))
        check("kb: a deleted call type matches no live call", !KBScope.only([UUID()]).allows(sales))
        check("kb: unticking from all keeps the rest", KBScope.all.toggling(sales, allTypes: [sales, vendor]) == .only([vendor]))
        check("kb: ticking from off", KBScope.off.toggling(sales, allTypes: [sales, vendor]) == .only([sales]))
        check("kb: unticking the last type is off", KBScope.only([sales]).toggling(sales, allTypes: [sales, vendor]) == .off)
        check("kb: adding copies into sets that have the source", KBScope.only([sales]).adding(vendor, whereHas: sales) == .only([sales, vendor]))
        check("kb: adding leaves other scopes alone",
              KBScope.all.adding(vendor, whereHas: sales) == .all && KBScope.only([vendor]).adding(sales, whereHas: UUID()) == .only([vendor]))

        let deal = KBFolder(name: "Acme deal", scope: .only([sales]))
        let paused = KBFolder(name: "Old deals", scope: .off)
        let inherits = KBDocument(name: "pricing.md", chunkCount: 1, addedAt: .now, folderID: deal.id)
        let own = KBDocument(name: "nda.md", chunkCount: 1, addedAt: .now, folderID: paused.id, scope: .only([vendor]))
        let loose = KBDocument(name: "faq.md", chunkCount: 1, addedAt: .now)
        check("kb: same as folder takes the folder's", inherits.effectiveScope(in: [deal, paused]) == .only([sales]))
        check("kb: own Use for beats an off folder", own.effectiveScope(in: [deal, paused]) == .only([vendor]))
        check("kb: no folder is all call types", loose.effectiveScope(in: [deal]) == .all)
        check("kb: a missing folder falls back to all", inherits.effectiveScope(in: []) == .all)

        let tagged = KBDocument(name: "a.md", chunkCount: 1, addedAt: .now, profileIDs: [sales]).migrated()
        let untagged = KBDocument(name: "b.md", chunkCount: 1, addedAt: .now).migrated()
        check("kb: upgrade keeps tags as own Use for", tagged.scope == .only([sales]) && tagged.folderID == nil && tagged.profileIDs.isEmpty)
        check("kb: upgrade turns no tags into off", untagged.scope == .off)

        check("kb: display name hides the extension",
              KBDocument(name: "05 - Service agreement.md", chunkCount: 1, addedAt: .now).displayName == "05 - Service agreement")
        check("kb: display name keeps an unknown extension",
              KBDocument(name: "notes v1.2", chunkCount: 1, addedAt: .now).displayName == "notes v1.2")

        // Round trip: a No-folder, Same-as-folder document writes neither key
        // and must come back as nil/nil (the per-document legacy trap).
        let back = (try? JSONEncoder().encode(loose)).flatMap { try? JSONDecoder().decode(KBDocument.self, from: $0) }
        check("kb: nil folder and scope survive a round trip", back != nil && back?.folderID == nil && back?.scope == nil)
        let ownBack = (try? JSONEncoder().encode(own)).flatMap { try? JSONDecoder().decode(KBDocument.self, from: $0) }
        check("kb: own scope survives a round trip", ownBack?.scope == .only([vendor]) && ownBack?.folderID == paused.id)
    }
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift build 2>&1 | grep -E "error:|Build complete"`
Expected: compile errors, `cannot find 'KBScope' in scope` / `cannot find 'KBFolder' in scope`.

- [ ] **Step 3: Implement the model**

In `Parrot/Models/KnowledgeBase.swift`, add above `struct KBDocument`:

```swift
/// Where a folder or document may be used on calls ("Use for").
enum KBScope: Codable, Equatable {
    /// Every call type.
    case all
    /// Only these call types (CallProfile ids).
    case only(Set<UUID>)
    /// Never used on calls.
    case off

    /// Whether a call of this type may use it. `nil` = no call type
    /// (harnesses, back-compat): everything that isn't off.
    func allows(_ callType: UUID?) -> Bool {
        switch self {
        case .all: return true
        case .off: return false
        case .only(let ids): return callType.map { ids.contains($0) } ?? true
        }
    }

    /// The scope after ticking or unticking one call type in the Use for
    /// menu. `.all` starts from every type in `allTypes`; none left = off.
    func toggling(_ id: UUID, allTypes: [UUID]) -> KBScope {
        var ids: Set<UUID>
        switch self {
        case .all: ids = Set(allTypes)
        case .off: ids = []
        case .only(let current): ids = current
        }
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
        return ids.isEmpty ? .off : .only(ids)
    }

    /// A new call type starts with another's documents: a set that has
    /// `source` gets `target` too. Other scopes are unchanged.
    func adding(_ target: UUID, whereHas source: UUID) -> KBScope {
        guard case .only(let ids) = self, ids.contains(source) else { return self }
        return .only(ids.union([target]))
    }
}

/// A group of documents sharing one Use for.
struct KBFolder: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var scope: KBScope = .all
}
```

Replace `struct KBDocument` with:

```swift
/// A document the user added to the knowledge base.
struct KBDocument: Codable, Identifiable {
    var id = UUID()
    var name: String
    /// The About line ("Signed service agreement, Sept 2026"), sent to the
    /// Assistant as the source's user note. Stored under its old key.
    var note: String = ""
    var chunkCount: Int
    var addedAt: Date
    /// Pre-folders call-type tags. Read only to upgrade (`migrated()`).
    var profileIDs: Set<UUID> = []
    /// nil = No folder.
    var folderID: UUID?
    /// nil = Same as folder.
    var scope: KBScope?

    enum CodingKeys: String, CodingKey { case id, name, note, chunkCount, addedAt, profileIDs, folderID, scope }

    init(id: UUID = UUID(), name: String, note: String = "", chunkCount: Int, addedAt: Date,
         profileIDs: Set<UUID> = [], folderID: UUID? = nil, scope: KBScope? = nil) {
        self.id = id
        self.name = name
        self.note = note
        self.chunkCount = chunkCount
        self.addedAt = addedAt
        self.profileIDs = profileIDs
        self.folderID = folderID
        self.scope = scope
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        // Fields added after 1.0 decode leniently (decodeIfPresent + default):
        // a strict decode of a missing key fails the WHOLE store load, and the
        // next save would then overwrite the store with empty — total KB loss.
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        chunkCount = try c.decode(Int.self, forKey: .chunkCount)
        addedAt = try c.decode(Date.self, forKey: .addedAt)
        profileIDs = try c.decodeIfPresent(Set<UUID>.self, forKey: .profileIDs) ?? []
        folderID = try c.decodeIfPresent(UUID.self, forKey: .folderID)
        // A scope this build can't read falls back to Same as folder
        // rather than failing the whole index.
        scope = try? c.decodeIfPresent(KBScope.self, forKey: .scope)
    }

    /// This document as a pre-folders index upgrades: no folder, its tags
    /// become its own Use for, and no tags (which meant never used on a
    /// call) becomes off. Behaviour is unchanged, only visible now.
    func migrated() -> KBDocument {
        var doc = self
        doc.folderID = nil
        doc.scope = profileIDs.isEmpty ? .off : .only(profileIDs)
        doc.profileIDs = []
        return doc
    }

    /// Its own Use for, else its folder's, else No folder's (all).
    func effectiveScope(in folders: [KBFolder]) -> KBScope {
        scope ?? folders.first { $0.id == folderID }?.scope ?? .all
    }

    /// The file name without a common document extension (the icon shows the type).
    var displayName: String {
        let ext = (name as NSString).pathExtension.lowercased()
        return ["md", "markdown", "txt", "text", "pdf"].contains(ext) ? (name as NSString).deletingPathExtension : name
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `swift build 2>&1 | grep -E "error:|Build complete" && .build/debug/Parrot --profile-test | grep -E "^FAIL|kb:|ALL PASS|FAILURES"`
Expected: every `kb:` line PASS, ends with `ALL PASS`.

- [ ] **Step 5: Commit**

```bash
git add Parrot/Models/KnowledgeBase.swift Parrot/ProfileTest.swift
git commit -m "Knowledge: scope, folder and document model for folders

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Service, index upgrade and every caller

**Files:**
- Modify: `Parrot/Services/KnowledgeBaseService.swift` (state, `addDocuments`, `addDocument`, scoping section ~L108-143, `search` ~L150-158, `seedForSnapshot`, `Store`/`load`/`save` ~L500-546)
- Modify: `Parrot/Models/KnowledgeBase.swift` (stop writing `profileIDs`)
- Modify: `Parrot/Services/CallAnalysisEngine.swift:412`
- Modify: `Parrot/CopilotHarness.swift:34-36`
- Modify: `Parrot/SnapshotTool.swift:424-429`
- Modify: `Parrot/Views/SettingsView.swift:976-995` (interim chip wiring; Task 3 replaces the row)
- Modify: `Parrot/Views/ProfilesSettingsView.swift:242-254, 378-412` (read-only card, delete `DocTagToggle`)
- Test: `Parrot/ProfileTest.swift` (new `testKnowledgeService`, `testKnowledgeStoreUpgrade`; update `testKBScoping`)

**Interfaces:**
- Consumes: Task 1's `KBScope`, `KBFolder`, `KBDocument.migrated()`, `effectiveScope(in:)`, `displayName`.
- Produces (on `KnowledgeBaseService`):
  - `private(set) var folders: [KBFolder]`
  - `func addDocuments(at urls: [URL], into folderID: UUID? = nil) async`
  - `nonisolated static func replacing(_ documents: [KBDocument], with new: KBDocument) -> [KBDocument]`
  - `@discardableResult func createFolder(name: String) -> KBFolder`
  - `func renameFolder(_ folder: KBFolder, to name: String)`
  - `func setScope(_ scope: KBScope, for folder: KBFolder)`
  - `func deleteFolder(_ folder: KBFolder)`
  - `func setScope(_ scope: KBScope?, for document: KBDocument)` (nil = Same as folder)
  - `func move(_ document: KBDocument, to folderID: UUID?)`
  - `func documents(in folderID: UUID?) -> [KBDocument]` (sorted by name)
  - `func effectiveScope(of document: KBDocument) -> KBScope`
  - `func isInPlay(_ document: KBDocument, callType: UUID?) -> Bool`
  - `func documentsInPlay(for profileID: UUID?) -> [String]` (unchanged signature, new rule)
  - `func seedForSnapshot(documents: [KBDocument], folders: [KBFolder] = [])`
  - Removed: `setProfiles(_:for:)`, `documentNames(for:)`.

- [ ] **Step 1: Write the failing tests**

Add to `Parrot/ProfileTest.swift` and call both from `run()` after `testKnowledgeModel()`:

```swift
    @MainActor
    static func testKnowledgeService() {
        let kb = KnowledgeBaseService(persistent: false)
        let sales = UUID(), vendor = UUID()
        let deal = KBFolder(name: "Acme deal", scope: .only([sales]))
        let paused = KBFolder(name: "Old deals", scope: .off)
        let inDeal = KBDocument(name: "pricing.md", chunkCount: 1, addedAt: .now, folderID: deal.id)
        let ownInDeal = KBDocument(name: "nda.md", chunkCount: 1, addedAt: .now, folderID: deal.id, scope: .only([vendor]))
        let inPaused = KBDocument(name: "old-plan.md", chunkCount: 1, addedAt: .now, folderID: paused.id)
        let loose = KBDocument(name: "faq.md", chunkCount: 1, addedAt: .now)
        kb.seedForSnapshot(documents: [inDeal, ownInDeal, inPaused, loose], folders: [deal, paused])

        check("kb: in play follows the folder", Set(kb.documentsInPlay(for: sales)) == ["pricing.md", "faq.md"])
        check("kb: own Use for wins", Set(kb.documentsInPlay(for: vendor)) == ["nda.md", "faq.md"])
        check("kb: no call type skips only off", Set(kb.documentsInPlay(for: nil)) == ["pricing.md", "nda.md", "faq.md"])
        check("kb: documents in a folder, by name", kb.documents(in: deal.id).map(\.name) == ["nda.md", "pricing.md"])

        kb.move(inDeal, to: paused.id)
        check("kb: a moved document follows its new folder", !kb.documentsInPlay(for: sales).contains("pricing.md"))
        kb.move(ownInDeal, to: nil)
        check("kb: a moved document keeps its own Use for",
              kb.documentsInPlay(for: vendor).contains("nda.md") && !kb.documentsInPlay(for: sales).contains("nda.md"))

        kb.deleteFolder(paused)
        let oldPlan = kb.documents.first { $0.name == "old-plan.md" }
        check("kb: deleting an off folder keeps its documents off",
              oldPlan?.folderID == nil && oldPlan?.scope == .off && !kb.documentsInPlay(for: nil).contains("old-plan.md"))
        check("kb: deleting a folder never deletes documents", kb.documents.count == 4 && kb.folders.map(\.name) == ["Acme deal"])

        kb.renameFolder(deal, to: "   ")
        check("kb: a blank name keeps the folder's name", kb.folders.first?.name == "Acme deal")
        kb.renameFolder(deal, to: "Northwind deal")
        check("kb: rename", kb.folders.first?.name == "Northwind deal")

        kb.copyProfileTags(from: sales, to: vendor)
        check("kb: a new call type gets the source's folders", kb.folders.first?.scope == .only([sales, vendor]))

        let tag = UUID()
        kb.tagAllDocuments(into: tag)
        check("kb: first seeding turns off documents on for that type",
              kb.documentsInPlay(for: tag).contains("old-plan.md") && kb.documentsInPlay(for: tag).contains("nda.md"))

        // Re-adding a file is an update: About line, folder and Use for stay.
        let old = KBDocument(name: "terms.md", note: "Signed terms, 2026", chunkCount: 3, addedAt: .distantPast,
                             folderID: deal.id, scope: .only([vendor]))
        let updated = KnowledgeBaseService.replacing([old], with: KBDocument(name: "terms.md", chunkCount: 5, addedAt: .now))
        check("kb: re-adding keeps About, folder and Use for",
              updated.count == 1 && updated[0].note == "Signed terms, 2026" && updated[0].folderID == deal.id
                && updated[0].scope == .only([vendor]) && updated[0].chunkCount == 5)
        let addedInto = KnowledgeBaseService.replacing([old], with: KBDocument(name: "terms.md", chunkCount: 5, addedAt: .now, folderID: paused.id))
        check("kb: re-adding into a folder moves it there", addedInto[0].folderID == paused.id && addedInto[0].scope == .only([vendor]))
    }

    @MainActor
    static func testKnowledgeStoreUpgrade() {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("kb-upgrade-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let index = dir.appendingPathComponent("index.json")
        let backup = dir.appendingPathComponent("index-backup-before-folders.json")
        let sales = UUID()
        let legacy = """
        {"documents":[
          {"id":"\(UUID().uuidString)","name":"tagged.md","note":"","chunkCount":1,"addedAt":0,"profileIDs":["\(sales.uuidString)"]},
          {"id":"\(UUID().uuidString)","name":"untagged.md","note":"","chunkCount":1,"addedAt":0}
        ],"chunks":[]}
        """
        try? Data(legacy.utf8).write(to: index)
        setenv("PARROT_KB_INDEX", index.path, 1)
        defer { unsetenv("PARROT_KB_INDEX"); try? fm.removeItem(at: dir) }

        let kb = KnowledgeBaseService()
        check("kb upgrade: tags become own Use for", kb.documents.first { $0.name == "tagged.md" }?.scope == .only([sales]))
        check("kb upgrade: untagged documents stay off, now visibly", kb.documents.first { $0.name == "untagged.md" }?.scope == .off)
        check("kb upgrade: nothing is copied before a save", !fm.fileExists(atPath: backup.path))

        // A document added after the upgrade: No folder, Same as folder.
        kb.seedForSnapshot(documents: kb.documents + [KBDocument(name: "fresh.md", chunkCount: 1, addedAt: .now)], folders: kb.folders)
        kb.createFolder(name: "Acme deal")  // saves
        check("kb upgrade: the first save keeps a backup", fm.fileExists(atPath: backup.path))
        let written = (try? String(contentsOf: index, encoding: .utf8)) ?? ""
        check("kb upgrade: the index is now version 2", written.contains("\"version\":2"))
        check("kb upgrade: old tags are no longer written", !written.contains("profileIDs"))

        let reopened = KnowledgeBaseService()
        let fresh = reopened.documents.first { $0.name == "fresh.md" }
        check("kb upgrade: a new document stays in play after relaunch",
              fresh != nil && fresh?.scope == nil && fresh.map { reopened.isInPlay($0, callType: sales) } == true)
        check("kb upgrade: folders come back", reopened.folders.map(\.name) == ["Acme deal"])
    }
```

Replace the body of `testKBScoping()` with (it used the removed `documentNames(for:)` and `profileIDs`):

```swift
    @MainActor
    static func testKBScoping() {
        let kb = KnowledgeBaseService(persistent: false)
        check("documentsInPlay for an unknown profile is empty on an empty KB", kb.documentsInPlay(for: UUID()).isEmpty)
        let tagID = UUID()
        kb.tagAllDocuments(into: tagID)
        check("tagAllDocuments on an empty KB is a no-op", kb.documents.isEmpty)
    }
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift build 2>&1 | grep -E "error:|Build complete"`
Expected: compile errors (`value of type 'KnowledgeBaseService' has no member 'folders'`, `extra argument 'folders'`, `no member 'replacing'`).

- [ ] **Step 3: Implement the service**

In `KnowledgeBaseService`, next to `documents`:

```swift
    private(set) var documents: [KBDocument] = []
    /// Folders in the order they were made. Documents point at them by id.
    private(set) var folders: [KBFolder] = []
```

and next to `persistent`:

```swift
    /// The loaded index predates folders: the first save keeps a copy.
    private var upgradedFromLegacy = false
```

Replace `addDocuments(at:)` and the tail of `addDocument(at:)`:

```swift
    func addDocuments(at urls: [URL], into folderID: UUID? = nil) async {
        isIndexing = true
        lastError = nil
        for url in urls {
            await addDocument(at: url, into: folderID)
        }
        isIndexing = false
        await refreshEmbeddings()
    }

    private func addDocument(at url: URL, into folderID: UUID?) async {
```

(body unchanged down to `guard !embedded.isEmpty ...`), then replace the final block (`// Re-adding a document replaces ...` through `save()`) with:

```swift
        // Re-adding a document replaces its previous version (see `replacing`).
        chunks.removeAll { $0.documentName == name }
        chunks.append(contentsOf: embedded)
        documents = Self.replacing(documents, with: KBDocument(
            name: name, chunkCount: embedded.count, addedAt: .now, folderID: folderID))
        save()
    }

    /// `documents` with `new` added. A file of the same name is an update:
    /// it keeps its About line and Use for, and its folder unless `new` was
    /// added into one.
    nonisolated static func replacing(_ documents: [KBDocument], with new: KBDocument) -> [KBDocument] {
        var doc = new
        if let old = documents.first(where: { $0.name == new.name }) {
            doc.note = old.note
            doc.scope = old.scope
            doc.folderID = new.folderID ?? old.folderID
        }
        return documents.filter { $0.name != new.name } + [doc]
    }
```

Replace `seedForSnapshot`:

```swift
    /// Fake documents and folders for the offscreen renders and tests.
    func seedForSnapshot(documents docs: [KBDocument], folders: [KBFolder] = []) {
        documents = docs
        self.folders = folders
    }
```

Replace the whole `// MARK: - Profile Scoping` section (`tagAllDocuments` through `documentsInPlay`) with:

```swift
    // MARK: - Folders and Use for

    @discardableResult
    func createFolder(name: String) -> KBFolder {
        let folder = KBFolder(name: name)
        folders.append(folder)
        save()
        return folder
    }

    /// A blank name keeps the old one.
    func renameFolder(_ folder: KBFolder, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = folders.firstIndex(where: { $0.id == folder.id }) else { return }
        folders[i].name = trimmed
        save()
    }

    func setScope(_ scope: KBScope, for folder: KBFolder) {
        guard let i = folders.firstIndex(where: { $0.id == folder.id }) else { return }
        folders[i].scope = scope
        save()
    }

    /// Never deletes documents: they move to No folder, and those that
    /// followed the folder keep its Use for as their own, so nothing the
    /// Assistant uses, or ignores, changes.
    func deleteFolder(_ folder: KBFolder) {
        guard let current = folders.first(where: { $0.id == folder.id }) else { return }
        for i in documents.indices where documents[i].folderID == current.id {
            if documents[i].scope == nil { documents[i].scope = current.scope }
            documents[i].folderID = nil
        }
        folders.removeAll { $0.id == current.id }
        save()
    }

    /// nil = Same as folder.
    func setScope(_ scope: KBScope?, for document: KBDocument) {
        guard let i = documents.firstIndex(where: { $0.id == document.id }) else { return }
        documents[i].scope = scope
        save()
    }

    /// nil = No folder. A document that follows its folder follows the new one.
    func move(_ document: KBDocument, to folderID: UUID?) {
        guard let i = documents.firstIndex(where: { $0.id == document.id }) else { return }
        documents[i].folderID = folderID
        save()
    }

    /// A folder's documents (nil = No folder), by name.
    func documents(in folderID: UUID?) -> [KBDocument] {
        documents.filter { $0.folderID == folderID }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func effectiveScope(of document: KBDocument) -> KBScope {
        document.effectiveScope(in: folders)
    }

    /// The one rule for whether the Assistant may use a document on a call
    /// of this type (nil = no call type: every document that isn't off).
    func isInPlay(_ document: KBDocument, callType: UUID?) -> Bool {
        effectiveScope(of: document).allows(callType)
    }

    // MARK: - Call types

    /// First-ever profile seeding (stores from before profiles): documents
    /// with their own Use for get this call type too; off ones get only it.
    func tagAllDocuments(into id: UUID) {
        for i in documents.indices {
            switch documents[i].scope {
            case .only(let ids)?: documents[i].scope = .only(ids.union([id]))
            case .off?: documents[i].scope = .only([id])
            default: break
            }
        }
        save()
    }

    /// A new call type starts with another's documents: every folder and
    /// document set that has `source` gets `target` too.
    func copyProfileTags(from source: UUID, to target: UUID) {
        for i in folders.indices { folders[i].scope = folders[i].scope.adding(target, whereHas: source) }
        for i in documents.indices { documents[i].scope = documents[i].scope?.adding(target, whereHas: source) }
        save()
    }

    /// The documents the Assistant can quote on a call of this type
    /// (nil = every document that isn't off). Mirrors `search`.
    func documentsInPlay(for profileID: UUID?) -> [String] {
        documents.filter { isInPlay($0, callType: profileID) }.map(\.name)
    }
```

In `search(query:profileID:topK:)`, replace the "Restrict to documents tagged" block (the `allowedNames` and `snapshot` lines) with:

```swift
        // Only documents this call type may use (nil = every document not off).
        let allowedNames = Set(documents.filter { isInPlay($0, callType: profileID) }.map(\.name))
        let snapshot = chunks.filter { allowedNames.contains($0.documentName) }
```

Replace `Store`, `load()` and `save()`:

```swift
    private struct Store: Codable {
        /// 2 = folders. Missing = a pre-folders index, upgraded on load.
        var version: Int?
        var documents: [KBDocument]
        var folders: [KBFolder]?
        var chunks: [KBChunk]
    }
```

In `load()`, replace the three lines after `let store = try JSONDecoder()...` with:

```swift
            let store = try JSONDecoder().decode(Store.self, from: data)
            chunks = store.chunks
            folders = store.folders ?? []
            // Legacy is decided per store, never per document: a new No-folder,
            // Same-as-folder document writes neither key either.
            if store.version == nil {
                documents = store.documents.map { $0.migrated() }
                upgradedFromLegacy = true
            } else {
                documents = store.documents
            }
```

```swift
    private func save() {
        guard persistent else { return }
        guard let data = try? JSONEncoder().encode(
            Store(version: 2, documents: documents, folders: folders, chunks: chunks)) else { return }
        if upgradedFromLegacy {
            // One copy of the pre-folders index, in case anyone goes back.
            let backup = Self.storeURL.deletingLastPathComponent()
                .appendingPathComponent("index-backup-before-folders.json")
            if !FileManager.default.fileExists(atPath: backup.path) {
                try? FileManager.default.copyItem(at: Self.storeURL, to: backup)
            }
            upgradedFromLegacy = false
        }
        try? data.write(to: Self.storeURL, options: .atomic)
    }
```

In `Parrot/Models/KnowledgeBase.swift`, stop writing the old tags: add to `KBDocument` (after `init(from:)`):

```swift
    /// `profileIDs` is never written: it exists only to upgrade old indexes.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(note, forKey: .note)
        try c.encode(chunkCount, forKey: .chunkCount)
        try c.encode(addedAt, forKey: .addedAt)
        try c.encodeIfPresent(folderID, forKey: .folderID)
        try c.encodeIfPresent(scope, forKey: .scope)
    }
```

- [ ] **Step 4: Rewire the callers**

`Parrot/Services/CallAnalysisEngine.swift:412`, replace the `knownDocumentNames:` line with:

```swift
            knownDocumentNames: knowledgeBase?.documentsInPlay(for: profile?.id) ?? [],
```

`Parrot/CopilotHarness.swift:34-36`, replace the two lines from `let profiles = ProfilePresets.all()` through the `print(...)` with:

```swift
            kb.setScope(.all, for: doc)
            print("kb-add: \(doc.name) → \(doc.chunkCount) chunks, used on all call types (already there: \(before))")
```

`Parrot/SnapshotTool.swift:424-429`, replace `profileIDs: Set([salesProfile?.id].compactMap { $0 })` in both documents with `scope: .only(Set([salesProfile?.id].compactMap { $0 }))` (Task 4 replaces this seed with folders).

`Parrot/Views/SettingsView.swift`, in the old `KBDocumentRow` (Task 3 deletes it): chip state and toggle become:

```swift
                        TagChip(label: profile.name, on: knowledgeBase.isInPlay(document, callType: profile.id))
```

```swift
    private func toggle(_ profile: CallProfile) {
        let next = knowledgeBase.effectiveScope(of: document).toggling(profile.id, allTypes: profiles.map(\.id))
        knowledgeBase.setScope(next, for: document)
    }
```

`Parrot/Views/ProfilesSettingsView.swift`: replace the `// MARK: Knowledge Documents section` card (lines ~242-254) with:

```swift
            // MARK: Knowledge Documents section
            // Read-only: Use for is set on the Knowledge page (folders and
            // documents); one editor per setting.
            SettingsCard(title: "Knowledge Documents", blurb: "Documents this profile can use.") {
                let docs = knowledgeBase.documents
                    .filter { knowledgeBase.isInPlay($0, callType: profile.id) }
                    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                ForEach(Array(docs.enumerated()), id: \.element.id) { index, doc in
                    SettingsRow(first: index == 0) {
                        HStack(spacing: 12) {
                            Text(doc.displayName)
                                .font(Theme.Typography.body)
                                .lineLimit(1)
                            Spacer(minLength: 12)
                            Text(knowledgeBase.folders.first { $0.id == doc.folderID }?.name ?? "No folder")
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Colors.ink3)
                                .lineLimit(1)
                        }
                    }
                }
                SettingsRow(first: docs.isEmpty) {
                    Hint("Change which documents a call type uses on the Knowledge page.")
                }
            }
```

and delete the whole `// MARK: - Doc Tag Toggle` / `private struct DocTagToggle` block.

- [ ] **Step 5: Run the tests**

Run: `swift build 2>&1 | grep -E "error:|Build complete" && .build/debug/Parrot --profile-test | grep -E "^FAIL|kb|ALL PASS|FAILURES"`
Expected: all `kb:` and `kb upgrade:` lines PASS, `ALL PASS`. Then `grep -rn "setProfiles\|documentNames(for" Parrot` returns nothing.

- [ ] **Step 6: Commit**

```bash
git add Parrot/Models/KnowledgeBase.swift Parrot/Services/KnowledgeBaseService.swift Parrot/Services/CallAnalysisEngine.swift Parrot/CopilotHarness.swift Parrot/SnapshotTool.swift Parrot/Views/SettingsView.swift Parrot/Views/ProfilesSettingsView.swift Parrot/ProfileTest.swift
git commit -m "Knowledge: folders and Use for in the service; one in-play rule; index v2 upgrade with backup

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: The Knowledge screen

**Files:**
- Create: `Parrot/Views/KnowledgeSettingsView.swift`
- Modify: `Parrot/Views/SettingsCards.swift` (`SettingsRow` gets `tint`)
- Modify: `Parrot/Views/Theme.swift` (`Metrics.tagInsetH`, `tagInsetV`, `offDash`)
- Modify: `Parrot/Views/SettingsView.swift` (route `.knowledge` to the new view; delete `knowledgePage`, the old `KBDocumentRow`, `allProfiles`, `showFileImporter`)
- Test: `Parrot/ProfileTest.swift` (new `testKnowledgeList`)

**Interfaces:**
- Consumes: Task 2's service API (`folders`, `documents(in:)`, `createFolder`, `renameFolder`, `setScope` ×2, `deleteFolder`, `move`, `addDocuments(at:into:)`, `updateNote`, `removeDocument`, `isIndexing`, `lastError`); Task 1's `KBScope.toggling`, `KBDocument.displayName`.
- Produces: `struct KnowledgeSettingsView: View` (no init args; reads `RecordingManager` from the environment); `enum KnowledgeList` with `enum Pill: Equatable { case sameAsFolder, allTypes(own: Bool), types([String], own: Bool), notUsed, paused }`, `static func pill(own: KBScope?, inherited: KBScope?, profiles: [CallProfile]) -> Pill`, `static func matches(_ document: KBDocument, _ query: String) -> Bool`, `static func deleteMessage(count: Int) -> String`, `static func toggled(_ key: String, in raw: String) -> String`.

- [ ] **Step 1: Write the failing test**

Add to `ProfileTest.swift`, call from `run()` after `testKnowledgeStoreUpgrade()`:

```swift
    @MainActor
    static func testKnowledgeList() {
        let presets = ProfilePresets.all()
        guard let sales = presets.first(where: { $0.name == "Sales discovery" }),
              let vendor = presets.first(where: { $0.name == "Vendor call" }) else {
            check("kb list: presets present", false); return
        }
        typealias L = KnowledgeList
        check("kb list: inheriting shows Same as folder", L.pill(own: nil, inherited: .only([sales.id]), profiles: presets) == .sameAsFolder)
        check("kb list: No folder default shows Same as folder", L.pill(own: nil, inherited: .all, profiles: presets) == .sameAsFolder)
        check("kb list: own types are highlighted", L.pill(own: .only([vendor.id]), inherited: .all, profiles: presets) == .types(["Vendor call"], own: true))
        check("kb list: a folder's types are not highlighted", L.pill(own: .only([sales.id]), inherited: nil, profiles: presets) == .types(["Sales discovery"], own: false))
        check("kb list: inheriting off shows not used", L.pill(own: nil, inherited: .off, profiles: presets) == .notUsed)
        check("kb list: an off folder shows paused", L.pill(own: .off, inherited: nil, profiles: presets) == .paused)
        check("kb list: only deleted call types shows not used", L.pill(own: .only([UUID()]), inherited: .all, profiles: presets) == .notUsed)

        let doc = KBDocument(name: "05 - Service agreement.md", note: "Signed görüşme notes", chunkCount: 1, addedAt: .now)
        check("kb list: search ignores case", L.matches(doc, "SERVICE"))
        check("kb list: search reads the About line, accents ignored", L.matches(doc, "gorusme"))
        check("kb list: a blank search matches", L.matches(doc, "  "))
        check("kb list: search misses", !L.matches(doc, "invoice"))

        check("kb list: delete message counts",
              L.deleteMessage(count: 9) == "Its 9 documents move to No folder and keep their settings."
                && L.deleteMessage(count: 1) == "Its document moves to No folder and keeps its settings.")
        check("kb list: closing then opening a folder", L.toggled("a", in: "b") == "a,b" && L.toggled("a", in: "a,b") == "b")
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift build 2>&1 | grep -E "error:|Build complete"`
Expected: `cannot find 'KnowledgeList' in scope`.

- [ ] **Step 3: Theme and row tint**

`Parrot/Views/Theme.swift`, inside `enum Metrics` after `chipInsetV`:

```swift
        /// Tag-sized pills (Knowledge Use for): horizontal / vertical inset.
        static let tagInsetH: CGFloat = 8
        static let tagInsetV: CGFloat = 4
        /// Dashed outline for "off" states (paused folder, unused document).
        static let offDash: [CGFloat] = [3, 2]
```

`Parrot/Views/SettingsCards.swift`, `SettingsRow`:

```swift
struct SettingsRow<Content: View>: View {
    var first = false
    /// A header row's fill (Knowledge folders).
    var tint: Color? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !first { Divider() }
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(tint ?? .clear)
        }
    }
}
```

- [ ] **Step 4: Create `Parrot/Views/KnowledgeSettingsView.swift`**

```swift
import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Settings → Knowledge: documents in folders. A folder's Use for decides
/// which calls the Assistant may quote its documents on; a document can have
/// its own. The rule itself lives in `KnowledgeBaseService.isInPlay`.
struct KnowledgeSettingsView: View {
    @Environment(RecordingManager.self) private var recordingManager
    @Query(sort: \CallProfile.sortOrder) private var profiles: [CallProfile]
    @State private var search = ""
    @State private var importing = false
    /// The folder the file picker adds into (nil = No folder).
    @State private var importFolder: UUID?
    @State private var deleting: KBFolder?
    @State private var renamingID: UUID?
    @State private var renameText = ""
    @FocusState private var renameFocused: Bool
    /// Closed folders, comma-separated ids ("none" = No folder).
    @AppStorage("knowledgeClosedFolders") private var closedRaw = ""

    private var kb: KnowledgeBaseService { recordingManager.knowledgeBase }
    private var closed: Set<String> { Set(closedRaw.split(separator: ",").map(String.init)) }

    var body: some View {
        SettingsPage {
            SettingsCard(
                title: "Documents",
                blurb: "The Assistant grounds its answers in these and cites the source. Indexed on this Mac, never uploaded."
            ) {
                SettingsRow(first: true) { toolbar }
                if kb.isIndexing || kb.lastError != nil {
                    SettingsRow { status }
                }
                if kb.documents.isEmpty && kb.folders.isEmpty {
                    SettingsRow {
                        Text("No documents yet. Add a pricing sheet or an FAQ and the Assistant can quote it.")
                            .font(Theme.Typography.secondary)
                            .foregroundStyle(Theme.Colors.ink3)
                    }
                }
                ForEach(kb.folders) { folder in
                    let docs = kb.documents(in: folder.id).filter { KnowledgeList.matches($0, search) }
                    if search.isEmpty || !docs.isEmpty {
                        section(folder, docs: docs)
                    }
                }
                let loose = kb.documents(in: nil).filter { KnowledgeList.matches($0, search) }
                if !loose.isEmpty {
                    section(nil, docs: loose)
                }
            }
        }
        .fileImporter(
            isPresented: $importing,
            allowedContentTypes: [.pdf, .plainText, .text],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                let folder = importFolder
                Task { await kb.addDocuments(at: urls, into: folder) }
            }
        }
        .confirmationDialog(
            "Delete “\(deleting?.name ?? "")”?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            presenting: deleting
        ) { folder in
            Button("Delete folder", role: .destructive) { kb.deleteFolder(folder) }
        } message: { folder in
            Text(KnowledgeList.deleteMessage(count: kb.documents(in: folder.id).count))
        }
    }

    private var toolbar: some View {
        HStack(spacing: Theme.Metrics.controlGap) {
            TextField("Search documents", text: $search)
                .textFieldStyle(.roundedBorder)
            Button("New folder") {
                let folder = kb.createFolder(name: "New folder")
                renameText = folder.name
                renamingID = folder.id
            }
            Button("Add documents…") {
                importFolder = nil
                importing = true
            }
        }
    }

    private var status: some View {
        HStack(spacing: Theme.Metrics.controlGap) {
            if kb.isIndexing {
                ProgressView().controlSize(.small)
                Text("Embedding on this Mac…")
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(Theme.Colors.ink2)
            }
            if let error = kb.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(Theme.Colors.warn)
            }
        }
    }

    /// A folder header (nil = No folder) and, when open, its documents.
    @ViewBuilder
    private func section(_ folder: KBFolder?, docs: [KBDocument]) -> some View {
        let key = folder?.id.uuidString ?? "none"
        let open = !search.isEmpty || !closed.contains(key)
        let paused = folder?.scope == .off
        SettingsRow(tint: Theme.Colors.panel) {
            HStack(spacing: 8) {
                Button {
                    closedRaw = KnowledgeList.toggled(key, in: closedRaw)
                } label: {
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.ink2)
                }
                .buttonStyle(.plain)
                Image(systemName: folder == nil ? "tray" : "folder")
                    .foregroundStyle(paused ? Theme.Colors.ink3 : Theme.Colors.ink2)
                if let folder, renamingID == folder.id {
                    TextField("Folder name", text: $renameText)
                        .textFieldStyle(.plain)
                        .font(Theme.Typography.cardTitle)
                        .focused($renameFocused)
                        .onAppear { renameFocused = true }
                        .onSubmit { commitRename(folder) }
                        .onExitCommand { renamingID = nil }
                        .onChange(of: renameFocused) { _, focused in
                            if !focused, renamingID == folder.id { commitRename(folder) }
                        }
                } else {
                    Text(folder?.name ?? "No folder")
                        .font(Theme.Typography.cardTitle)
                        .foregroundStyle(paused ? Theme.Colors.ink2 : Theme.Colors.ink)
                        .lineLimit(1)
                }
                Text(docs.count == 1 ? "1 document" : "\(docs.count) documents")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.ink3)
                Spacer(minLength: 8)
                if let folder {
                    ScopeMenu(own: folder.scope, inherited: nil, profiles: profiles) {
                        kb.setScope($0 ?? .all, for: folder)
                    }
                    Menu {
                        Button("Rename") {
                            renameText = folder.name
                            renamingID = folder.id
                        }
                        Button("Add documents here…") {
                            importFolder = folder.id
                            importing = true
                        }
                        Divider()
                        Button("Delete folder…", role: .destructive) { deleting = folder }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                } else {
                    Text("All call types")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.ink3)
                }
            }
        }
        .dropDestination(for: String.self) { ids, _ in
            for id in ids.compactMap(UUID.init(uuidString:)) {
                if let document = kb.documents.first(where: { $0.id == id }) {
                    kb.move(document, to: folder?.id)
                }
            }
            return true
        }
        if open {
            ForEach(docs) { document in
                SettingsRow {
                    KBDocumentRow(document: document, folders: kb.folders, profiles: profiles, knowledgeBase: kb)
                }
            }
        }
    }

    private func commitRename(_ folder: KBFolder) {
        kb.renameFolder(folder, to: renameText)
        renamingID = nil
    }
}

// MARK: - Document row

/// One document: name, Use for, size and menu, with the About line under it.
struct KBDocumentRow: View {
    let document: KBDocument
    let folders: [KBFolder]
    let profiles: [CallProfile]
    let knowledgeBase: KnowledgeBaseService

    @State private var about: String
    @FocusState private var editingAbout: Bool
    /// Removal asks first: a document is work the user prepared.
    @State private var confirmingRemove = false

    init(document: KBDocument, folders: [KBFolder], profiles: [CallProfile], knowledgeBase: KnowledgeBaseService) {
        self.document = document
        self.folders = folders
        self.profiles = profiles
        self.knowledgeBase = knowledgeBase
        _about = State(initialValue: document.note)
    }

    private var inherited: KBScope { folders.first { $0.id == document.folderID }?.scope ?? .all }
    private var unused: Bool {
        KnowledgeList.pill(own: document.scope, inherited: inherited, profiles: profiles) == .notUsed
    }
    private var isPDF: Bool { document.name.lowercased().hasSuffix(".pdf") }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(systemName: isPDF ? "doc.richtext" : "doc.text")
                    .foregroundStyle(unused ? Theme.Colors.ink3 : Theme.Colors.accent)
                Text(document.displayName)
                    .font(Theme.Typography.sans(13, .medium))
                    .foregroundStyle(unused ? Theme.Colors.ink2 : Theme.Colors.ink)
                    .lineLimit(1)
                    .help(document.name)
                Spacer(minLength: 8)
                ScopeMenu(own: document.scope, inherited: inherited, profiles: profiles) {
                    knowledgeBase.setScope($0, for: document)
                }
                Text("\(document.chunkCount) chunks")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.ink3)
                    .monospacedDigit()
                    .lineLimit(1)
                Menu {
                    Menu("Move to folder") {
                        ForEach(folders) { folder in
                            Button(folder.name) { knowledgeBase.move(document, to: folder.id) }
                                .disabled(folder.id == document.folderID)
                        }
                        Divider()
                        Button("No folder") { knowledgeBase.move(document, to: nil) }
                            .disabled(document.folderID == nil)
                    }
                    Button("Edit about line") { editingAbout = true }
                    Divider()
                    Button("Remove…", role: .destructive) { confirmingRemove = true }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .contentShape(Rectangle())
            .draggable(document.id.uuidString)
            TextField("Add a line about this document", text: $about)
                .textFieldStyle(.plain)
                .font(Theme.Typography.secondary)
                .foregroundStyle(Theme.Colors.ink2)
                .focused($editingAbout)
                .onSubmit { saveAbout() }
                .onChange(of: editingAbout) { _, editing in if !editing { saveAbout() } }
                .padding(.leading, 24)
        }
        .confirmationDialog("Remove \(document.displayName)?", isPresented: $confirmingRemove) {
            Button("Remove", role: .destructive) { knowledgeBase.removeDocument(document) }
        } message: {
            Text("The Assistant stops using it right away. You can add the file again any time.")
        }
    }

    private func saveAbout() {
        if about != document.note { knowledgeBase.updateNote(about, for: document) }
    }
}

// MARK: - Use for pill and menu

/// The Use for pill and its menu. Folders pass `inherited: nil`; documents
/// pass their folder's scope (No folder: `.all`).
private struct ScopeMenu: View {
    let own: KBScope?
    let inherited: KBScope?
    let profiles: [CallProfile]
    let set: (KBScope?) -> Void

    private var effective: KBScope { own ?? inherited ?? .all }

    var body: some View {
        Menu {
            if inherited != nil {
                Toggle("Same as folder", isOn: choice(own == nil) { set(nil) })
                Divider()
            }
            Toggle("All call types", isOn: choice(own == .all) { set(.all) })
            Divider()
            ForEach(profiles) { profile in
                Toggle(profile.name, isOn: choice(ticked(profile.id)) {
                    // From Same as folder this starts from the folder's set.
                    set(effective.toggling(profile.id, allTypes: profiles.map(\.id)))
                })
            }
            Divider()
            Toggle("Off, not used on calls", isOn: choice(own == .off) { set(.off) })
        } label: {
            ScopePill(pill: KnowledgeList.pill(own: own, inherited: inherited, profiles: profiles))
        }
        // .button + .plain keeps the pill's own look (borderless flattens it).
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
        .help("Which calls the Assistant may use this on")
    }

    private func ticked(_ id: UUID) -> Bool {
        if case .only(let ids) = effective { return ids.contains(id) }
        return false
    }

    /// A menu checkmark that runs `action` when picked.
    private func choice(_ isOn: Bool, _ action: @escaping () -> Void) -> Binding<Bool> {
        Binding(get: { isOn }, set: { _ in action() })
    }
}

private struct ScopePill: View {
    let pill: KnowledgeList.Pill

    var body: some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon) }
            Text(text)
            Image(systemName: "chevron.down")
        }
        .font(Theme.Typography.caption)
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, Theme.Metrics.tagInsetH)
        .padding(.vertical, Theme.Metrics.tagInsetV)
        .foregroundStyle(foreground)
        .background(background, in: RoundedRectangle(cornerRadius: Theme.Metrics.chipRadius))
        .overlay {
            if dashed {
                RoundedRectangle(cornerRadius: Theme.Metrics.chipRadius)
                    .strokeBorder(Theme.Colors.line, style: StrokeStyle(lineWidth: 1, dash: Theme.Metrics.offDash))
            }
        }
        .contentShape(Rectangle())
    }

    private var text: String {
        switch pill {
        case .sameAsFolder: "Same as folder"
        case .allTypes: "All call types"
        case .types(let names, _): names.count <= 2 ? names.joined(separator: ", ") : "\(names[0]) +\(names.count - 1)"
        case .notUsed: "Not used on calls"
        case .paused: "Off"
        }
    }

    private var icon: String? {
        switch pill {
        case .notUsed: "eye.slash"
        case .paused: "pause.fill"
        default: nil
        }
    }

    private var dashed: Bool { pill == .notUsed || pill == .paused }

    private var highlighted: Bool {
        switch pill {
        case .allTypes(let own), .types(_, let own): own
        default: false
        }
    }

    private var foreground: Color { dashed ? Theme.Colors.ink3 : highlighted ? Theme.Colors.accent : Theme.Colors.ink2 }
    private var background: Color { dashed ? .clear : highlighted ? Theme.Colors.selection : Theme.Colors.chip }
}

// MARK: - Pure helpers

/// The Knowledge page's decisions, kept pure for --profile-test.
enum KnowledgeList {
    /// What a Use for pill says.
    enum Pill: Equatable {
        case sameAsFolder
        case allTypes(own: Bool)
        case types([String], own: Bool)
        case notUsed
        case paused
    }

    /// Documents pass their folder's scope (No folder: `.all`) as
    /// `inherited`; folders pass nil. Deleted call types are ignored.
    static func pill(own: KBScope?, inherited: KBScope?, profiles: [CallProfile]) -> Pill {
        let isDocument = inherited != nil
        let effective = own ?? inherited ?? .all
        switch effective {
        case .off:
            return isDocument ? .notUsed : .paused
        case .only(let ids):
            let names = profiles.filter { ids.contains($0.id) }.map(\.name)
            if names.isEmpty { return .notUsed }
            return isDocument && own == nil ? .sameAsFolder : .types(names, own: isDocument)
        case .all:
            return isDocument && own == nil ? .sameAsFolder : .allTypes(own: isDocument)
        }
    }

    /// Search: name or About line, ignoring case and accents.
    static func matches(_ document: KBDocument, _ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty || document.name.localizedStandardContains(q) || document.note.localizedStandardContains(q)
    }

    static func deleteMessage(count: Int) -> String {
        switch count {
        case 0: "It's empty."
        case 1: "Its document moves to No folder and keeps its settings."
        default: "Its \(count) documents move to No folder and keep their settings."
        }
    }

    /// Opens or closes one folder in the stored set ("none" = No folder).
    static func toggled(_ key: String, in raw: String) -> String {
        var keys = Set(raw.split(separator: ",").map(String.init))
        if keys.contains(key) { keys.remove(key) } else { keys.insert(key) }
        return keys.sorted().joined(separator: ",")
    }
}
```

- [ ] **Step 5: Route Settings to it**

In `Parrot/Views/SettingsView.swift`:
- `case .knowledge: knowledgePage` → `case .knowledge: KnowledgeSettingsView()`
- delete `private var knowledgePage: some View { ... }` (the whole `// MARK: - Knowledge` block through its `.fileImporter`), the old `// MARK: - Knowledge Base Document Row` / `struct KBDocumentRow` block, and the now-unused `@Query(sort: \CallProfile.sortOrder) private var allProfiles` and `@State private var showFileImporter` (check with `grep -n "allProfiles\|showFileImporter" Parrot/Views/SettingsView.swift` that nothing else uses them first).

- [ ] **Step 6: Run the tests**

Run: `swift build 2>&1 | grep -E "error:|Build complete" && .build/debug/Parrot --profile-test | grep -E "^FAIL|kb|ALL PASS|FAILURES"`
Expected: all `kb list:` lines PASS, `ALL PASS`.

- [ ] **Step 7: Commit**

```bash
git add Parrot/Views/KnowledgeSettingsView.swift Parrot/Views/SettingsCards.swift Parrot/Views/Theme.swift Parrot/Views/SettingsView.swift Parrot/ProfileTest.swift
git commit -m "Knowledge: folders screen with Use for pills, About lines, search and drag to move

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Screens, real data check, docs, PR

**Files:**
- Modify: `Parrot/SnapshotTool.swift:423-429` (seed with folders)
- Modify: `FILEMAP.md`
- No commits of rendered images (the help screenshot is redone at release by `/release-docs`).

**Interfaces:**
- Consumes: everything above.
- Produces: the PR.

- [ ] **Step 1: Seed the help shot with folders**

Replace the `// Two documents so the Knowledge page...` seed in `SnapshotTool.swift` with:

```swift
        // Folders, an own Use for, an off folder and an unused document, so
        // the Knowledge page shows every state.
        let vendorProfile = (try? context.fetch(FetchDescriptor<CallProfile>()))?
            .first { $0.name == "Vendor call" }
        let dealFolder = KBFolder(name: "Acme deal", scope: .only(Set([salesProfile?.id].compactMap { $0 })))
        let oldFolder = KBFolder(name: "Old deals", scope: .off)
        rm.knowledgeBase.seedForSnapshot(documents: [
            KBDocument(name: "security-faq.pdf", note: "Security and data answers for buyers",
                       chunkCount: 14, addedAt: .now, folderID: dealFolder.id),
            KBDocument(name: "pricing-2026.md", note: "Plans and discounts, 2026",
                       chunkCount: 9, addedAt: .now, folderID: dealFolder.id),
            KBDocument(name: "mutual-nda.md", note: "Signed NDA, Sept 2026", chunkCount: 4, addedAt: .now,
                       folderID: dealFolder.id, scope: .only(Set([vendorProfile?.id].compactMap { $0 }))),
            KBDocument(name: "northwind-proposal.md", chunkCount: 12, addedAt: .now, folderID: oldFolder.id),
            KBDocument(name: "roadmap.md", chunkCount: 20, addedAt: .now, scope: .off),
        ], folders: [dealFolder, oldFolder])
```

- [ ] **Step 2: Render and look, light and dark**

```bash
SHOTS=$(mktemp -d)
swift build 2>&1 | grep -E "error:|Build complete"
.build/debug/Parrot --help-shots "$SHOTS" >/dev/null && cp "$SHOTS/settings-knowledge.png" "$SHOTS/light.png"
.build/debug/Parrot --help-shots "$SHOTS" -AppleInterfaceStyle Dark >/dev/null && cp "$SHOTS/settings-knowledge.png" "$SHOTS/dark.png"
echo "$SHOTS"
```

Open `light.png` and `dark.png` (Read tool) and check, at 780×620: folder headers tinted, "Acme deal" pill "Sales discovery", NDA pill blue "Vendor call", "Old deals" dashed "Off", roadmap dashed "Not used on calls" under No folder, no clipped text, chunk counts on one line, readable in dark. Fix anything off in `KnowledgeSettingsView.swift` and re-render.

- [ ] **Step 3: Upgrade the owner's real index, on a copy**

```bash
KB=$(mktemp -d)
cp "$HOME/Library/Containers/com.uygar.parrot/Data/Library/Application Support/Parrot/KnowledgeBase/index.json" "$KB/index.json"
printf '# Probe\n\nA tiny test document.\n' > "$KB/probe.md"
PARROT_KB_INDEX="$KB/index.json" .build/debug/Parrot --kb-add "$KB/probe.md"
python3 - "$KB" <<'EOF'
import json, sys, os, collections
d = json.load(open(os.path.join(sys.argv[1], "index.json")))
kinds = collections.Counter(next(iter(x["scope"])) if "scope" in x else "same-as-folder" for x in d["documents"])
print("version", d.get("version"), "| docs", len(d["documents"]), "| folders", len(d.get("folders", [])), "|", dict(kinds))
print("backup", os.path.exists(os.path.join(sys.argv[1], "index-backup-before-folders.json")))
print("profileIDs written:", any("profileIDs" in x for x in d["documents"]))
EOF
```

Expected (owner's index, 15 documents + probe): `version 2 | docs 16 | folders 0 | {'only': 11, 'off': 4, 'all': 1}`, `backup True`, `profileIDs written: False`. Then `rm -rf "$KB"`. The real index is untouched (only the copy was opened).

- [ ] **Step 4: FILEMAP**

Update rows in `FILEMAP.md` (line counts from `wc -l`):
- `Models/KnowledgeBase.swift`: "KB document/chunk/reference value types; `KBScope` (Use for: all / only / off), `KBFolder`, upgrade from tags"
- `Services/KnowledgeBaseService.swift`: append "; folders and Use for, `isInPlay` (the one rule for what the Assistant may quote), index v2 upgrade + backup"
- `Views/SettingsView.swift`: refresh the line count (Knowledge moved out)
- `Views/ProfilesSettingsView.swift`: "…; read-only list of documents a profile can use"
- `Views/SettingsCards.swift`: "…; rows can take a header tint"
- new row after `SettingsCards.swift`: `| \`Views/KnowledgeSettingsView.swift\` | <lines> | Settings → Knowledge: folders, Use for pills and menu, About line, search, drag to move; \`KnowledgeList\` pure helpers |`

- [ ] **Step 5: Full test run and commit**

Run: `make test 2>&1 | tail -2`
Expected: `ALL PASS`.

```bash
git add Parrot/SnapshotTool.swift FILEMAP.md
git commit -m "Knowledge: folder states in the help shot; file map

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

- [ ] **Step 6: Push and open the PR**

```bash
git push -u origin feat/kb-folders
```

PR to `master`, title "Knowledge folders: Use for on folders and documents, visible Off, About line". Body (plain punctuation, no em-dashes, no real names): what changed, the empty-means-nowhere fix and that 4 of the owner's documents will read "Not used on calls" after updating, the upgrade + backup, the Profiles page becoming read-only, screenshots from Step 2, test counts, and the owner's live check after release: one call where the Copilot log shows an excerpt from a folder-scoped document. End with `🤖 Generated with [Claude Code](https://claude.com/claude-code)`.
