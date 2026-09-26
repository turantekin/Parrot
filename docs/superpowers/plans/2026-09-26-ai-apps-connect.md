# Parrot in Claude & Co. (MCP v2): Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the hidden `Parrot --mcp` switch into a headline feature: one click connects Claude Desktop (and Claude Code, Codex, Cursor), and the user's own Claude/ChatGPT plan does the thinking over their meetings. Free on every tier, fully local, read-only.

**Architecture:** Everything stays in the existing stdio server (`Services/MCPServer.swift`, launched as `Parrot --mcp` by the AI app). It gains smarter tools (meaning-aware search, filters, transcript pages, commitments, export), MCP *prompts* (ready-made workflows), and tool annotations. The app's Settings card gains real one-click connect buttons (a generated `.mcpb` for Claude Desktop, a deeplink for Cursor, a copied command for Claude Code / Codex). Distribution adds a release `.mcpb`, an MCP Registry entry and a Claude plugin folder.

**Tech Stack:** Swift 5.10+, SwiftData (read only), NaturalLanguage (existing `MeetingMemory` search), Makefile build, `--profile-test` harness (no XCTest), `@anthropic-ai/mcpb` CLI (release script only).

**Background:** `docs/superpowers/plans/2026-09-24-next-features-roadmap.md` Phase 4 built v1 (three tools, Copy Setup). This plan is v2.

## Product decisions (settled 2026-09-26)

1. **Free for everyone.** No paywall, no history cap, full transcripts. This is the pitch against Granola (free = 30 days, no transcripts), tl;dv, Jamie and Meetily (MCP is Pro-only).
2. **ChatGPT (chat app) is out of scope for now.** It only talks to internet-hosted servers; reaching a Mac needs OpenAI's Secure MCP Tunnel (developer-platform setup). OpenAI users are served through **Codex**, which runs local servers. Revisit if users ask.
3. **Read-only.** No tool writes to Parrot. Writing *elsewhere* (Gmail, HubSpot, Linear, Notion) is done by the AI app's own connectors with the text Parrot returns.

## Why users want this (evidence, 2026-09 market scan)

Ranked jobs: cross-meeting questions ("what did we decide on pricing?"), weekly digests and pre-call briefs, follow-up emails in the user's voice, CRM updates and objection patterns, PRDs / feature-request lists from customer calls, "what did I promise, and to whom?", bulk export.

Top complaints about competitors: own data behind a paywall; local caches locked (Granola v6 broke community servers); whole transcripts flood the AI's context; "Me/Them" instead of names so action items lose their owner; no "a new meeting is ready" trigger; meeting-bot privacy (Otter class action).

Local rivals: Minutes, Anarlog (ex-Hyprnote), Screenpipe (free, developer-leaning, CLI setup); Meetily (polished, but MCP is paid). **Parrot's lane: the polished, free, local Mac app where connecting is one click, with real speaker names and context-smart tools.**

## Global Constraints

- macOS 14.0+. Build and test with `make test` (must end `ALL PASS`). Never use Xcode builds.
- The server stays **read-only**: `ModelConfiguration(allowsSave: false)`; no tool mutates SwiftData, settings or files other than the export folder in Task 5.
- Every tool keeps the existing privacy gates: only `status == .done` meetings, never `CloudGate.mayLeaveMac == false` meetings, off unless `mcpEnabled`, switch-off ends a live session.
- Tool output stays under `MCPServer.maxToolText`; tools that can grow (transcripts, lists) page instead of truncating silently.
- Tool text is data, not instructions: keep the `instructions` line; new prompts never paste transcript text into the prompt body beyond what a tool returns.
- Never log meeting text from the app. The harness may print.
- UI strings: short, plain English, no em-dashes. Colours/paddings from `Theme.swift`.
- New files go into `FILEMAP.md` in the same commit. Commit messages end with the repo's attribution lines.
- No new network calls from Parrot. The only outbound path is the AI app the user connected.

## File Map

| File | Responsibility |
|---|---|
| `Parrot/Services/MCPServer.swift` | async tool dispatch, new tools, prompts, annotations, `.mcpb` / deeplink / command builders |
| `Parrot/Services/MCPCommitments.swift` (new) | pure: pull commitment bullets + owners from a report via `Receipts` / `ReceiptIndex` |
| `Parrot/Services/MCPPrompts.swift` (new) | pure: the four workflow prompts (`prompts/list`, `prompts/get`) |
| `Parrot/Services/MCPBundle.swift` (new) | builds the Claude Desktop `.mcpb` (manifest, launcher, icon) into a temp folder |
| `Parrot/Views/ConnectionsPrivacySettings.swift` | "AI Apps" card: per-app connect buttons, honest blurb |
| `Parrot/ProfileTest.swift` | extend `testMCPServer()` |
| `scripts/release.sh` | pack + attach `Parrot.mcpb` to the GitHub release |
| `integrations/claude-plugin/` (new) | Claude plugin: `.claude-plugin/plugin.json`, `.mcp.json`, skills, README, PRIVACY |
| `server.json` (new) | MCP Registry entry |
| `docs/help/connections.html`, `docs/help/privacy.html`, `README.md`, `FILEMAP.md` | docs |

---

### Task 1: Search that understands meaning, plus filters

Today `search_meetings` passes all-zero cosine scores (`MCPServer.swift:233-236`), so it only matches exact words. `MeetingMemory.search` already does hybrid BM25 + on-device vectors.

**Files:** `MCPServer.swift` (`handle`, `call`, `run`), `ProfileTest.swift`

**Interfaces:**
- `DataSource.search: (String, Set<UUID>?, Int) async -> [MemoryChunk]` (new closure; harness passes a stub)
- `static func call(_:args:source:) async -> String?` (was sync)
- `list_meetings` and `search_meetings` gain optional `since`, `until` (ISO dates), `when` (plain words: "last week", "in August", parsed by `AskEngine.dateRange`), `person` (matches `people`).

**Steps:**
- [ ] Make `handle`/`call` async; in `run()` wrap each line in a `Task` and wait with a semaphore (stdio stays one-request-at-a-time, order preserved).
- [ ] `search_meetings` calls `MeetingMemory().search(query, within: allowedIDs, topK: limit)` where `allowedIDs` is the filtered snapshot (keeps the privacy gate).
- [ ] Add the filter arguments to both tools; apply them to the snapshot before search/list.
- [ ] Results carry speaker name + `[mm:ss]` stamp per excerpt (already in chunk text for transcripts; add for report chunks: "(report)").
- [ ] Harness: stubbed `search` returns a chunk the lexical path would miss → tool returns it; `when: "last week"` excludes an older meeting; a private meeting never appears even if the stub returns its chunk.

### Task 2: Transcripts in pages, not floods

**Files:** `MCPServer.swift`, `ProfileTest.swift`

**Interfaces:**
- New tool `get_transcript(id, from?: "mm:ss", to?: "mm:ss", max_lines?: Int = 400)` → lines with speaker names, then `next_from: "mm:ss"` when more remains.
- `get_meeting` keeps `include_transcript` for compatibility but, above `max_lines`, returns the first page plus a pointer to `get_transcript`.

**Steps:**
- [ ] Reuse `Meeting.transcriptLines` (already `[mm:ss] Name: text`) through the existing `transcript` closure; slice by segment start time.
- [ ] Say in the tool description: "Long meetings come in pages; call again with `from` = `next_from`."
- [ ] Harness: 1,000-line stub pages into three calls with no overlap and no gap; `from` beyond the end → "No more transcript."

### Task 3: Commitments with owners ("what did I promise?")

Reports already have commitment-type sections (`Receipts.isCommitmentSection`: next steps, commitments, follow-ups, action items, promises) whose bullets carry `[mm:ss]` receipts. The receipt time resolves to the transcript line, and that line has the speaker, so the owner is a lookup, not a guess.

**Files:** `MCPCommitments.swift` (new, pure), `MCPServer.swift`, `ProfileTest.swift`

**Interfaces:**
- `enum MCPCommitments { struct Item { meetingID; title; date; text; owner: String?; stamp: String? }; static func items(summary: String, index: ReceiptIndex, ...) -> [Item] }`
- New tool `list_commitments(person?, owner?: "me" | "others" | name, since?, until?, when?, limit?)`.

**Steps:**
- [ ] Split the summary into sections; keep bullets under commitment titles; drop `Receipts.isPlaceholder` bullets.
- [ ] Owner = speaker of `index.resolve(stamp)`; no valid stamp → owner `nil` (shown as "unclear"), never invented.
- [ ] `MeetingInfo` gains `receiptIndex` lazily via a new `DataSource.receipts: (UUID) -> ReceiptIndex` closure (only this tool pays for it).
- [ ] Harness: a report with "Next steps" bullets stamped to a "Me" line and a "Sarah" line → `owner: "me"` returns one, `owner: "Sarah"` the other; an unstamped bullet → "unclear"; "- None" skipped.

### Task 4: Ready-made workflows (MCP prompts) and tool annotations

Prompts show up in Claude Desktop's "+" menu, so users get value without writing a prompt.

**Files:** `MCPPrompts.swift` (new, pure), `MCPServer.swift`, `ProfileTest.swift`

**Prompts:**
| Name | Arguments | Tells the AI to |
|---|---|---|
| `weekly_digest` | `when` (default "last 7 days") | list meetings, pull commitments, write decisions / my to-dos / waiting-on-others / risks, each with meeting + time |
| `follow_up_email` | `meeting` (id or title words) | read the meeting, draft a follow-up in the user's voice, only promises with receipts |
| `prep_for_call` | `person` or `company` | find past meetings with them, open items, what was offered, questions to ask |
| `prd_from_calls` | `topic`, `when` | search calls for the topic, group requests/pains with quotes and counts, draft a short PRD |

**Steps:**
- [ ] `initialize` advertises `"prompts": ["listChanged": false]`; handle `prompts/list` and `prompts/get` (returns one user message naming which Parrot tools to use).
- [ ] Every tool gets `title` and `annotations: {readOnlyHint: true, destructiveHint: false, openWorldHint: false}` (required for directory review; also stops "allow this change?" prompts in clients).
- [ ] Harness: `prompts/list` has four; `prompts/get weekly_digest` mentions `list_commitments`; every tool has `readOnlyHint == true`.

### Task 5: Save a meeting to a file

For bulk export and for AI apps that can read files (Claude Code, Codex, Cowork), a path is better than 60k characters of text.

**Files:** `MCPServer.swift`, `ProfileTest.swift` (reuses `ExportService`)

**Interfaces:** tool `export_meeting(id, format: "markdown" | "txt" | "srt" = "markdown")` → absolute path.

**Steps:**
- [ ] Write to `~/Downloads/Parrot Exports/` (the app already holds the Downloads entitlement; the `--mcp` process runs the same signed binary). Same file name rules as the in-app export; overwrite the same meeting's file.
- [ ] This is the only write the server makes; it's a copy of the user's own data into their Downloads. Tool description says so; `readOnlyHint` stays true (no Parrot data changes).
- [ ] Harness: markdown export of a stub meeting opens with the same front matter the in-app export writes; bad id → "No meeting with that id."

### Task 6: One-click connect in Settings

The app is sandboxed, so it can't edit other apps' config files. Each app gets the cleanest path it supports.

**Files:** `MCPBundle.swift` (new), `MCPServer.swift`, `ConnectionsPrivacySettings.swift`, `Theme.swift` (if a new metric is needed)

| App | Button | What it does |
|---|---|---|
| Claude Desktop (+ Cowork) | **Connect** | Builds `Parrot.mcpb` in the temp folder (manifest, launcher that runs *this* app's `Parrot --mcp`, icon, privacy link) and opens it; Claude shows its install screen |
| Cursor | **Connect** | Opens Cursor's MCP install deeplink with the command |
| Claude Code | **Copy command** | `claude mcp add parrot -- "<path>" --mcp` |
| Codex (OpenAI) | **Copy command** | `codex mcp add parrot -- "<path>" --mcp` |
| Anything else | **Copy setup** | today's JSON snippet |

**Steps:**
- [ ] Buttons disabled until "Allow AI apps to read my meetings" is on; turning it on is still the only consent step.
- [ ] Show "Installed" hints only when cheap to detect (Claude Desktop / Cursor by bundle id via `NSWorkspace.urlForApplication(withBundleIdentifier:)`); otherwise hide the Connect button and keep Copy.
- [ ] Fix the blurb: drop "ChatGPT", name Claude, Codex, Cursor; keep "the app you connect usually sends what it reads to its own cloud, so on-device-only meetings are never shown to it".
- [ ] Harness: `.mcpb` manifest JSON has name, version = `AppUpdater.currentVersion`, the four prompts, all tools, and a launcher pointing at the given path; command builders quote paths with spaces.
- [ ] Manual (on a Mac): Connect → Claude install screen → ask "what did I promise last week?" → answer cites meetings. Repeat in Claude Code and Codex.

### Task 7: Docs and launch copy

**Files:** `docs/help/connections.html`, `docs/help/privacy.html`, `README.md`, `FILEMAP.md`

- [ ] Help page: per-app steps, the four ready-made prompts, example questions, the privacy line.
- [ ] README: move MCP from a trailing sentence to its own "Use your meetings in Claude" section: free, local, no bot, full history.
- [ ] Run the `release-docs` skill at release time for notes + website list.

### Task 8: Distribution (after Tasks 1-7 ship)

Being listed is for discovery only; users can connect without any store.

- [ ] **Release asset:** `scripts/release.sh` packs `Parrot.mcpb` (launcher finds Parrot by bundle id, so it doesn't assume `/Applications`) and attaches it to the GitHub release; website gets a "Works with Claude" block with the download.
- [ ] **MCP Registry:** add `server.json` (name `io.github.turantekin/parrot`, the release `.mcpb` URL + sha256) and publish with the registry CLI. Then list on Smithery and mcp.so.
- [ ] **Claude plugin directory** (the only listing route for local servers; standalone `.mcpb` listings are closed): `integrations/claude-plugin/` with `plugin.json`, `.mcp.json` (same launcher), four skills mirroring the prompts, README, PRIVACY. Validate with `claude plugin validate`, submit at claude.ai/directory/manage (repo must be public at publish). Data-handling answers: reads personal data locally; sends nothing itself; the Claude session receives what tools return.
- [ ] **Not now:** ChatGPT (needs a hosted relay or the developer tunnel), Gemini.

## Later (v3, only if usage asks)

- Knowledge-base search tool (`KnowledgeBaseService` hybrid search is ready).
- "New meeting ready" signal: the existing webhook already fires; document it as the trigger for Claude/Zapier automations before building anything new.
- Start/stop recording from the AI app: needs a bridge into the running app (App Intent or URL scheme), since `--mcp` is a separate process. Would also be the first write, so it needs its own decision.

## Risks

| Risk | Mitigation |
|---|---|
| Users don't realise the connected AI sends meeting text to its cloud | Plain line on the card and help page; on-device-only meetings stay invisible |
| Store version skew (Parrot updated, app not reopened) | Existing clear error; `.mcpb` version tracks the app version |
| Plugin directory review / security scan flags the launcher script | Keep it a few lines, no network, documented in PRIVACY; `.mcpb` download works regardless |
| Context floods in long histories | Paging (Task 2), export-to-file (Task 5), `limit` caps everywhere |
| Sandboxed `--mcp` can't reach a moved/renamed app | Launcher resolves by bundle id, not path |

## Size

Tasks 1-5: about 1 week (server + harness). Task 6: 2-3 days plus a Mac check in each app. Tasks 7-8: 2-3 days, then Anthropic review time.
