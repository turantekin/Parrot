# Profiles: Share, Suggest, Gallery: Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make call profiles portable. One file format (`.parrotprofile`) carries a profile between Macs, from Claude into Parrot, and later from a public gallery and marketplace, without ever carrying anyone's meeting data or loosening privacy.

**Why:** Profiles are Parrot's most powerful feature and the hardest to set up (persona, what to flag live, trigger rules, mood meters). Claude is very good at writing them, and people who've tuned a great "Enterprise sales" or "Investor pitch" profile want to share it. Once shared profiles exist, they're a growth loop: a gallery, then a marketplace.

**Depends on:** `docs/superpowers/plans/2026-09-26-ai-apps-connect.md` (launch release: Claude can already *read* profiles via `list_profiles` / `get_profile`, and `get_profile` already emits the format below).

**Tech Stack:** Swift 5.10+, SwiftData (`CallProfile`), `ProfileStore`, `ProfilesSettingsView`, `--profile-test` harness, Makefile Info.plist substitution for the document type and URL scheme.

## Decisions (settled 2026-09-26)

1. **Claude suggests, you approve.** Claude never changes a profile directly. It sends a suggestion; Parrot shows what would change; the user applies or discards; undo is always there.
2. **Export/import ships together with Claude suggestions**, in the release right after the Claude launch. Same file, same review screen.
3. **The gallery lives on openparrot.app**, and the owner approves every submission.
4. **Paid profiles:** the format leaves room; the decision comes much later.
5. **Privacy rule:** an imported or suggested profile can make things **more** private, never less.

## Stages

| Stage | Users get | Release |
|---|---|---|
| 1. Foundation | Claude reads profiles. The format below is written down and `get_profile` emits it | Claude launch release |
| 2. Share + suggest | Export / Import / Share, double-click a `.parrotprofile` to add it, "Claude suggests, you approve", "Optimize with Claude" | Right after launch |
| 3. Gallery | Profile gallery on openparrot.app, **Browse Profiles** in Parrot, one-click install, update notices | When stage 2 gets used |
| 4. Marketplace | Creator pages, ratings, categories, maybe paid expert profiles | When there's traction |

---

## The file format (designed now, used by every stage)

A `.parrotprofile` file is UTF-8 JSON, human-readable, at most 64 KB.

```json
{
  "format": "parrot.profile",
  "formatVersion": 1,
  "sharedID": "7C1E…-stable-for-life",
  "version": 3,
  "profile": {
    "name": "Investor pitch",
    "icon": "chart.line.uptrend.xyaxis",
    "summary": "Pitching to VCs and angels.",
    "persona": "You are coaching a founder pitching …",
    "tone": "Short, direct cards.",
    "counterpart": "the investor",
    "allowGeneralKnowledge": true,
    "kinds": [
      { "key": "objection", "label": "Objection", "color": "D9534F", "icon": "exclamationmark.bubble",
        "trigger": "The investor pushes back on market size, team or traction.", "pinned": true, "priority": 2 }
    ],
    "gauges": [
      { "key": "interest", "label": "Interest", "low": "Cold", "high": "Leaning in", "color": "3F9168" }
    ]
  },
  "privacy": { "recommendOnDeviceOnly": false },
  "meta": {
    "description": "Flags objections, asks and follow-up promises on investor calls.",
    "author": "Optional name", "authorURL": "https://…",
    "language": "en", "category": "fundraising", "tags": ["vc", "seed"],
    "license": "CC-BY-4.0",
    "source": "user | claude | gallery | builtin",
    "basedOn": { "sharedID": "…", "version": 2 },
    "createdWith": "Parrot 1.8.0"
  },
  "suggestion": { "targetSharedID": "…", "reason": "Your last 10 sales calls ignored 80% of 'Small talk' cards …" }
}
```

**Rules:**
- **`sharedID` + `version`** identify a profile across Macs for life. They let the gallery say "v3 available" and let an import recognise "this is an update to a profile you have". `CallProfile` gains `sharedID: UUID?`, `sharedVersion: Int = 0` and `sharedSource: String?` (defaulted properties, so the existing store migrates). The local `id` never leaves the Mac.
- **Built-ins get fixed `sharedID`s** (their existing preset UUIDs), so the gallery can host improved versions of them too.
- **Unknown fields are kept and ignored.** A marketplace can add `price` or `creatorID` later without breaking older Parrots.
- **Never in the file:** meeting content, names from calls, knowledge-base documents or their tags, local IDs, API keys, any setting outside the profile. The export screen shows the exact contents before saving.
- **Privacy:** `recommendOnDeviceOnly: true` turns on-device-only **on** at import. Nothing in any file can turn it off; the importer ignores any attempt.
- **Limits:** at most 20 kinds and 6 gauges; `persona`/`tone` at most 4,000 characters each; other text at most 300. Colors must be 6-digit hex (else a default); an unknown SF Symbol falls back to a default icon. A file that breaks a limit is refused with a plain reason.
- **Safety:** a profile is instructions for Parrot's own AI. It can't run code, open links or send data anywhere. The worst a bad profile can do is give misleading Copilot cards, which is why every import and suggestion goes through a preview.

---

## Stage 1 (Claude launch release)

Covered by the AI-apps plan (Task 6). One extra step here:

- [ ] `Parrot/Services/ProfileFile.swift` (new, pure): `struct ProfileFile: Codable` for the format above + `encode(_ profile: CallProfile, source:) -> Data` + `decode(_ data: Data) throws -> ProfileFile` with the limits. `get_profile` uses `encode`. Harness: every built-in round-trips; the limits refuse bad files; unknown fields survive a decode/encode round trip.

## Stage 2 (right after launch): Share and suggest

### Task A: Export, Import, Share

**Files:** `ProfileFile.swift`, `ProfileStore.swift`, `ProfilesSettingsView.swift`, `ParrotApp.swift` (open-file handling), `project.yml` / Makefile Info.plist (document type `com.uygar.parrot.profile`, extension `.parrotprofile`), `ProfileTest.swift`

- [ ] Profile editor gets **Export…** (save panel) and **Share…** (the macOS share sheet: Mail, Messages, AirDrop).
- [ ] **Import…** in the profiles list, drag-and-drop onto the list, and double-clicking a `.parrotprofile` all open the **Review screen** (Task C).
- [ ] New `sharedID` → added as a new profile (`isBuiltIn = false`, `sharedSource` from `meta.source`).
- [ ] Known `sharedID` → treated as an update: if the local copy isn't user-modified, offer **Update**; if it is, offer **Keep mine / Use theirs / Keep both**.
- [ ] The profile starts with no knowledge-base documents; the Review screen says "Add your own documents after importing".

### Task B: Claude suggests (MCP)

**Files:** `MCPServer.swift`, `MCPPrompts.swift`, `ProfileFile.swift`, `ProfileTest.swift`

- [ ] New tool `suggest_profile(profile_json, reason)`. It validates with `ProfileFile.decode`, then writes the file to `Application Support/Parrot/ProfileInbox/<uuid>.parrotprofile`. It never touches SwiftData. The description says the user must approve it in Parrot. Annotations: `readOnlyHint: false`, `destructiveHint: false`.
- [ ] At most 10 files in the inbox (oldest dropped); switch-off or "Allow Claude to suggest profiles" off (new key `mcpAllowProfileSuggestions`, default on) makes the tool refuse.
- [ ] New prompts:
  - `create_profile(call_type)`: Claude asks a few questions, then calls `suggest_profile`.
  - `optimize_profile(profile, last_n = 10)`: Claude reads the profile, the last N meetings' transcripts and **Copilot cards with handled/ignored state**, finds cards that were ignored and moments that were missed, and suggests a better profile with a reason per change. Needs "Copilot cards" shared; the prompt tells Claude to ask the user to tick it if it's off.
- [ ] Harness: a valid suggestion lands in the inbox; an invalid one returns the reason and writes nothing; a suggestion trying `onDeviceOnly: false` on an on-device profile has no effect after review.

### Task C: Review screen, Apply, Undo

**Files:** `ProfileReviewView.swift` (new), `ProfileStore.swift`, `RecordingManager` or `AppSession` (inbox watcher), `Theme.swift`

- [ ] The app watches `ProfileInbox/`; a new file shows a banner: "Claude suggested changes to 'Sales discovery'. Review." (or "…a new profile: 'Investor pitch'").
- [ ] **Review screen**, shared by imports and suggestions:
  - who it came from (you / Claude / a file / the gallery) and Claude's reason
  - side-by-side changes, grouped as persona, what to flag (added / removed / changed kinds), mood meters, other
  - the privacy line when it turns on-device-only on
- [ ] Buttons: **Apply** · **Save as new profile** · **Discard**.
- [ ] **Undo:** `ProfileStore` keeps the last 5 versions of each profile (a JSON history via `ProfileFile`); the editor gets "Restore previous version".
- [ ] Applying marks the profile `isUserModified` (so preset refreshes keep it) and bumps `sharedVersion`.
- [ ] A suggestion is never applied mid-call: if a call is live with that profile, Apply waits until the call ends and says so.

### Task D: Docs

- [ ] Help: "Share and import profiles" + "Let Claude build or tune a profile" (with the two prompts).
- [ ] AI-apps page (Task 9 there): the six jobs gain a seventh, **"Tune my Copilot"**.

## Stage 3: Gallery (when stage 2 gets used)

- [ ] **Source of truth:** a public GitHub repo (e.g. `turantekin/parrot-profiles`), one `.parrotprofile` per folder with a README and a screenshot. CI validates each file with the same rules (a small script, or `Parrot --validate-profile` in CI) and builds `index.json`.
- [ ] **Submission:** a pull request, or a form on openparrot.app that opens one. The owner approves each. A profile can be reported, and the gallery can pull it.
- [ ] **Website:** openparrot.app/profiles with category pages (Sales, Hiring, Fundraising, Support, Coaching, Legal, Health), search and "Open in Parrot" buttons.
- [ ] **In the app:** **Browse Profiles** fetches `index.json` from openparrot.app. This is user-initiated and sends nothing about the user (a plain GET of public files). Install goes through the Review screen. New URL scheme `parrot://profile/install?url=…` for one-click install from the website; it only accepts `https://openparrot.app/…` URLs.
- [ ] **Update notices:** once a day, and only when the user has gallery profiles installed, compare `sharedID`/`version` against `index.json`: "Investor pitch v4 is available". Same Keep mine / Use theirs choice as imports.
- [ ] Built-in presets are published as the first gallery entries.
- [ ] License: gallery profiles are CC BY 4.0 (free to use and remix, with credit); `basedOn` records the lineage.

## Stage 4: Marketplace (decide when there's traction)

Open questions, not decided:
- **Accounts:** creator pages and ratings need identities. Reuse GitHub sign-in, or add openparrot.app accounts?
- **Quality signals:** installs and ratings would need an opt-in anonymous ping, which is a change for a local-first app. It needs its own privacy decision.
- **Paid profiles:** price, payments (e.g. Stripe or Lemon Squeezy), revenue share, refunds, and whether a paid profile can be re-shared (the CC BY gallery license wouldn't apply). The format already allows extra `meta` fields.
- **Moderation at scale:** today it's owner review; later maybe trusted reviewers.
- **Teams:** a private team gallery (a company shares its sales playbook internally) could be the first paid tier.

## Risks

| Risk | Mitigation |
|---|---|
| A shared profile gives bad or manipulative Copilot advice | Preview before install, limits, gallery review, report button; profiles can't act or send data |
| Text inside a recorded call steers Claude into a harmful suggestion | Suggestions only land in the inbox; the user sees every change; privacy can't be loosened |
| An update wipes someone's tuning | `sharedID`/`version` + `isUserModified` → Keep mine / Use theirs / Keep both; 5-version undo |
| Personal data leaks through an export | Fixed field list; KB docs, tags and IDs never exported; the export shows the full contents first |
| Format changes break old files | `formatVersion`; unknown fields kept; decoders accept every older version |

## Size

Stage 1 extra: 1 day. Stage 2: about 1.5-2 weeks (A 3 days, B 3 days, C 4-5 days, D 1 day). Stage 3: about 1 week of app work plus the website pages. Stage 4: not sized.
