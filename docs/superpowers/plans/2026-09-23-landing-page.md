# Parrot Landing Page Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A single marketing page for Parrot in `site/`, deployed on Vercel, whose centrepiece is a rebuilt Parrot call window that plays itself as you scroll.

**Architecture:** Next.js App Router, statically generated with hourly revalidation. All copy lives in one `content.ts`; every chapter is one component; GitHub release and star data are fetched in server components with graceful fallbacks. Colours are CSS variables in `globals.css`, exposed to Tailwind through `@theme inline`.

**Tech Stack:** Next.js (latest, App Router), React, TypeScript, Tailwind CSS v4, shadcn/ui (button, switch), lucide-react, next/font (self-hosted Google fonts), vitest, pnpm, Vercel.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-09-23-landing-page-design.md`.
- Site lives in `site/` inside this repo; Vercel root directory is `site`.
- No analytics, no cookies, no third-party runtime requests. Fonts self-hosted via `next/font`.
- Every colour is a CSS variable in `site/app/globals.css`. No hard-coded hex in components.
- Copy voice: short, plain English, no jargon, **no em-dashes**, no AI-flavoured phrasing.
- Dark mode follows the system (`prefers-color-scheme`), no toggle.
- Motion: scroll reveals only; fully readable with JS off and with `prefers-reduced-motion`.
- Screenshots are committed copies of `docs/help/img/*.png` made by `site/scripts/sync-assets.mjs` (deviation from the spec's build-time copy, so the Vercel build never depends on files outside the root directory).
- GitHub release rule: newest non-draft release, pre-release allowed (`/releases/latest` returns 404 for this repo).
- Package manager: pnpm. Node 20.
- Commit after every task with the trailer `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.

## File structure

```
site/
  package.json, pnpm-lock.yaml, next.config.ts, tsconfig.json, postcss.config.mjs,
  eslint.config.mjs, components.json, vercel.json, .gitignore
  scripts/sync-assets.mjs        copies screenshots + icon into public/ and app/
  content.ts                     every word on the page, typed
  lib/github.ts                  pickRelease (pure), getRelease, getStars
  lib/github.test.ts             vitest for pickRelease
  lib/utils.ts                   cn() from shadcn
  app/layout.tsx                 fonts, metadata, js class script
  app/globals.css                theme tokens, tones, reveal + pop animations
  app/page.tsx                   assembles the chapters
  app/icon.png                   favicon (synced)
  public/og.png, public/icon.png, public/img/*.png
  components/reveal.tsx          IntersectionObserver reveal wrapper (client)
  components/section.tsx         chapter frame: tone, kicker, title, lede
  components/download-button.tsx async server component, live version
  components/star-count.tsx      async server component
  components/nav.tsx, hero.tsx
  components/call-window.tsx     the rebuilt Parrot window (presentational)
  components/call-story.tsx      scroll-driven beats (client)
  components/knowledge.tsx       answer card with the documents switch (client)
  components/brains.tsx, after-call.tsx, ledger.tsx, letter.tsx,
  components/open-source.tsx, footer.tsx
  components/ui/button.tsx, ui/switch.tsx   shadcn
```

---

### Task 1: Scaffold the site

**Files:**
- Create: `site/` via create-next-app, then shadcn init
- Create: `site/scripts/sync-assets.mjs`, `site/vercel.json`
- Modify: `site/package.json` (scripts), `site/app/page.tsx` (placeholder)
- Delete: `site/public/*.svg` boilerplate

- [ ] **Step 1: Create the app**

```bash
cd /Users/uygar/Scripts/Parrot/.claude/worktrees/musing-bassi-e87793
pnpm create next-app@latest site --ts --tailwind --eslint --app --no-src-dir --import-alias "@/*" --use-pnpm --yes
cd site
pnpm dlx shadcn@latest init -d
pnpm dlx shadcn@latest add button switch
pnpm add -D vitest
rm -f public/*.svg
```

- [ ] **Step 2: Asset sync script**

`site/scripts/sync-assets.mjs`:

```js
import { copyFileSync, mkdirSync, readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const site = dirname(dirname(fileURLToPath(import.meta.url)));
const repo = dirname(site);
const imgSrc = join(repo, "docs/help/img");
const imgDst = join(site, "public/img");
mkdirSync(imgDst, { recursive: true });
for (const f of readdirSync(imgSrc)) {
  if (f.endsWith(".png")) copyFileSync(join(imgSrc, f), join(imgDst, f));
}
const icon = join(repo, "Parrot/Assets.xcassets/AppIcon.appiconset/icon_512.png");
copyFileSync(icon, join(site, "public/icon.png"));
copyFileSync(icon, join(site, "app/icon.png"));
console.log("assets synced");
```

Run: `node scripts/sync-assets.mjs && cp ~/Desktop/parrot-social-preview.png public/og.png`

- [ ] **Step 3: Scripts and Vercel config**

Add to `site/package.json` scripts: `"test": "vitest run"`, `"sync-assets": "node scripts/sync-assets.mjs"`.

`site/vercel.json`:

```json
{ "ignoreCommand": "git diff --quiet HEAD^ HEAD -- ." }
```

- [ ] **Step 4: Placeholder page builds**

Replace `site/app/page.tsx` with `export default function Page() { return <main>Parrot</main>; }`.
Run: `pnpm build`. Expected: build succeeds.

- [ ] **Step 5: Commit**

```bash
git add site && git commit -m "Site: scaffold Next.js landing page in site/"
```

### Task 2: GitHub release and star data

**Files:**
- Create: `site/lib/github.ts`, `site/lib/github.test.ts`

**Interfaces:**
- Produces: `pickRelease(list: ApiRelease[]): Release | null`, `getRelease(): Promise<Release | null>`, `getStars(): Promise<number | null>`, type `Release = { version, tag, url, dmgUrl, dmgSizeMB, publishedAt }`.

- [ ] **Step 1: Failing test**

`site/lib/github.test.ts`:

```ts
import { describe, expect, it } from "vitest";
import { pickRelease, type ApiRelease } from "./github";

const dmg = (v: string) => ({
  name: `Parrot-${v}.dmg`,
  browser_download_url: `https://github.com/turantekin/Parrot/releases/download/v${v}/Parrot-${v}.dmg`,
  size: 17 * 1048576,
});
const rel = (over: Partial<ApiRelease> = {}): ApiRelease => ({
  tag_name: "v0.17.1",
  draft: false,
  prerelease: true,
  html_url: "https://github.com/turantekin/Parrot/releases/tag/v0.17.1",
  published_at: "2026-09-03T13:29:01Z",
  assets: [dmg("0.17.1")],
  ...over,
});

describe("pickRelease", () => {
  it("takes the newest non-draft release even when every release is a pre-release", () => {
    const r = pickRelease([
      rel({ tag_name: "v0.17.0", published_at: "2026-09-01T15:47:15Z", assets: [dmg("0.17.0")] }),
      rel(),
    ]);
    expect(r?.version).toBe("0.17.1");
    expect(r?.dmgUrl).toContain("Parrot-0.17.1.dmg");
    expect(r?.dmgSizeMB).toBe(17);
  });
  it("skips drafts", () => {
    const r = pickRelease([rel({ tag_name: "v0.18.0", draft: true, published_at: "2026-10-01T00:00:00Z" }), rel()]);
    expect(r?.tag).toBe("v0.17.1");
  });
  it("copes with a release that has no dmg", () => {
    const r = pickRelease([rel({ assets: [] })]);
    expect(r?.dmgUrl).toBeNull();
    expect(r?.dmgSizeMB).toBeNull();
  });
  it("returns null for an empty list", () => {
    expect(pickRelease([])).toBeNull();
  });
});
```

- [ ] **Step 2: Run, expect failure**

Run: `pnpm test`. Expected: FAIL, cannot resolve `./github`.

- [ ] **Step 3: Implement**

`site/lib/github.ts`:

```ts
export type ApiRelease = {
  tag_name: string;
  draft: boolean;
  prerelease: boolean;
  html_url: string;
  published_at: string;
  assets: { name: string; browser_download_url: string; size: number }[];
};

export type Release = {
  version: string;
  tag: string;
  url: string;
  dmgUrl: string | null;
  dmgSizeMB: number | null;
  publishedAt: string;
};

const REPO = "turantekin/Parrot";
const API = `https://api.github.com/repos/${REPO}`;

/** Newest non-draft release. Pre-releases count: every Parrot release so far is one. */
export function pickRelease(list: ApiRelease[]): Release | null {
  const r = list
    .filter((x) => !x.draft)
    .sort((a, b) => b.published_at.localeCompare(a.published_at))[0];
  if (!r) return null;
  const dmg = r.assets.find((a) => a.name.endsWith(".dmg"));
  return {
    version: r.tag_name.replace(/^v/, ""),
    tag: r.tag_name,
    url: r.html_url,
    dmgUrl: dmg?.browser_download_url ?? null,
    dmgSizeMB: dmg ? Math.round(dmg.size / 1048576) : null,
    publishedAt: r.published_at,
  };
}

function headers(): Record<string, string> {
  const h: Record<string, string> = { Accept: "application/vnd.github+json" };
  if (process.env.GITHUB_TOKEN) h.Authorization = `Bearer ${process.env.GITHUB_TOKEN}`;
  return h;
}

export async function getRelease(): Promise<Release | null> {
  try {
    const res = await fetch(`${API}/releases?per_page=10`, { headers: headers(), next: { revalidate: 3600 } });
    if (!res.ok) return null;
    return pickRelease((await res.json()) as ApiRelease[]);
  } catch {
    return null;
  }
}

export async function getStars(): Promise<number | null> {
  try {
    const res = await fetch(API, { headers: headers(), next: { revalidate: 3600 } });
    if (!res.ok) return null;
    const j = (await res.json()) as { stargazers_count?: unknown };
    return typeof j.stargazers_count === "number" ? j.stargazers_count : null;
  } catch {
    return null;
  }
}
```

- [ ] **Step 4: Run, expect pass**

Run: `pnpm test`. Expected: 4 passed.

- [ ] **Step 5: Commit**

```bash
git add site/lib && git commit -m "Site: GitHub release picker with test, stars fetch"
```

### Task 3: Theme, fonts, layout, reveal, section

**Files:**
- Modify: `site/app/globals.css` (replace), `site/app/layout.tsx` (replace)
- Create: `site/components/reveal.tsx`, `site/components/section.tsx`

**Interfaces:**
- Produces: `<Reveal className? delay?>`, `<Section id tone kicker title lede? className?>` with `tone: "teal" | "green" | "orange" | "coral"`.
- Tailwind utilities available afterwards: colours `paper ink ink-2 ink-3 line card tone teal green orange coral` plus shadcn names; fonts `font-display font-sans font-serif font-mono font-ui`; classes `tone-teal` etc. set `--tone`; `reveal`, `card-in`, `bubble-in`.

- [ ] **Step 1: globals.css**

```css
@import "tailwindcss";

:root {
  --paper: #fbfaf6;
  --ink: #17181a;
  --ink-2: #5d6067;
  --ink-3: #9a9ea6;
  --line: #e7e4dc;
  --card: #ffffff;
  --brand-teal: #1a8db5;
  --brand-green: #34a353;
  --brand-orange: #f08a24;
  --brand-coral: #e3503c;
  --tone: var(--brand-teal);
  --radius: 0.75rem;

  --background: var(--paper);
  --foreground: var(--ink);
  --card-foreground: var(--ink);
  --popover: var(--card);
  --popover-foreground: var(--ink);
  --primary: var(--ink);
  --primary-foreground: var(--paper);
  --secondary: #f1efe8;
  --secondary-foreground: var(--ink);
  --muted: #f1efe8;
  --muted-foreground: var(--ink-2);
  --accent: #f1efe8;
  --accent-foreground: var(--ink);
  --destructive: var(--brand-coral);
  --border: var(--line);
  --input: var(--line);
  --ring: var(--tone);
}

@media (prefers-color-scheme: dark) {
  :root {
    --paper: #121315;
    --ink: #f1efe9;
    --ink-2: #a5a8ae;
    --ink-3: #6d7077;
    --line: #27292e;
    --card: #1a1b1f;
    --brand-teal: #3fb0d6;
    --brand-green: #52c073;
    --brand-orange: #f6a04a;
    --brand-coral: #f0705e;
    --secondary: #1f2126;
    --muted: #1f2126;
    --accent: #1f2126;
  }
}

@theme inline {
  --color-paper: var(--paper);
  --color-ink: var(--ink);
  --color-ink-2: var(--ink-2);
  --color-ink-3: var(--ink-3);
  --color-line: var(--line);
  --color-card: var(--card);
  --color-tone: var(--tone);
  --color-teal: var(--brand-teal);
  --color-green: var(--brand-green);
  --color-orange: var(--brand-orange);
  --color-coral: var(--brand-coral);

  --color-background: var(--background);
  --color-foreground: var(--foreground);
  --color-card-foreground: var(--card-foreground);
  --color-popover: var(--popover);
  --color-popover-foreground: var(--popover-foreground);
  --color-primary: var(--primary);
  --color-primary-foreground: var(--primary-foreground);
  --color-secondary: var(--secondary);
  --color-secondary-foreground: var(--secondary-foreground);
  --color-muted: var(--muted);
  --color-muted-foreground: var(--muted-foreground);
  --color-accent: var(--accent);
  --color-accent-foreground: var(--accent-foreground);
  --color-destructive: var(--destructive);
  --color-border: var(--border);
  --color-input: var(--input);
  --color-ring: var(--ring);

  --font-display: var(--font-display);
  --font-sans: var(--font-sans);
  --font-serif: var(--font-serif);
  --font-mono: var(--font-mono);
  --font-ui: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", sans-serif;

  --radius-sm: calc(var(--radius) - 4px);
  --radius-md: calc(var(--radius) - 2px);
  --radius-lg: var(--radius);
  --radius-xl: calc(var(--radius) + 4px);
}

.tone-teal { --tone: var(--brand-teal); }
.tone-green { --tone: var(--brand-green); }
.tone-orange { --tone: var(--brand-orange); }
.tone-coral { --tone: var(--brand-coral); }

@layer base {
  * { @apply border-border outline-ring/50; }
  html { scroll-behavior: smooth; }
  body { @apply bg-background text-foreground font-sans antialiased; }
  ::selection { background: color-mix(in oklab, var(--tone) 25%, transparent); }
}

/* Scroll reveals only when JS is present; without it everything is visible. */
.js .reveal { opacity: 0; transform: translateY(14px); transition: opacity 0.6s ease, transform 0.6s ease; }
.js .reveal.is-visible { opacity: 1; transform: none; }

@keyframes pop {
  from { opacity: 0; transform: translateY(8px) scale(0.98); }
  to { opacity: 1; transform: none; }
}
.js .card-in, .js .bubble-in { animation: pop 0.45s ease both; }

@media (prefers-reduced-motion: reduce) {
  .js .reveal { opacity: 1; transform: none; transition: none; }
  .js .card-in, .js .bubble-in { animation: none; }
  html { scroll-behavior: auto; }
}
```

- [ ] **Step 2: layout.tsx**

```tsx
import type { Metadata } from "next";
import { Bricolage_Grotesque, Inter, Instrument_Serif, JetBrains_Mono } from "next/font/google";
import "./globals.css";
import { site } from "@/content";

const display = Bricolage_Grotesque({ subsets: ["latin"], variable: "--font-display" });
const sans = Inter({ subsets: ["latin"], variable: "--font-sans" });
const serif = Instrument_Serif({ subsets: ["latin"], weight: "400", style: ["normal", "italic"], variable: "--font-serif" });
const mono = JetBrains_Mono({ subsets: ["latin"], variable: "--font-mono" });

const base = process.env.VERCEL_PROJECT_PRODUCTION_URL
  ? `https://${process.env.VERCEL_PROJECT_PRODUCTION_URL}`
  : "http://localhost:3000";
const title = `${site.name}: ${site.tagline}`;

export const metadata: Metadata = {
  metadataBase: new URL(base),
  title,
  description: site.description,
  openGraph: { title, description: site.description, images: ["/og.png"], type: "website", siteName: site.name },
  twitter: { card: "summary_large_image", title, description: site.description, images: ["/og.png"] },
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" className={`${display.variable} ${sans.variable} ${serif.variable} ${mono.variable}`}>
      <head>
        <script dangerouslySetInnerHTML={{ __html: "document.documentElement.classList.add('js')" }} />
      </head>
      <body>{children}</body>
    </html>
  );
}
```

- [ ] **Step 3: reveal.tsx**

```tsx
"use client";
import { useEffect, useRef, type ReactNode } from "react";

export function Reveal({ children, className = "", delay = 0 }: { children: ReactNode; className?: string; delay?: number }) {
  const ref = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    const io = new IntersectionObserver(
      ([e]) => {
        if (e.isIntersecting) {
          el.classList.add("is-visible");
          io.disconnect();
        }
      },
      { rootMargin: "0px 0px -10% 0px" },
    );
    io.observe(el);
    return () => io.disconnect();
  }, []);
  return (
    <div ref={ref} className={`reveal ${className}`} style={{ transitionDelay: `${delay}ms` }}>
      {children}
    </div>
  );
}
```

- [ ] **Step 4: section.tsx**

```tsx
import type { ReactNode } from "react";
import { Reveal } from "./reveal";

export type Tone = "teal" | "green" | "orange" | "coral";

export function Section({ id, tone, kicker, title, lede, children, className = "" }: {
  id: string; tone: Tone; kicker: string; title: string; lede?: string; children: ReactNode; className?: string;
}) {
  return (
    <section id={id} className={`tone-${tone} py-20 sm:py-28 ${className}`}>
      <div className="mx-auto max-w-6xl px-5 sm:px-8">
        <Reveal className="max-w-2xl">
          <p className="font-mono text-xs uppercase tracking-[0.2em] text-tone">{kicker}</p>
          <h2 className="mt-3 font-display text-4xl font-bold tracking-tight sm:text-5xl">{title}</h2>
          {lede && <p className="mt-4 text-lg text-ink-2">{lede}</p>}
        </Reveal>
        <div className="mt-12">{children}</div>
      </div>
    </section>
  );
}
```

- [ ] **Step 5: Build, commit**

Run: `pnpm build` (needs `content.ts` from Task 4 for `site`; do Task 4 first if building here fails). Commit: `git add site && git commit -m "Site: theme tokens, fonts, reveal and section frame"`.

### Task 4: All copy in content.ts

**Files:**
- Create: `site/content.ts`

**Interfaces:**
- Produces: `site, nav, hero, call, knowledge, brains, after, ledger, letter, openSource, footer` and types `Bubble, Card, CallState`.

- [ ] **Step 1: Write content.ts** (full text is the spec's copy; see the file in the repo after this task. It must contain no em-dashes: `grep -c "—" site/content.ts` prints 0.)

- [ ] **Step 2: Commit** `git add site/content.ts && git commit -m "Site: all page copy in content.ts"`

### Task 5: Nav, hero, download button, star count

**Files:**
- Create: `site/components/download-button.tsx`, `site/components/star-count.tsx`, `site/components/nav.tsx`, `site/components/hero.tsx`
- Modify: `site/app/page.tsx` to render `<Nav /><main><Hero /></main>`

- [ ] **Step 1: download-button.tsx**

```tsx
import { getRelease } from "@/lib/github";
import { hero, site } from "@/content";
import { Button } from "@/components/ui/button";

export async function DownloadButton({ size = "lg" }: { size?: "lg" | "sm" }) {
  const rel = await getRelease();
  const href = rel?.dmgUrl ?? site.releases;
  const label = rel ? `Download Parrot ${rel.version}` : "Download Parrot";
  if (size === "sm") {
    return (
      <Button asChild size="sm" className="rounded-full">
        <a href={href}>{label}</a>
      </Button>
    );
  }
  return (
    <div>
      <Button asChild size="lg" className="h-12 rounded-full px-6 text-base">
        <a href={href}>{label} for macOS</a>
      </Button>
      <p className="mt-3 text-sm text-ink-2">
        {rel?.dmgSizeMB ? `${rel.dmgSizeMB} MB. ` : ""}
        {site.requirements}.{" "}
        <a className="underline underline-offset-4 hover:text-tone" href={`${site.repo}#build-from-source`}>
          {hero.buildFromSource}
        </a>
      </p>
    </div>
  );
}
```

- [ ] **Step 2: star-count.tsx**

```tsx
import { getStars } from "@/lib/github";

export async function StarCount() {
  const stars = await getStars();
  if (stars === null) return null;
  return (
    <span className="ml-1.5 rounded-full bg-secondary px-2 py-0.5 font-mono text-xs text-ink-2">
      ★ {stars.toLocaleString("en-US")}
    </span>
  );
}
```

- [ ] **Step 3: nav.tsx and hero.tsx** (code in the repo after this task; hero renders headline halves, sub, `<DownloadButton />`, three proof items with `border-teal/green/orange` top rules, and the trust strip in mono uppercase).

- [ ] **Step 4: Build, commit** `pnpm build && git add site && git commit -m "Site: nav, hero, live download button and star count"`

### Task 6: The call window and scroll story

**Files:**
- Create: `site/components/call-window.tsx` (presentational, props `{ state: CallState }`), `site/components/call-story.tsx` (client)
- Modify: `site/app/page.tsx` add `<CallStory />`

- [ ] **Step 1: call-window.tsx** renders title bar (Recording, elapsed, Stop), Copilot pane (score card with coach line, mood chip, two gauges, then `state.cards` as answer / pinned / action cards using lucide icons `Lightbulb, Copy, FileText, AlertTriangle, CheckCircle2, Circle, Sparkles, Pause, Square`), Transcript pane (`hidden sm:flex`, bubbles bottom-aligned, Me right in `bg-teal/15`, Them left in `bg-secondary`). New cards and bubbles get `card-in` / `bubble-in`.
- [ ] **Step 2: call-story.tsx**: `useState(0)` beat; IntersectionObserver with `rootMargin: "-40% 0px -40% 0px"` over the four callouts (`data-beat` 1..4) sets the beat; window sticky `top-16` on all sizes, callouts spaced `space-y-24 lg:space-y-[50vh]`, active callout gets `border-tone`.
- [ ] **Step 3: Build, run dev, scroll, confirm cards appear in order. Commit** `git commit -m "Site: rebuilt call window that plays itself on scroll"`

### Task 7: Knowledge, brains, after the call

**Files:**
- Create: `site/components/knowledge.tsx` (client, shadcn `Switch`, `key={String(on)}` on the card so it re-pops), `site/components/brains.tsx`, `site/components/after-call.tsx`
- Modify: `site/app/page.tsx`

- [ ] **Step 1–3: implement each from content.ts; screenshots via `next/image` with the width/height in content.**
- [ ] **Step 4: Build, commit** `git commit -m "Site: knowledge switch, brain options, after-call chapter"`

### Task 8: Ledger, letter, open source, footer, assembly

**Files:**
- Create: `site/components/ledger.tsx`, `letter.tsx`, `open-source.tsx`, `footer.tsx`
- Modify: `site/app/page.tsx` final order: Nav, Hero, CallStory, Knowledge, Brains, AfterCall, Ledger, Letter, OpenSource, Footer

- [ ] **Step 1–4: implement; ledger is a `<dl>` in mono; letter is serif inside a card with a display-font sign-off; open source has the three-line `<pre>` block in `bg-ink text-paper`; footer repeats `<DownloadButton />` and the no-cookies line.**
- [ ] **Step 5: Build, commit** `git commit -m "Site: privacy ledger, letter, open source, footer"`

### Task 9: Verify

- [ ] `pnpm lint && pnpm test && pnpm build` clean.
- [ ] `.claude/launch.json` entry `site` (pnpm dev on 3000); open in the browser pane; screenshot every chapter at desktop and at the mobile preset, light and dark (`resize_window` colorScheme).
- [ ] `curl -sI` the download href from the rendered page; expect a 302 to a GitHub objects URL.
- [ ] `grep -rn "—" site/content.ts site/components` prints nothing.
- [ ] Add `site/` line to `FILEMAP.md`; commit `docs: map site/ in FILEMAP`.

### Task 10: Deploy preview and open the PR

- [ ] From `site/`: `vercel link --yes --project parrot` then `vercel --yes`; record the preview URL. Note for the user: set Root Directory to `site` in the Vercel project settings when connecting Git, and promote to production from the dashboard or with `vercel --prod`.
- [ ] `git push -u origin claude/project-landing-page-c6aae8` and `gh pr create` against `master` with the preview URL in the body.
