import { Button } from "@/components/ui/button";
import { openSource as o } from "@/content";
import { Reveal } from "./reveal";
import { Section } from "./section";

export function OpenSource() {
  return (
    <Section id="open-source" tone="orange" kicker={o.kicker} title={o.title} lede={o.lede}>
      <div className="grid gap-10 lg:grid-cols-2 lg:gap-16">
        <Reveal>
          <h3 className="font-semibold">{o.helpTitle}</h3>
          <ul className="mt-3 space-y-2 text-ink-2">
            {o.help.map((h) => (
              <li key={h} className="flex gap-3"><span className="mt-2.5 size-1.5 shrink-0 rounded-full bg-tone" />{h}</li>
            ))}
          </ul>
          <div className="mt-8 flex flex-wrap gap-3">
            <Button render={<a href={o.cta.href} />} nativeButton={false} className="rounded-full">{o.cta.label}</Button>
            <Button render={<a href={o.contributing.href} />} nativeButton={false} variant="outline" className="rounded-full">{o.contributing.label}</Button>
          </div>
        </Reveal>
        <Reveal delay={80}>
          <pre className="overflow-x-auto rounded-xl bg-ink p-5 font-mono text-sm leading-relaxed text-paper"><code>{o.build.join("\n")}</code></pre>
          <p className="mt-3 text-sm text-ink-2">{o.buildNote}</p>
        </Reveal>
      </div>
    </Section>
  );
}
