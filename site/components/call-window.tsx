import { Circle, CircleCheck, Copy, FileText, Lightbulb, Pause, Sparkles, Square, TriangleAlert } from "lucide-react";
import type { Bubble, CallState, Card } from "@/content";

function Gauge({ label, value, color }: { label: string; value: number; color: string }) {
  return (
    <span className="flex items-center gap-1.5 text-[11px] text-ink-2">
      <span className={`size-1.5 rounded-full ${color}`} />
      {label}
      <span className="h-1 w-8 overflow-hidden rounded-full bg-line">
        <span className={`block h-full transition-[width] duration-700 ${color}`} style={{ width: `${value}%` }} />
      </span>
    </span>
  );
}

function CardView({ card }: { card: Card }) {
  const base = "card-in rounded-lg border border-line bg-card p-3 text-[13px] shadow-sm";
  if (card.kind === "answer") {
    return (
      <div className={base}>
        <div className="flex items-center justify-between text-ink-2">
          <span className="flex items-center gap-1.5">
            <span className="grid size-5 place-items-center rounded bg-teal/15 text-teal"><Lightbulb className="size-3" /></span>
            Suggested answer
          </span>
          <span className="font-mono text-[11px] underline">{card.at}</span>
        </div>
        <p className="mt-2 font-semibold">{card.title}</p>
        <p className="mt-1">“{card.quote}”</p>
        <div className="mt-2 flex items-center gap-3">
          <span className="flex items-center gap-1 rounded-md bg-teal/15 px-2 py-1 text-[12px] font-medium text-teal"><Copy className="size-3" />Copy</span>
          <span className="flex items-center gap-1 text-[12px] text-ink-3"><FileText className="size-3" />{card.source}</span>
        </div>
      </div>
    );
  }
  if (card.kind === "pinned") {
    return (
      <div className={base}>
        <div className="flex items-start justify-between gap-2">
          <div>
            <p className="flex items-center gap-1.5 font-semibold">
              {card.resolved ? <CircleCheck className="size-3.5 text-green" /> : <TriangleAlert className="size-3.5 text-orange" />}
              {card.title}
            </p>
            <p className="mt-0.5 text-[12px] text-ink-2"><span className="font-mono underline">{card.at}</span> {card.detail}</p>
          </div>
          {card.resolved ? <CircleCheck className="size-4 shrink-0 text-green" /> : <Circle className="size-4 shrink-0 text-ink-3" />}
        </div>
        {!card.resolved && <p className="mt-2 rounded-md border border-line bg-paper p-2">“{card.quote}”</p>}
      </div>
    );
  }
  return (
    <div className={base}>
      <div className="flex items-center justify-between text-ink-2">
        <span className="flex items-center gap-1.5">
          <span className="grid size-5 place-items-center rounded bg-green/15 text-green"><CircleCheck className="size-3" /></span>
          Action item
        </span>
        <span className="font-mono text-[11px] underline">{card.at}</span>
      </div>
      <p className="mt-2 font-semibold">{card.title}</p>
      <p className="mt-1 text-[12px] text-ink-3">{card.who}</p>
    </div>
  );
}

function BubbleView({ b }: { b: Bubble }) {
  const me = b.who === "me";
  return (
    <div className={`bubble-in flex flex-col ${me ? "items-end" : "items-start"}`}>
      <span className="mb-1 font-mono text-[10px] text-ink-3">
        {me ? <><span className="text-teal">Me</span> {b.at}</> : <>Them {b.at}</>}
      </span>
      <p className={`max-w-[88%] rounded-xl px-3 py-2 text-[13px] ${me ? "bg-teal/15" : "bg-secondary"}`}>{b.text}</p>
    </div>
  );
}

/** The Parrot call screen, rebuilt in HTML. Renders one state; the parent decides which. */
export function CallWindow({ state }: { state: CallState }) {
  return (
    <div className="overflow-hidden rounded-xl border border-line bg-card font-ui shadow-xl shadow-ink/5">
      <div className="flex items-center justify-between border-b border-line px-3 py-2 text-[12px]">
        <span className="flex items-center gap-2">
          <span className="flex gap-1">
            <i className="size-2.5 rounded-full bg-coral/80" /><i className="size-2.5 rounded-full bg-orange/80" /><i className="size-2.5 rounded-full bg-green/80" />
          </span>
          <span className="ml-2 flex items-center gap-1.5 font-medium text-coral"><span className="rec-dot size-2 rounded-full bg-coral" />Recording</span>
        </span>
        <span className="font-mono">{state.elapsed}</span>
        <span className="flex items-center gap-1 font-medium text-coral"><Square className="size-2.5" fill="currentColor" />Stop</span>
      </div>
      <div className="grid sm:grid-cols-2">
        <div className="max-h-[46vh] overflow-hidden p-3 sm:max-h-none sm:border-r sm:border-line">
          <div className="flex items-center justify-between text-[12px]">
            <span className="flex items-center gap-1.5 font-semibold"><Sparkles className="size-3.5 text-teal" />Copilot</span>
            <span className="flex items-center gap-2 text-ink-2">
              You {state.talking}% <Pause className="size-3" />
              <span className="flex items-center gap-1"><span className="size-1.5 rounded-full bg-green" />Listening</span>
            </span>
          </div>
          <div className="mt-3 rounded-lg border border-line bg-card p-3 shadow-sm">
            <div className="flex items-baseline justify-between">
              <span className="flex items-baseline gap-2">
                <span className={`font-display text-2xl font-bold ${state.score >= 70 ? "text-green" : "text-orange"}`}>{state.score}</span>
                <span className="font-mono text-[10px] uppercase tracking-wider text-ink-3">Call score</span>
              </span>
              {state.open > 0 && (
                <span className="flex items-center gap-1 text-[12px] font-medium text-orange"><TriangleAlert className="size-3" />{state.open} open</span>
              )}
            </div>
            <p className="mt-1.5 text-[13px]">{state.coach}</p>
            <div className="mt-2 flex flex-wrap items-center gap-3">
              <span className="rounded-full bg-secondary px-2 py-0.5 text-[11px]">{state.mood}</span>
              <Gauge label="Buying temp" value={state.temp} color="bg-orange" />
              <Gauge label="You're talking" value={state.talking} color="bg-ink-3" />
            </div>
          </div>
          <div className="mt-3 flex flex-col-reverse gap-3 sm:flex-col">
            {state.cards.map((c) => <CardView key={`${c.kind}-${c.at}-${c.kind === "pinned" ? c.resolved : ""}`} card={c} />)}
          </div>
        </div>
        <div className="hidden min-h-[360px] flex-col border-t border-line p-3 sm:flex sm:border-t-0">
          <div className="flex justify-center gap-1 text-[12px]">
            <span className="rounded-md bg-secondary px-3 py-1 font-medium">Transcript</span>
            <span className="px-3 py-1 text-ink-2">Notes</span>
          </div>
          <div className="mt-auto space-y-3 pt-4">
            {state.transcript.map((b) => <BubbleView key={`${b.who}-${b.at}`} b={b} />)}
          </div>
        </div>
      </div>
    </div>
  );
}
