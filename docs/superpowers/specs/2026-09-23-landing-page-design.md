# Parrot landing page: design

Date: 2026-09-23. Status: approved by Uygar in conversation, ready for a plan.

## Purpose

One marketing page for Parrot, aimed at people who take client calls for a
living (sales, consultants, founders) and want help during the call without
sending the call to anyone's cloud. In ten seconds a visitor should get two
things: Parrot helps while you are talking, and the call stays on your Mac.

Primary action: download the DMG. Secondary: star or contribute on GitHub.

Voice: short, plain English, no jargon, no em-dashes, no AI-flavoured phrasing.
Calibrate against `docs/help/*.html` and the README.

## Where it lives

- Next.js (App Router), Tailwind, shadcn/ui, in `site/` inside this repo.
- Deployed on Vercel with the project root directory set to `site`, and an
  ignored-build-step rule so commits that do not touch `site/` skip deploys.
- No custom domain yet; the free `*.vercel.app` address is fine. A domain is a
  DNS change later, not a rebuild.
- The existing help site stays on GitHub Pages; the landing page links to it.

## Chapters, top to bottom

1. **Nav**: parrot icon + "Parrot", links: Help (GitHub Pages guide), GitHub
   (with live star count), Download button.
2. **Hero**: headline "Help during the call. Not after it." Subline: "Parrot
   listens along on your Mac, suggests answers from your own documents, and
   keeps every call where it belongs. Free and open source." Three proof lines:
   no bot joins your meeting; audio never leaves your Mac; works with anything
   that makes sound. Download button showing the live version, a small "or
   build from source" link, and a trust strip: open source (GPL-3.0), no
   account, no telemetry, signed and notarized, macOS 14+ on Apple Silicon.
3. **The call**: a rebuilt Parrot call window (HTML, not video, not a
   screenshot) that plays itself as the visitor scrolls. Four beats from the
   Northwind demo script:
   - The other side asks where customer data is stored. A Suggested Answer
     card appears with the `northwind-faq.md` source chip and a Copy button.
   - They ask about annual pricing for ten seats. A pinned question card
     appears, then ticks itself resolved once "Me" answers.
   - "Me" promises to send the security summary and DPA. An action item card
     is captured.
   - The call score and coach line update along the way.
   Each beat has a one-line callout explaining what just happened. On phones
   the window stacks: transcript above cards.
4. **Knowledge Base**: heading "Brief it like a new teammate." One answer card
   with a switch: "general knowledge" on one side, "from security-faq.pdf" on
   the other; the card text and source chip change with the switch. Then the
   real `settings-knowledge.png`, and three short notes: coaching
   instructions, the general-knowledge label on cards, the pre-call brief.
5. **The brain is your choice**: three cards: Claude with your own key; a local
   model through Ollama, free and offline; any OpenAI-compatible server. Below:
   pause button, pace setting, and the per-call cost row with the local column
   reading $0.00.
6. **After the call**: `report.png`, plus playback synced to the transcript,
   speaker names, importing old recordings, the optional polish pass.
7. **What leaves your Mac**: a ledger table, not badges. Audio: never.
   Transcript text: only to the provider you chose, only if you turned it on.
   Network by default: one release check a day. Accounts and telemetry: none.
   Two closing lines: this page has no cookie banner because there is nothing
   to consent to; there is nothing to certify because there is no server.
   Link to SECURITY.md.
8. **A letter from Uygar**: the "Hi from Uygar" help page rewritten as a short
   signed letter in the first person. Why it exists, real client calls every
   week, built with Claude, rough edges and loud bugs welcome, links (linktree,
   email, issues), the buy-me-a-coffee line. Uygar reviews every word before
   it ships.
9. **Open source**: repo link, GPL-3.0, the "where I could use a hand" list
   from the README, the three-line build command (`git clone`, `cd`,
   `make run`), link to CONTRIBUTING.md.
10. **Footer**: download again, requirements, Help guide, Releases, License,
    contact, "no cookies, no analytics" one-liner.

## Look

- Paper-white background, dark ink. Accents from the app icon: teal, green,
  orange, coral. One accent per chapter so the page shifts colour as you
  scroll; no gradient blobs, no purple (the category colour).
- Type: a bold wide grotesk for headlines, a plain sans for body and the
  rebuilt app window, a serif only inside the letter, monospace for the
  ledger. Fonts self-hosted through `next/font` so the page makes no
  third-party requests at runtime.
- Motion: scroll-driven reveals only, via IntersectionObserver. Everything is
  fully readable with motion off (`prefers-reduced-motion`) and with JS off.
- Dark mode follows the system. Every colour is a CSS variable in one theme
  file; no hard-coded hex in components.
- Screenshots are the real ones from `docs/help/img`, copied into the site at
  build time so there is one source of truth.

## Under the hood

- `site/app/` (layout, page, globals.css with theme tokens, opengraph image),
  `site/components/` (one file per chapter plus `download-button`,
  `star-count`, `call-window`), `site/content.ts` (all copy in one file),
  `site/lib/github.ts` (release + stars fetch), `site/scripts/copy-assets.mjs`
  (prebuild copy of screenshots and icon).
- GitHub data: `GET /repos/turantekin/Parrot/releases?per_page=10`, take the
  first entry that is not a draft (pre-releases count, since every Parrot
  release so far is one; `/releases/latest` returns 404). From it: tag,
  version, the `.dmg` asset URL and size. `GET /repos/turantekin/Parrot` for
  the star count. Fetched in server components with hourly revalidation.
  Fallbacks: download button links to the Releases page and drops the
  version; star count hides.
- No analytics, no cookies, no third-party scripts.
- Metadata: title, description, Open Graph and Twitter card using the existing
  social preview image; favicon from the app icon.
- Vercel: root directory `site`; ignored build step
  `git diff --quiet HEAD^ HEAD -- .` (run from the root directory).

## Checks before it ships

- `pnpm build` passes with zero warnings; `pnpm lint` clean.
- One unit test for the release picker (newest non-draft, pre-release ok,
  DMG asset found, graceful empty).
- Screenshots of every chapter at desktop and phone widths, light and dark.
- The download button resolves to the real DMG on GitHub.

## Out of scope

Blog, changelog, pricing page, custom domain, analytics, moving the help site
off GitHub Pages, a recorded demo video.
