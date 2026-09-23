import Image from "next/image";
import { after } from "@/content";
import { Reveal } from "./reveal";
import { Section } from "./section";

export function AfterCall() {
  return (
    <Section id="after" tone="coral" kicker={after.kicker} title={after.title} lede={after.lede}>
      <div className="grid gap-10 lg:grid-cols-2 lg:gap-16">
        <Reveal>
          <div className="relative max-h-[640px] overflow-hidden rounded-xl border border-line">
            <Image src={after.screenshot.src} alt={after.screenshot.alt} width={after.screenshot.width} height={after.screenshot.height} className="w-full" />
            <div className="pointer-events-none absolute inset-x-0 bottom-0 h-32 bg-linear-to-t from-paper to-transparent" />
          </div>
        </Reveal>
        <div className="space-y-8">
          {after.points.map((p, i) => (
            <Reveal key={p.title} delay={i * 80}>
              <h3 className="font-display text-xl font-bold">{p.title}</h3>
              <p className="mt-1 text-ink-2">{p.body}</p>
            </Reveal>
          ))}
        </div>
      </div>
    </Section>
  );
}
