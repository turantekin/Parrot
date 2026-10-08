# Knowledge folders: design

Date: 2026-10-06.
Status: **approved in brainstorming, not built.** Base: master at `67c81ea`
(0.26.0). Branch `feat/kb-folders`. Ships in the same release as the
search/Home CPU fix (#106), which touches `SidebarView`/`DashboardView`, not
these files.

## 1. Problem

Settings → Knowledge is one flat list. With the owner's 15 documents it is
already hard to see what is what:

- Every row repeats all seven "Use for" call-type chips, so rows are three
  lines tall and the page scrolls for screens.
- The "When should the Assistant use this?" field is empty on all 15
  documents. It is noise shown 15 times.
- Documents fall into obvious groups (company basics, one deal's nine
  numbered files, one-off call briefs) that the list can't show.

And the list hides a real bug. `KBDocument.profileIDs` is documented as
"Empty = unscoped (all-profiles)", but `search(profileID:)` and
`documentsInPlay(for:)` treat empty as **nowhere**, and every call has a
profile (`ProfileStore.activeProfile` falls back to the first one). So a
document with no chips is never used on any call. Four of the owner's
documents (roadmap, plan, two briefings) have silently never reached the
Assistant.

## 2. Decisions (with the owner)

| Question | Choice |
|---|---|
| Shape | **Folders** (option B): one folder per document, collapsible, no nesting |
| Where "Use for" lives | **On the folder, and a document can have its own** |
| Folder vs document | **Replace**: a document is "Same as folder" or its own setting, which fully replaces the folder's |
| Upgrade, documents with no chips | **Keep them off, and say so**: shown as "Not used on calls"; nothing switches on behind anyone's back |
| The note field | Becomes a one-line **About** ("Signed service agreement, Sept 2026"), same storage, still sent to the Assistant |

## 3. Rules

**Scope.** Folders and documents carry a scope with three states:

- `all`: every call type.
- `only(Set<call type id>)`: those call types.
- `off`: never used on calls.

**Resolution** (the one rule, one function):

```
effective(document) = document.scope ?? folder(document)?.scope ?? .all
inPlay(document, callType) = effective(document) is .all
                           or .only(ids) where ids contains callType
```

`callType == nil` (harnesses, back-compat callers) means every document
that isn't `off`.

**Folders.** A new folder starts at `all`. "No folder" is not stored: it is
the documents with `folderID == nil`, and its scope is always `all`, so a
newly added document is used rather than silently idle.

**Documents.** `scope == nil` shows as "Same as folder".

- Moving a "Same as folder" document adopts the new folder's scope. A
  document with its own scope keeps it.
- Deleting a folder never deletes documents. Each document that was "Same
  as folder" first gets the folder's scope copied as its own, then moves to
  No folder. Effective behaviour is unchanged.
- Re-adding a file with the same name (today: replaces it, keeps the note)
  also keeps `folderID` and `scope`. Adding into a folder (folder menu "Add
  documents here") sets `folderID`.

**Deleted call types.** Ids of deleted profiles are ignored at resolution
and hidden in the UI. An `only` set whose ids are all gone behaves as
`off` and is shown as "Not used on calls".

**Upgrade** (one pure function `migrate(legacy document) -> KBDocument`):

- `folderID = nil` for everyone. No folders are created.
- Chips present: `scope = .only(profileIDs)`.
- No chips: `scope = .off`.

Effective behaviour is identical before and after; only now it is visible.

## 4. Data

`Models/KnowledgeBase.swift`:

```swift
enum KBScope: Codable, Equatable { case all, only(Set<UUID>), off }

struct KBFolder: Codable, Identifiable {
    var id = UUID()
    var name: String
    var scope: KBScope = .all
}

struct KBDocument {            // existing type, new fields
    var folderID: UUID?        // nil = No folder
    var scope: KBScope?        // nil = Same as folder
    // `note` stays the stored name of the About line.
    // `profileIDs` is decoded only to migrate; it is no longer written.
}
```

`index.json` gains `version: 2` and `folders: [KBFolder]`. Every new key
decodes with `decodeIfPresent` and a default, following the existing comment
in `KBDocument.init(from:)`: a strict decode failure would empty the KB on
the next save. **A store without `version` is legacy**: every document goes
through `migrate` once, then the store is saved as version 2. Legacy is
decided per store, never per document: a new document in No folder that is
"Same as folder" has neither `folderID` nor `scope` written, and must not be
mistaken for a legacy one (it would turn `off`).

**Backup.** On the first save after a legacy load, copy the existing file to
`index-backup-before-folders.json` (once; skip if it exists). Precedent:
`index-backup-*.json` files from the 0.20 embedding migration.

**Downgrade.** An older build reads the new file with no `profileIDs`, so
every document would look unused on calls. Accepted: Sparkle never
downgrades, and someone who installs an older build by hand can restore
`index-backup-before-folders.json`.

## 5. Service (`KnowledgeBaseService`)

- State: `folders: [KBFolder]` next to `documents`.
- Folders: `createFolder(name:) -> KBFolder`, `renameFolder`, `setScope(_:for folder:)`, `deleteFolder` (rules above).
- Documents: `setScope(_ scope: KBScope?, for document:)`, `move(_ document:, to folderID: UUID?)`, `addDocuments(at:into folderID:)` (existing `addDocuments(at:)` calls it with `nil`).
- Resolution: `effectiveScope(of:) -> KBScope` and `isInPlay(_:callType:) -> Bool`, the only place the rule lives.
- Callers rewired to `isInPlay`: `search(query:profileID:topK:)` (all three `CallAnalysisEngine` call sites and the Jev fast path go through it), `documentsInPlay(for:)` (Home Assistant card, call brief), `documentNames(for:)`.
- `copyProfileTags(from:to:)` (a built-in call type added after install starts with Default's documents): insert `to` into every folder and document `only` set containing `from`. Duplicating a call type does not call it (true before this change too).
- `tagAllDocuments(into:)` (first-ever profile seeding, pre-profiles stores): insert into each document's `only` set, turning `off` into `only([id])`. Runs after migration, so very old stores keep working as before.
- `setProfiles(_:for:)` is replaced by `setScope`.

## 6. Screen

A new `Views/KnowledgeSettingsView.swift` holds the Knowledge section (moved
out of `SettingsView.swift`, 970 lines). Theme tokens only, no hard-coded
colours or paddings.

**Header:** "Documents", a "Search documents" field, "New folder", "Add
documents" (adds to No folder).

**Folder header:** disclosure chevron, folder icon, name, "N documents",
scope pill, ⋯ menu (Rename, Add documents here, Delete folder). Open/closed
state is remembered per folder (`@AppStorage`, a set of ids). A folder at
`off` shows a dashed "Off" pill with a pause icon and greyed name. No folder
comes last, shows "All call types" as plain text (not a menu), and appears
only when it has documents.

**Document row:** two lines. Line 1: type icon, name with `.md`/`.pdf`/…
hidden, scope pill, chunk count, ⋯ menu (Move to folder ▸, Edit about line,
Remove). Line 2: the About line, or the hint "Add a line about this
document"; click to edit inline, saved on commit.

**Scope pill:**

- grey "Same as folder" when inheriting;
- blue with the call type names when the document has its own;
- dashed "Not used on calls" with an eye-off icon when effectively off.

**Scope menu** (folder menu = same without the first item): ✓ Same as folder
· All call types · each call type as a toggle · Off, not used on calls.
Toggling a call type while "Same as folder" starts from the folder's set.

**Move:** drag a row onto a folder header or onto No folder, or use "Move
to folder ▸" (lists folders, then "No folder").

**Search:** filters by document name and About line across folders;
folders with a match open while searching; empty folders hide while
searching.

**Delete folder:** confirm "Delete “Acme deal”? Its 9 documents move to No
folder and keep their settings."

**Profiles page.** Settings → Profiles has a "Knowledge Documents" card with
an on/off switch per document for the selected call type. Two editors with
different rules for one setting would bring the confusion back, so the card
becomes read-only: the documents this call type can use (`isInPlay`), each
with its folder name, and the hint "Change which documents a call type uses
on the Knowledge page." (Found while planning; owner-approved direction:
Use for lives on folders and documents.)

## 7. Testing

`--profile-test` checks:

- Resolution: document `nil` + folder `only` → folder's; document `only` beats folder `off`; No folder → `all`; `off` never in play; `nil` call type → everything not `off`.
- Delete folder: inheriting documents keep their effective scope and land in No folder.
- Move: inheriting document adopts the new folder; own scope survives.
- Upgrade: chips → `only(chips)`; none → `off`; an index with no `version`/`folders` keys loads and migrates once.
- Round trip: a version-2 store with a No-folder, "Same as folder" document saves and reloads with that document still `nil`/`nil` and in play (the per-document legacy trap).
- `copyProfileTags` reaches folder and document scopes; `tagAllDocuments` turns `off` into `only`.
- `search(profileID:)` and `documentsInPlay(for:)` honour folders; deleted call type ids are ignored.
- Existing KB checks (`testKBScoping`, lenient decode) updated, not deleted.

Screens: the Knowledge page rendered offscreen at settings size in light and
dark (help-shots style) with a seeded store: folders, an `off` folder, an
own-scope document, a "Not used on calls" document. Checked for overflow.

Real app on a store copy (recipe in memory): the owner's 15 documents load
with 4 "Not used on calls", 11 with their own call types, everything in No
folder; the backup file exists; a second launch doesn't redo the upgrade.

Live: one call where the Copilot log shows an excerpt from a document whose
scope comes from its folder.

## 8. Out of scope

Nested folders, a document in two folders, renaming documents (chunks are
keyed by file name), auto-sorting into folders, AI-written About lines. A
"Suggest folders" button can come later on top of this.

## 9. Release

Own PR from `feat/kb-folders`. At release, `/release-docs` updates the help
page for Knowledge (folders, Use for, Off, About line) and its screenshot,
and the notes call out that documents which were silently unused now say
"Not used on calls".
