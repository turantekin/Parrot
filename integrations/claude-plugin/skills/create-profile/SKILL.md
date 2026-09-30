---
name: create-profile
description: Build a Parrot call profile (what the live Copilot flags, and what the report after the call covers) for a kind of call, and send it to Parrot for the user to review. Use when the user wants a new profile, a Copilot setup for a type of call, or says their calls need a different report.
---

# Create a call profile

1. Ask three to five short questions: who is on the other side, what the user wants out of these calls, what they tend to miss, what the report should cover.
2. Use `list_profiles` and `get_profile` on the closest profile as the starting point.
3. Write the new profile as .parrotprofile JSON: persona, card types with clear triggers, gauges, and a report template (up to 8 sections; `commitments: true` on the section that holds promises).
4. Send it with `suggest_profile` and a one-line reason. The user reviews it in Parrot; nothing changes until they press Apply.

Keep it short and plain: small local AI models run these profiles too. Never put names or details from the user's meetings in a profile, and never turn on-device only off.
