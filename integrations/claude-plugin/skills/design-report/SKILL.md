---
name: design-report
description: Redesign the end-of-call report of one of the user's Parrot profiles (sections, scorecards, coaching), for example to match a hiring scorecard, and send it to Parrot for review. Use when the user wants their Parrot reports to cover different things.
---

# Design a report

1. Read the profile with `get_profile`.
2. Change only its `report` block: up to 8 sections, each with a title, a type (prose, bullets or scorecard) and a short guide; `commitments: true` on the section that holds promises.
3. A scorecard has 1 to 8 criteria, each with a label and a guide. It scores only what was said, never age, gender, accent, looks or other personal traits.
4. Send it with `suggest_profile` (`updates` = the profile's name). The user reviews it in Parrot.

Keep it short and plain: small local AI models run these profiles too.
