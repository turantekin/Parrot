import { brains as b } from "@/content";
import { Reveal } from "./reveal";
import { Section } from "./section";

export function Brains() {
  return (
    <Section id="brain" tone="orange" kicker={b.kicker} title={b.title} lede={b.lede}>
      <div className="grid gap-4 sm:grid-cols-3">
        {b.options.map((o, i) => (
          <Reveal key={o.name} delay={i * 80}>
            <div className="h-full rounded-xl border border-line bg-card p-5">
              <p className="font-mono text-xs uppercase tracking-wider text-tone">{o.note}</p>
              <h3 className="mt-2 font-display text-2xl font-bold">{o.name}</h3>
              <p className="mt-2 text-ink-2">{o.body}</p>
            </div>
          </Reveal>
        ))}
      </div>
      <div className="mt-12 grid gap-10 lg:grid-cols-[1fr_1.2fr] lg:gap-16">
        <div className="space-y-6">
          {b.controls.map((c) => (
            <Reveal key={c.title}>
              <h3 className="font-semibold">{c.title}</h3>
              <p className="mt-1 text-ink-2">{c.body}</p>
            </Reveal>
          ))}
        </div>
        <Reveal>
          <div className="overflow-hidden rounded-xl border border-line bg-card">
            <table className="w-full text-sm">
              <thead>
                <tr className="border-b border-line bg-secondary text-left font-mono text-xs uppercase tracking-wider text-ink-2">
                  <th className="px-4 py-3 font-normal">{b.cost.title}</th>
                  {b.cost.columns.map((c) => <th key={c} className="px-4 py-3 font-normal">{c}</th>)}
                </tr>
              </thead>
              <tbody>
                {b.cost.rows.map((r) => (
                  <tr key={r.label} className="border-b border-line last:border-0">
                    <td className="px-4 py-3">{r.label}</td>
                    {r.values.map((v, i) => (
                      <td key={i} className={`px-4 py-3 font-mono ${i === 1 ? "text-green" : ""}`}>{v}</td>
                    ))}
                  </tr>
                ))}
              </tbody>
            </table>
            <p className="border-t border-line px-4 py-3 text-sm text-ink-2">{b.cost.footer}</p>
          </div>
        </Reveal>
      </div>
    </Section>
  );
}
