# Parrot for Claude

Your meetings from [Parrot](https://openparrot.app), the free, local Mac app that records your calls and writes the transcript with real speaker names, available in Claude. Claude reads; nothing changes without your OK.

Ask things like:

- "What did I promise last week?"
- "When did Sarah mention the budget?"
- "Brief me for my call with Acme."
- "Draft the follow-up for this morning's call."
- "Coach me across my last 10 calls: where do I talk too much?"

## What you need

1. Parrot on your Mac (macOS 14 or later, Apple Silicon): [openparrot.app](https://openparrot.app).
2. In Parrot, open **Claude & AI Apps** and turn on **Allow AI apps to read my meetings**.

## What's inside

- An MCP server: Parrot itself (`Parrot --mcp`), started by `server/launch.sh`, which finds Parrot in Applications or by its app id. No network. It only writes a meeting export you ask for, and suggested profiles that wait for your review.
- Tools: `list_meetings`, `get_meeting`, `search_meetings`, `get_transcript`, `list_commitments`, `export_meeting`, `meeting_stats`, `list_profiles`, `get_profile`, `suggest_profile`. All read-only except two: `export_meeting` saves a copy of one meeting to Downloads/Parrot Exports, and `suggest_profile` leaves a suggested call profile that changes nothing until the user applies it in Parrot.
- Skills: weekly digest, follow-up email, prep for a call, PRD from calls, create a profile, improve a profile, design a report.

## For reviewers

Install Parrot, record or import one short audio file (File > Import Audio), wait for the report, then turn on the switch above. Ask "What did I promise?" or "Summarize my latest meeting".

More: [Use your meetings in Claude](https://openparrot.app/help/claude.html). Privacy: [PRIVACY.md](PRIVACY.md).
