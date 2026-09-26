# Handoff: Claude connection + Profiles 2.0

Planned in a cloud session on 2026-09-26. Build and test locally on the Mac.
This file is the starting point for a new local Claude Code session. It covers
the why, the decisions, where the plans are, the order of work and how to test.

---

## 1. Start here (for the owner)

In Terminal, inside your Parrot folder:

```
git fetch origin
git checkout claude/api-membership-integration-plan-pxh0td
git checkout -b claude-connection
make test
```

`make test` must end with `ALL PASS` before any work starts. Then open Claude
Code in the same folder (`claude`, or the Claude Desktop app → Code) and paste
the message in section 9.

---

## 2. Why we're doing this (short)

- **The original question:** can users plug their Claude / ChatGPT / Gemini
  *membership* into Parrot instead of an API key? As of September 2026:
  - **Claude:** Anthropic blocks using Pro/Max logins in third-party apps (since Feb 2026).
  - **ChatGPT:** works, but it's a coding-tool path, not a guaranteed program.
  - **Gemini:** Google banned it and suspended accounts.

  So Parrot keeps using API keys and Ollama for its own AI.
- **The chosen route is the reverse:** put Parrot *inside* Claude. Claude
  Desktop, Claude Code, Codex and Cursor read the user's meetings through Parrot's local
  MCP server, and the user's own Claude (or ChatGPT, through Codex) plan does
  the thinking. This is fully allowed and needs no cloud of our own.
- **Market gap:**
  - Cloud meeting tools (Granola, Otter, Fireflies, Fathom…) all have Claude connectors, but they need a meeting bot and often a paywall. Granola's free plan is 30 days with no transcripts.
  - The local rivals are either developer tools (Minutes, Anarlog, Screenpipe) or paid (Meetily).
  - **Parrot's lane:** the polished, free, local Mac app where connecting is one click, with real speaker names and smart tools.
- **Parrot already has a v1:** `Parrot --mcp` (`Parrot/Services/MCPServer.swift`),
  with 3 read-only tools and a copy-paste setup, off by default. This work
  makes it a headline feature.

---

## 3. All decisions (settled with the owner)

**Claude connection (release 1)**
1. Free for everyone. No paywall, no history cap, full transcripts.
2. ChatGPT chat app is out for now; OpenAI users are served through Codex.
3. Read-only. No tool changes Parrot data. Writing to Gmail/Notion/CRM is done by Claude's own connectors.
4. The user chooses what's shared: transcripts ✔, reports ✔, notes ✔, Copilot cards ✘ by default, plus excluded call types. On-device-only meetings are never shared.
5. Activity line: "Claude read 5 meetings today at 14:02" (counts only).
6. Talk-time stats ship in this release.
7. Post-report tips: at most once a week, with "Don't show again".
8. Claude can *read* profiles in this release; changing them comes in release 2.
9. Re-analysis happens in Claude; nothing is saved back into Parrot.
10. Discovery: its own "Claude & AI Apps" page, a first-connection moment, "Ask Claude about this meeting", ready-made actions in Claude's menu, and a website page.

**Profiles 2.0 (release 2, right after)**
1. Claude suggests profile changes; the user approves in Parrot (review screen, undo).
2. Export / import / share `.parrotprofile` files, built together with Claude suggestions.
3. **Report templates per profile**: each profile defines its report sections and coaching style.
4. **Scorecards**: 1-5 per criterion, each backed by a moment in the call.
5. "Rewrite report with a different profile", with undo.
6. Privacy rule: imports and suggestions can only make things *more* private.
7. Migration: Copilot settings are never touched. Built-ins the user never edited get the new report format automatically (easy to switch back). Tuned built-ins and user-made profiles stay classic, with an offer. Past meetings stay as they are. There's a backup and a restore point first.
8. Gallery on openparrot.app, with the owner approving every submission (release 3). Paid profiles: the file format leaves room, and the decision comes much later.

---

## 4. The plans (read in this order)

1. `docs/superpowers/plans/2026-09-26-ai-apps-connect.md`: **release 1**, 11 tasks.
2. `docs/superpowers/plans/2026-09-26-profiles-share-suggest-gallery.md`: **release 2+**. Read the "file format" section even for release 1, because `get_profile` already outputs that format (`ProfileFile.swift`).
3. Background: `docs/superpowers/plans/2026-09-24-next-features-roadmap.md` (Phase 4 built MCP v1).

Project rules are in `CLAUDE.md`. `FILEMAP.md` maps every file.

---

## 5. Scope right now: release 1 only

Build **Tasks 1-10** of the AI-apps plan, plus the Stage 1 `ProfileFile.swift`
step from the profiles plan. Task 11 (distribution) is done together with the owner.

**Don't build yet:** report templates, profile suggestions, import/export,
gallery, ChatGPT, Gemini, start/stop recording from Claude, knowledge-base search.

---

## 6. Order of work and checkpoints

| Step | Tasks | Checked by | Checkpoint |
|---|---|---|---|
| A | 1-7: server (smart search + filters, transcript pages, commitments with owners, ready-made prompts + annotations, export to file, talk time + read profiles, permissions + activity) | `make test` (new harness checks per task) | Owner connects Claude Desktop with today's Copy Setup and tries the questions in section 7 |
| B | 8-9: one-click connect + the "Claude & AI Apps" page, meeting menu, first-connection banner, tips | `make test`, `--snapshot` renders, manual checks in section 7 | Owner walks through section 7 in all four apps |
| C | 10: help page, privacy page, README | `release-docs` skill at release time | Owner reads the help page |
| D | 11: `.mcpb` in the release, MCP Registry, Claude plugin | Owner | Beta week first (section 8) |

Rules:
- Commit after each task.
- Keep `make test` green.
- Never build with Xcode.
- Add new files to `FILEMAP.md` in the same commit.
- Never log meeting text.

---

## 7. Mac test checklist (manual)

Before testing, have at least 5 finished meetings, including one marked
**on-device only** and one in a call type you'll exclude.

**Connect**
- [ ] Claude Desktop: Connect → Claude's install screen → install → Parrot appears in Claude's connectors.
- [ ] Claude Code: Copy command → paste in Terminal → `claude mcp list` shows parrot.
- [ ] Codex: Copy command → paste → Codex lists parrot.
- [ ] Cursor: Connect → Cursor's install prompt → parrot appears.
- [ ] Claude Desktop not installed → the button says "Get Claude".
- [ ] The old v1 copy-paste setup still works without changes.

**Ask in Claude, check the answers**
- [ ] "What did I promise last week?" → items with owner and meeting + time.
- [ ] "When did [person] mention [topic]?" → finds it even with different wording.
- [ ] "Summarize my calls with [person] this month" → only that person's meetings, only this month.
- [ ] "Give me the full transcript of [long meeting]" → comes in pages, nothing missing.
- [ ] "How much did I talk in [meeting]?" → talk-time shares add up to 100%.
- [ ] "Save [meeting] as a file" → Markdown lands in Downloads/Parrot Exports.
- [ ] "What profiles do I have?" and "show me my Sales profile" → correct.
- [ ] Claude's "+" menu shows the four ready-made actions, and each works.
- [ ] "What can you do with Parrot?" → describes the six jobs.

**Privacy and trust**
- [ ] The on-device-only meeting never appears: not in lists, search or exports.
- [ ] Meetings in an excluded call type never appear.
- [ ] Untick Transcripts → Claude can't see transcript text (search and export too).
- [ ] Main switch off → Claude loses access on its next question, without a restart.
- [ ] The activity line updates after Claude reads meetings.
- [ ] The first-connection banner shows once.

**In Parrot**
- [ ] "Ask Claude about this meeting" copies the question and brings Claude to the front.
- [ ] The post-report tip shows at most once a week, and "Don't show again" works.

---

## 8. What only the owner can do

- **Beta:** 5-10 real users on a direct-download build for a week before the public launch.
- **Privacy policy page** on openparrot.app covering the AI-app connection (the directory requires one).
- **Brand check:** Anthropic's brand guidelines before using "Claude" in the page name or a "Works with Claude" badge.
- **Claude plugin directory:** submit at claude.ai/directory/manage (the repo must be public at publish; include reviewer notes).
- **Website:** a "Use Parrot with Claude" page with examples per audience (founders, sales, product managers, recruiters, consultants), plus the launch message: *"Use your meetings in Claude. Free, no bot, no 30-day limit, your data stays on your Mac."*
- **Signals to watch** (Parrot has no telemetry): `.mcpb` downloads, the directory's usage tab, registry listings, GitHub stars and issues, beta feedback.

---

## 9. First message to paste into the local Claude Code session

```
Read docs/superpowers/HANDOFF-claude-connection-and-profiles.md, then
CLAUDE.md, FILEMAP.md and docs/superpowers/plans/2026-09-26-ai-apps-connect.md
(and the "file format" section of the profiles plan).

We're building release 1 only: Tasks 1-10 of the AI-apps plan plus the
Stage 1 ProfileFile.swift step. Work on the branch `claude-connection`.

Start with step A (Tasks 1-7), one task at a time: write the harness checks
first, implement, run `make test` until ALL PASS, commit, then move on.
Stop after step A and tell me in plain, non-technical words what's done and
what I should try in Claude Desktop (section 7 of the handoff).

If anything in the plan doesn't match the code, or a decision seems wrong,
stop and ask me instead of guessing.
```
