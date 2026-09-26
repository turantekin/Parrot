# Ask Parrot as a chat: design

Date: 2026-09-25. Status: **approved in brainstorming, not built.** Base:
master at `7747074`. Decisions were made with the user one at a time; the
mockups live in `.superpowers/brainstorm/` (gitignored).

## 1. Problem

Ask Parrot (⌘K) today is a search box in a 580×540 sheet:

- One question, one answer. The next question wipes the last one, and a
  follow-up ("and what did we offer them?") is searched on its own words, so
  "them" means nothing.
- It always uses the reports AI (`SwitchingAnalysisProvider.reportsProvider`).
  There is no way to pick a free local model for it without also changing
  reports.
- A magnifying-glass icon; nothing says an AI writes the answer.
- Broad questions ("what did everyone promise this month?") see 8 passages,
  all of which can come from one long call.

## 2. Decisions (with the user)

| Question | Choice |
|---|---|
| Keep chats? | **Saved, like ChatGPT**: a list you can reopen and continue |
| Layout | **Its own page** in the main window: sidebar, chat list column, chat |
| AI sign | **Sparkles (✦) in the sidebar**, **Parrot logo with a ✦ badge** as the answer avatar |
| Follow-ups | **The AI rewrites the question first**, local rules as the fallback |

## 3. What the user sees

**The page.** The sidebar row "Ask Parrot" gets the `sparkles` icon and opens
a page in the detail area (no sheet). A middle column holds **New chat** and
the saved chats, newest first, grouped Today / Yesterday / weekday / date.
A chat is titled with its first question; right-click offers **Rename** and
**Delete**. A new chat shows the three example questions from `AskView`.

**The conversation.** The user's messages sit on the right; Parrot's answers
on the left with the app logo in a circle and a small ✦ badge. Citation
chips (`0:12 · Acme renewal`) stay inside the answer and open the meeting at
that moment through `AppSession.pendingJump`, as today. While a turn runs the
answer slot shows "Reading your meetings…", then "Writing…". Without an AI the
closest moments are shown, as today.

**Getting there.** ⌘K and the Ask menu item open the page with a new chat and
the field focused. "Ask about this meeting" on a meeting page starts a new
chat limited to that meeting; a tag above the field reads
"This meeting: Acme renewal ✕", and ✕ widens the chat to all meetings. The
scope is stored with the chat.

**Which AI answers.** The chat header's right side names the AI in plain
words: "Claude Haiku · cloud", "gemma3 · on this Mac", or the custom model
name. It is a menu that switches the same setting as Settings (§5). The
privacy line under the field stays, reworded per AI as today.

**Stop.** While a turn runs, the send button becomes **Stop** and cancels it.
A stopped turn is not saved.

## 4. How a turn works

1. **Rewrite (every turn after the first).** The Ask AI gets the last 3
   exchanges and the new question and returns one standalone question
   (`AskEngine.rewritePrompt`, short `maxTokens`). An empty, over-long
   (> 300 chars) or failed reply falls back to the local rule: the new
   question plus the previous question, with the meetings the last answer
   cited searched first. No message to the user on fallback.
2. **Time words (local).** today, yesterday, this week, last week, this
   month, last month (English only, first version) in the standalone question
   become a date range; meetings outside it are left out of the search. Pure
   function, harness-tested.
3. **Search (on the Mac).** `MeetingMemory.search` with the standalone
   question, the chat's scope, the private-meeting exclusion (as today) and
   the date range. `topK` goes from 8 to **12**, with at most **3 passages per
   meeting** (applied after ranking, so a long call can't fill every slot).
4. **Answer.** `provider.complete` with `AskEngine.systemPrompt` (extended by
   one line: earlier messages are context, cite only the new excerpts) and a
   user message holding the last 3 exchanges as plain text (citations
   flattened to "(Acme renewal, 0:12)") followed by the new
   `<meeting_excerpts>` and question. M-labels are per turn, as today.
5. **Check.** `AskEngine.parse` + `receiptIndex.resolve` drop any citation
   that doesn't match the transcript, as today.

## 5. Choosing the AI

- New setting `askProvider` (`@AppStorage`), default `""` = same as reports.
  Values are `CopilotProviderKind` raw values.
- `SwitchingAnalysisProvider` gains `askKind`: `CloudGate.forcesLocal ?
  .ollama : (askSelected ?? reportsKind)`, and an `ask` provider built like
  `reportsProvider` (falls back to the live one when not configured). Ask
  calls a new `completeAsk(system:user:maxTokens:)` that uses it, with the
  same redaction as reports (`redactCloud`), rewrite included.
- Settings → Copilot → Model: a third row **Ask Parrot** under
  "Post-call reports", a menu picker "Same as reports" + the kinds, and
  `providerConfig(for:)` below it when it differs from the others.
- Ollama and Custom keep one model each, shared by all three jobs. Per-job
  models are out of scope.
- `ask(...)` decides `local` from the ask route, not the reports route, so the
  private-meeting filter and the request can't disagree (same rule as today).

## 6. Storage

- Chats are plain Codable values in `Application Support/Parrot/Chats/chats.json`,
  beside the memory index. **Not SwiftData:** no schema change, so an older
  build opening the store can't drop anything.
- `AskChat { id, title, scope: UUID?, scopeTitle: String?, created, updated,
  messages: [AskMessage] }`; `AskMessage { id, role: me | parrot, text,
  lines: [AskEngine.Line], note: String?, answeredByAI, usedPrivate: Bool,
  model: String? }`.
- `AskChatStore` (`@Observable`, `final class`): load at launch, save after
  each turn / rename / delete (atomic write). One file; chats are small.
- Deleting a chat is permanent. A deleted meeting leaves chat text in place;
  its chips render as "deleted" and do nothing.
- Retention (`applyRetention`) also removes chats not updated for longer
  than the meeting clean-up period, when that setting is on.

## 7. Privacy

- Unchanged: a cloud AI never sees on-device-only meetings; search and the
  time-word filter run on the Mac; only the chosen passages + recent chat
  go out.
- New: an answer written from a private meeting by a local AI is stored with
  `usedPrivate = true`. When the chat's current AI is a cloud one, those
  exchanges are left out of the history sent for both rewrite and answer.

## 8. Code layout

| Unit | Change |
|---|---|
| `Services/AskEngine.swift` | rewrite prompt + parse, history formatting, time words, per-meeting cap (all pure, `nonisolated static`) |
| `Services/AskChatStore.swift` | new: chat values, load/save, delete, retention sweep |
| `Services/RecordingManager+Memory.swift` | `ask` takes a chat (history + scope), runs §4, uses the ask route |
| `Services/OpenAICompatibleProvider.swift` | `askSelected`, `askKind`, ask provider, `completeAsk` |
| `Views/AskPageView.swift` | new: chat list column + conversation + input; replaces the sheet |
| `Views/AskView.swift` | answer/chip rendering reused inside messages; sheet removed |
| `Views/ContentView.swift`, `SidebarView.swift` | Ask page in the detail area; sparkles row. The three `showDashboard`/`showSettings`/`selectedMeeting` flags become one `Destination` enum, since a fourth flag makes the combinations unmanageable |
| `Views/AppCommands.swift`, `MeetingDetailView.swift` | ⌘K and "Ask about this meeting" open the page with a new (scoped) chat |
| `Views/SettingsView.swift` | Ask Parrot row |
| `Views/Theme.swift` | avatar size and badge metrics |

## 9. Errors

| Case | Behaviour |
|---|---|
| AI not set up / Ollama not running / key missing | Closest moments + a plain note naming the fix |
| Rewrite fails or returns junk | Local fallback, silent |
| AI invents a citation | Dropped (as today) |
| User presses Stop | Task cancelled, turn discarded, field keeps the question |
| chats.json unreadable | Start empty, keep the bad file as `chats.json.bad`, log once |

## 10. Testing

- `make test` checks: chat store round-trip / delete / retention; rewrite
  prompt shape and fallback on empty or long replies; time words to date
  ranges; 3-per-meeting cap; `usedPrivate` history filter against a cloud
  route; `askKind` routing incl. on-device-only; history formatting flattens
  citations.
- Harness: `--ask-chat-test [claude|ollama]` runs a scripted two-turn chat
  (question, then a pronoun follow-up) against the real store in the
  container, prints the rewritten question, the answer and its citations.
  Run on Claude and gemma3:4b before the user tries it.
- `--help-shots` gains the Ask page; the user then tries it in the app.

## 11. Build order

Each step ships on its own:

1. Ask Parrot AI picker + AI name in the answer area (§5).
2. Sparkles sidebar icon + Parrot avatar with badge.
3. Chat page with saved chats (§3, §6), still one-shot search per turn.
4. Follow-ups: rewrite + history (§4 steps 1 and 4, §7).
5. Broad questions: 12 passages, 3 per meeting, time words (§4 steps 2–3).

## 12. Out of scope

Per-job Ollama models, streaming token-by-token answers, non-English time
words, exporting chats, chats that trigger actions (Reminders, email).
