"use client";
import { useState } from "react";
import { Copy, FileText, Lightbulb } from "lucide-react";
import { Switch } from "@/components/ui/switch";
import { knowledge as k } from "@/content";
import { Reveal } from "./reveal";
import { Section } from "./section";

export function Knowledge() {
  const [on, setOn] = useState(true);
  const a = on ? k.grounded : k.general;
  return (
    <Section id="knowledge" tone="green" kicker={k.kicker} title={k.title} lede={k.lede}>
      <div className="grid items-center gap-12 lg:grid-cols-2 lg:gap-20">
        <div className="space-y-8 lg:order-2">
          {k.notes.map((n, i) => (
            <Reveal key={n.title} delay={i * 80}>
              <h3 className="text-xl font-semibold tracking-tight">{n.title}</h3>
              <p className="mt-1.5 text-ink-2">{n.body}</p>
            </Reveal>
          ))}
        </div>
        <Reveal className="lg:order-1">
          <div className="frame frame-sm">
            <div className="bg-card p-4 font-ui">
              <p className="font-mono text-[10px] text-ink-3">Them {k.question.at}</p>
              <p className="mt-1 inline-block rounded-xl bg-secondary px-3 py-2 text-[13px]">{k.question.text}</p>
              <div key={String(on)} className="card-in mt-4 rounded-lg border border-line bg-card p-3 text-[13px] shadow-sm">
                <div className="flex items-center justify-between text-ink-2">
                  <span className="flex items-center gap-1.5">
                    <span className="grid size-5 place-items-center rounded bg-teal/15 text-teal"><Lightbulb className="size-3" /></span>
                    Suggested answer
                  </span>
                  <span className="font-mono text-[11px] underline">{k.question.at}</span>
                </div>
                <p className="mt-2 font-semibold">{a.title}</p>
                <p className="mt-1">“{a.quote}”</p>
                <div className="mt-2 flex items-center gap-3">
                  <span className="flex items-center gap-1 rounded-md bg-teal/15 px-2 py-1 text-[12px] font-medium text-teal"><Copy className="size-3" />Copy</span>
                  <span className="flex items-center gap-1 text-[12px] text-ink-3">
                    {on && <FileText className="size-3" />}
                    {a.source}
                  </span>
                </div>
              </div>
              <label className="mt-4 flex cursor-pointer items-center justify-between rounded-lg bg-secondary px-3 py-2.5 text-[13px]">
                <span>{k.toggleLabel}</span>
                <Switch checked={on} onCheckedChange={(v) => setOn(Boolean(v))} aria-label={k.toggleLabel} />
              </label>
            </div>
          </div>
        </Reveal>
      </div>
    </Section>
  );
}
