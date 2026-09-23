import type { ReactNode } from "react";
import { Reveal } from "./reveal";

export type Tone = "teal" | "green" | "orange" | "coral";

/** Chapter frame: accent tone, optional kicker, title, lede. `dark` flips the section to black. */
export function Section({
  id, tone, kicker, title, lede, children, align = "left", dark = false, band = false, className = "",
}: {
  id: string; tone: Tone; kicker?: string; title: string; lede?: string; children: ReactNode;
  align?: "left" | "center"; dark?: boolean; band?: boolean; className?: string;
}) {
  const centered = align === "center";
  return (
    <section id={id} className={`tone-${tone} ${dark ? "band-dark" : band ? "bg-band" : ""} py-24 sm:py-32 ${className}`}>
      <div className="mx-auto max-w-6xl px-5 sm:px-8">
        <Reveal className={centered ? "mx-auto max-w-2xl text-center" : "max-w-2xl"}>
          {kicker && <p className="font-mono text-xs uppercase tracking-[0.2em] text-tone">{kicker}</p>}
          <h2 className="mt-3 text-4xl font-semibold leading-[1.05] tracking-[-0.02em] sm:text-5xl">{title}</h2>
          {lede && <p className="mt-4 text-lg text-ink-2">{lede}</p>}
        </Reveal>
        <div className="mt-14">{children}</div>
      </div>
    </section>
  );
}
