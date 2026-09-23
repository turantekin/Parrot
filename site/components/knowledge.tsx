"use client";
import { useState } from "react";
import { Switch } from "@/components/ui/switch";
import { knowledge as k } from "@/content";
import { Clip } from "./clip";
import { KnowledgeWindow } from "./knowledge-window";
import { Reveal } from "./reveal";
import { Section } from "./section";

export function Knowledge() {
  const [on, setOn] = useState(true);
  const [touched, setTouched] = useState(false);
  return (
    <Section id="knowledge" tone="green" kicker={k.kicker} title={k.title} lede={k.lede}>
      <div className="grid items-start gap-12 lg:grid-cols-[1.1fr_0.9fr] lg:gap-16">
        <Reveal>
          <Clip steps={4} seconds={10} caption={(s) => k.clip.captions[s]} forceEnd={touched} onReplay={() => setTouched(false)}>
            {(step) => <KnowledgeWindow step={step} grounded={on} />}
          </Clip>
          <label className="mt-5 flex cursor-pointer items-center justify-between rounded-xl border border-line bg-card px-4 py-3 text-sm">
            <span>{k.toggleLabel}</span>
            <Switch checked={on} onCheckedChange={(v) => { setOn(Boolean(v)); setTouched(true); }} aria-label={k.toggleLabel} />
          </label>
        </Reveal>
        <div className="space-y-8">
          {k.notes.map((n, i) => (
            <Reveal key={n.title} delay={i * 80}>
              <h3 className="text-xl font-semibold tracking-tight">{n.title}</h3>
              <p className="mt-1.5 text-ink-2">{n.body}</p>
            </Reveal>
          ))}
        </div>
      </div>
    </Section>
  );
}
