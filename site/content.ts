// Every word on the page. Edit here, not in components.
// Voice: short, plain, no jargon, no em-dashes.

export const site = {
  name: "Parrot",
  tagline: "A live copilot for your calls that runs on your Mac",
  description:
    "Parrot listens along on your Mac, suggests answers from your own documents, and keeps every call where it belongs. Free and open source.",
  repo: "https://github.com/turantekin/Parrot",
  releases: "https://github.com/turantekin/Parrot/releases",
  help: "https://turantekin.github.io/Parrot/help/",
  security: "https://github.com/turantekin/Parrot/blob/master/SECURITY.md",
  contributing: "https://github.com/turantekin/Parrot/blob/master/CONTRIBUTING.md",
  license: "https://github.com/turantekin/Parrot/blob/master/LICENSE",
  issues: "https://github.com/turantekin/Parrot/issues",
  linktree: "https://linktr.ee/turantekin",
  email: "uygar@turantekin.co.uk",
  coffee: "https://buymeacoffee.com/turantekin",
  requirements: "macOS 14 or later on Apple Silicon",
};

export const nav = {
  help: "Help",
  github: "GitHub",
};

export const hero = {
  headline: ["Help during the call.", "Not after it."],
  sub: site.description,
  proofs: [
    {
      title: "No bot joins your meeting",
      body: "Parrot records what your Mac already plays and hears. Nothing shows up in the participant list.",
    },
    {
      title: "Audio never leaves your Mac",
      body: "Transcription, speaker detection and your documents all run on your own machine.",
    },
    {
      title: "Works with anything that makes sound",
      body: "Google Meet, Zoom, Teams, a phone on speaker. If your Mac can hear it, Parrot can.",
    },
  ],
  trust: ["Open source, GPL-3.0", "No account", "No telemetry", "Signed and notarized", "macOS 14+, Apple Silicon"],
  buildFromSource: "or build from source",
};

export type Bubble = { who: "them" | "me"; at: string; text: string };
export type Card =
  | { kind: "answer"; at: string; title: string; quote: string; source: string }
  | { kind: "pinned"; at: string; title: string; detail: string; quote: string; resolved: boolean }
  | { kind: "action"; at: string; title: string; who: string };
export type CallState = {
  phase?: "prep" | "live" | "done";
  elapsed: string;
  score: number;
  coach: string;
  mood: string;
  temp: number;
  talking: number;
  open: number;
  transcript: Bubble[];
  cards: Card[];
  brief?: { title: string; profile: string; lines: string[]; docs: string[] };
  report?: { summary: string; commitments: string[]; coaching: string[] };
};

const q1: Bubble = { who: "them", at: "00:38", text: "Before we go further, our legal team asked: where is our customer data actually stored?" };
const a1: Bubble = { who: "me", at: "00:52", text: "All of it stays in the EU, in Frankfurt. And we'll sign a DPA if that helps." };
const q2: Bubble = { who: "them", at: "01:10", text: "Good. And what does the annual plan cost for a team of ten?" };
const a2: Bubble = { who: "me", at: "01:22", text: "For ten seats it's $79 a seat per month on the annual plan." };
const r3: Bubble = { who: "them", at: "01:30", text: "Okay. That honestly removes our biggest concern." };
const p3: Bubble = { who: "me", at: "01:36", text: "Great. I'll send the security summary and the DPA right after this call." };

const answerCard: Card = {
  kind: "answer",
  at: "00:41",
  title: "Answer the data question",
  quote: "All customer data is stored in the EU, in Frankfurt. We sign a DPA on request.",
  source: "northwind-faq.md",
};
const pinnedOpen: Card = {
  kind: "pinned",
  at: "01:10",
  title: "Annual pricing for 10 seats still open",
  detail: "They asked what the annual plan costs for ten people and haven't had an answer yet.",
  quote: "For ten seats the annual plan is $79 per seat per month, billed yearly.",
  resolved: false,
};
const pinnedDone: Card = { ...pinnedOpen, resolved: true };
const actionCard: Card = { kind: "action", at: "01:36", title: "Send the security summary and DPA after the call", who: "Me" };

const live0: CallState = {
  elapsed: "00:41", score: 64, coach: "Warming up. Let them talk, then ask what changed since last time.",
  mood: "Curious", temp: 40, talking: 55, open: 0, transcript: [q1], cards: [],
};
const live1: CallState = { ...live0, elapsed: "00:44", coach: "Warming up. Answer the data question in one breath, then move on.", temp: 45, talking: 52, cards: [answerCard] };
const live2: CallState = { ...live1, elapsed: "00:55", score: 66, coach: "Good answer. Now ask what else legal flagged.", mood: "Warming", temp: 55, talking: 50, transcript: [q1, a1] };
const obj0: CallState = {
  elapsed: "01:12", score: 66, coach: "Answer the pricing question, then ask who signs off.",
  mood: "Warming", temp: 55, talking: 50, open: 1, transcript: [q1, a1, q2], cards: [answerCard, pinnedOpen],
};
const obj1: CallState = { ...obj0, elapsed: "01:24", score: 74, coach: "Good. Lock the next step before you wrap up.", temp: 66, talking: 49, open: 0, transcript: [q1, a1, q2, a2], cards: [answerCard, pinnedDone] };
const obj2: CallState = { ...obj1, elapsed: "01:41", score: 78, coach: "Going well. Ask who signs off on budget before you wrap up.", mood: "Engaged", temp: 78, talking: 48, transcript: [q1, a1, q2, a2, r3, p3], cards: [answerCard, pinnedDone, actionCard] };

const prep0: CallState = {
  phase: "prep", elapsed: "00:00", score: 0, coach: "", mood: "", temp: 0, talking: 0, open: 0, transcript: [], cards: [],
  brief: { title: "Northwind, 10:00", profile: "Sales discovery", lines: [], docs: [] },
};
const prep1: CallState = { ...prep0, brief: { ...prep0.brief!, lines: ["Last time, EU data residency came up and stayed open."] } };
const prep2: CallState = { ...prep1, brief: { ...prep1.brief!, lines: [...prep1.brief!.lines, "They want SSO confirmed before renewal."], docs: ["northwind-faq.md"] } };
const prep3: CallState = { ...prep2, brief: { ...prep2.brief!, docs: ["northwind-faq.md", "pricing-2026.pdf"] } };

const done0: CallState = {
  phase: "done", elapsed: "41:12", score: 78, coach: "", mood: "Engaged", temp: 78, talking: 48, open: 0,
  transcript: [q1, a1, q2, a2, r3, p3], cards: [], report: { summary: "", commitments: [], coaching: [] },
};
const done1: CallState = { ...done0, report: { ...done0.report!, summary: "Northwind is ready to move. Data residency and SSO are settled and ten seats were quoted at $79 a seat on the annual plan." } };
const done2: CallState = { ...done1, report: { ...done1.report!, commitments: ["Send the security summary and DPA", "Confirm who signs off on budget"] } };
const done3: CallState = { ...done2, report: { ...done2.report!, coaching: ["Talk ratio 48%, right where it should be", "Objections handled: 2 of 2", "Missed: asking who signs off"] } };

export const demo = {
  seconds: 10,
  tabs: [
    { id: "prep", label: "Prep for a call" },
    { id: "answer", label: "Answer a hard question" },
    { id: "objection", label: "Handle an objection" },
    { id: "after", label: "After the call" },
  ],
  scenarios: {
    prep: [prep0, prep1, prep2, prep3],
    answer: [live0, live1, live2],
    objection: [obj0, obj1, obj2],
    after: [done0, done1, done2, done3],
  } as Record<string, CallState[]>,
  captions: {
    prep: "One line before you hit record, and the copilot knows who you're talking to. Your documents are already in play.",
    answer: "The other side asks. Two seconds later the answer is on screen, quoted from your own FAQ, with the file named on the card.",
    objection: "Unanswered questions get pinned until you handle them. Promises are captured the moment you make them.",
    after: "The report is written before you've hung up: summary, commitments, and coaching on the call itself.",
  } as Record<string, string>,
};

export const ready = {
  title: "Ready to try Parrot?",
  lede: "Three steps, no account, nothing to configure.",
  steps: [
    { n: "1", title: "Download and pick a model", body: "One signed DMG. Choose a Whisper model on first launch; it downloads once and runs on your Mac from then on.", img: "/img/onboarding-model.png", width: 500, height: 600 },
    { n: "2", title: "Allow two permissions", body: "System audio for the other side, microphone for yours. The welcome tour deep-links to the exact settings panes.", img: "/img/onboarding-permissions.png", width: 500, height: 600 },
    { n: "3", title: "Hit record on your next call", body: "Google Meet, Zoom, Teams, anything. The copilot panel opens next to the live transcript.", img: "/img/dashboard.png", width: 1000, height: 620 },
  ],
};

export const knowledge = {
  kicker: "Knowledge base",
  title: "Brief it like a new teammate.",
  lede: "Drop in your pricing sheet, your FAQ, your playbook. Parrot reads them on your Mac and answers from them on the call.",
  toggleLabel: "Answer from my documents",
  question: { at: "12:31", text: "Is single sign-on included, or is that an add-on?" },
  general: {
    title: "Answer the SSO question",
    quote: "Most tools offer SSO on higher tiers. Check your plan details and confirm with the team.",
    source: "general knowledge",
  },
  grounded: {
    title: "Answer the SSO question",
    quote: "SSO is included for every workspace, SAML and OIDC both. No add-on, no extra tier.",
    source: "security-faq.pdf",
  },
  notes: [
    {
      title: "Your documents stay here",
      body: "PDF, text or markdown. They're chunked and embedded on this Mac with Apple's own language framework. Nothing is uploaded, ever.",
    },
    {
      title: "It says where an answer came from",
      body: "Every card names its source: your document, or the words general knowledge. You decide whether it may answer beyond your files at all.",
    },
    {
      title: "Coaching instructions and a pre-call brief",
      body: "Standing guidance for every call, like keep answers short and always offer three price options. And one line before you hit record, so the copilot knows who you're talking to from the first second.",
    },
  ],
  screenshot: {
    src: "/img/settings-knowledge.png",
    alt: "Parrot's Knowledge settings: documents with notes and the coaching instructions box",
    width: 780,
    height: 540,
  },
};

export const brains = {
  kicker: "The brain",
  title: "You pick the brain.",
  lede: "The copilot needs a language model. Parrot doesn't care which one, and it never sends audio to any of them.",
  options: [
    {
      name: "Claude",
      note: "Your own API key",
      body: "The sharpest live cards. A full hour of calls costs a few cents on Haiku. The key lives in your Keychain.",
    },
    {
      name: "Ollama",
      note: "Free and offline",
      body: "A local model on your Mac. No key, no account, no network. The whole app runs with the Wi-Fi off.",
    },
    {
      name: "Your own server",
      note: "Anything OpenAI-compatible",
      body: "Point Parrot at a URL. LM Studio, a box in your office, whatever you already run.",
    },
  ],
  controls: [
    { title: "Pause", body: "One button on the call screen. While paused nothing is sent and nothing is spent." },
    {
      title: "Pace",
      body: "Relaxed fits free tiers. Fast is for calls where every second counts. You also choose how much of the conversation each request carries.",
    },
    { title: "Profiles", body: "Sales discovery, a 1:1, an interview. Each profile has its own cards, gauges and tone." },
  ],
  cost: {
    title: "One hour of calls, roughly",
    columns: ["Claude", "Local"],
    rows: [
      { label: "Transcription, on-device Whisper", values: ["$0.00", "$0.00"] },
      { label: "Live copilot cards", values: ["$0.06", "$0.00"] },
      { label: "Post-call report", values: ["$0.01", "$0.00"] },
      { label: "Speaker detection", values: ["$0.00", "$0.00"] },
    ],
    footer: "Every meeting shows its real cost: model, tokens, calls, minutes. Local features show $0.00, proudly.",
  },
};

export const after = {
  kicker: "After the call",
  title: "The report is written before you've hung up.",
  lede: "Summary, pain points, commitments. Then a coaching report on the call itself.",
  points: [
    {
      title: "Coaching, not just notes",
      body: "Talk ratio, what went well, what to improve, objections handled versus missed, and every commitment made.",
    },
    {
      title: "Playback that follows the transcript",
      body: "Click a line, hear that moment. Right-click a line to fix a speaker, or to trim the nonsense after you forgot to hit stop.",
    },
    {
      title: "Names, not Speaker 2",
      body: "On-device speaker detection tells people apart. Name a voice once and Parrot suggests who's talking next time.",
    },
    {
      title: "Old recordings welcome",
      body: "Drop an audio file on the app. It's transcribed, diarized and summarized like a live call. An optional polish pass re-transcribes with a large model for pennies.",
    },
  ],
  screenshot: {
    src: "/img/report.png",
    alt: "Parrot's post-call report with summary, coaching and commitment cards",
    width: 1280,
    height: 2142,
  },
};

export const ledger = {
  kicker: "Privacy",
  title: "What leaves your Mac.",
  lede: "The honest list. It is short.",
  rows: [
    { what: "Audio", where: "Never. Not to us, not to anyone. There is no us." },
    {
      what: "Transcript text",
      where: "Only to the AI provider you chose, only if you turned the copilot on. Settings say exactly what is sent.",
    },
    { what: "Your documents", where: "Never. Embedded on-device with Apple's language framework." },
    { what: "Network, by default", where: "One request a day to GitHub, to check for a new release." },
    { what: "Accounts, telemetry, analytics", where: "None. There is no server to phone home to." },
  ],
  closers: [
    "This page has no cookie banner because there is nothing to consent to.",
    "There is nothing to certify because there is no server. The code is small enough to read in an afternoon, and the security policy asks you to try.",
  ],
  facts: ["About 13k lines of Swift", "Two real dependencies", "Keys live in your Keychain", "Releases signed and notarized"],
  securityLink: "Read the security policy",
};

export const letter = {
  kicker: "From Uygar",
  greeting: "Hi, I'm Uygar.",
  paragraphs: [
    "Parrot is a fun project of mine that got a little out of hand, in the best way.",
    "I spent years using call recorders and meeting assistants for work. There was always something. The one feature I needed wasn't there, or it was locked behind a plan I didn't want, or my client calls had to travel through somebody else's cloud and I was supposed to be fine with that. Nobody was building the tool I had in my head. At some point I stopped waiting and built it.",
    "I've been running my own business on it since, real client calls every week, and honestly, it helps me a lot. It remembers what was promised, catches the questions I dodged, and my calls stay on my Mac where they belong. It felt too useful to keep to myself. So here it is, free and open source, for anyone who wants the same thing.",
    "I build it with Claude as my coding buddy, late nights included. It's a personal project, so be kind to its rough edges, and loud about its bugs. Both help.",
  ],
  signoff: "Uygar",
  ps: "It's free and stays free. If it saves your day once in a while, you can buy me a coffee. No pressure, the parrot eats seeds anyway.",
  links: [
    { label: "Say hi", href: site.linktree },
    { label: "Email me", href: `mailto:${site.email}` },
    { label: "Open an issue", href: site.issues },
    { label: "Buy me a coffee", href: site.coffee },
  ],
};

export const openSource = {
  kicker: "Open source",
  title: "Read it. Fix it. Make it yours.",
  lede: "Native Swift, one repo, GPL-3.0. The whole app fits in an afternoon of reading, and FILEMAP.md tells you where everything is.",
  helpTitle: "Where I could use a hand",
  help: [
    "Speaker detection with overlapping speech and similar voices",
    "macOS permission edge cases around audio-capture taps",
    "Bugs, ideas, and telling me I'm doing something wrong",
  ],
  build: ["git clone https://github.com/turantekin/Parrot.git", "cd Parrot", "make run"],
  buildNote: "That compiles with swift build, assembles Parrot.app, signs it with whatever identity you have, and launches it.",
  cta: { label: "Star or fork on GitHub", href: site.repo },
  contributing: { label: "Read CONTRIBUTING.md", href: site.contributing },
};

export const footer = {
  title: "Your next call is the demo.",
  lede: "Download Parrot, hit record, and see what the copilot says.",
  links: [
    { label: "Help guide", href: site.help },
    { label: "Releases", href: site.releases },
    { label: "Source", href: site.repo },
    { label: "License", href: site.license },
    { label: "Security", href: site.security },
    { label: "Contact", href: `mailto:${site.email}` },
  ],
  note: "No cookies, no analytics, no tracking of any kind. Made by Uygar, with Claude.",
};
