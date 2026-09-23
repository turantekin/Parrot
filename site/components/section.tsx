import type { ReactNode } from "react";
import { Reveal } from "./reveal";

export type Tone = "teal" | "green" | "orange" | "coral";

/** Chapter frame: sets the accent tone and renders kicker, title, lede. */
export function Section({
  id, tone, kicker, title, lede, children, className = "",
}: {
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
