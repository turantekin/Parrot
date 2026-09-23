import Image from "next/image";
import { after } from "@/content";
import { Reveal } from "./reveal";
import { Section } from "./section";

export function AfterCall() {
  return (
    <Section id="after" tone="coral" kicker={after.kicker} title={after.title} lede={after.lede}>
      <div className="grid items-center gap-12 lg:grid-cols-2 lg:gap-20">
        <div className="space-y-8">
          {after.points.map((p, i) => (
            <Reveal key={p.title} delay={i * 80}>
              <h3 className="text-xl font-semibold tracking-tight">{p.title}</h3>
              <p className="mt-1.5 text-ink-2">{p.body}</p>
            </Reveal>
          ))}
        </div>
        <Reveal>
          <div className="frame frame-sm">
            <div className="relative max-h-[560px] overflow-hidden bg-card">
              <Image src={after.screenshot.src} alt={after.screenshot.alt} width={after.screenshot.width} height={after.screenshot.height} className="w-full" />
              <div className="pointer-events-none absolute inset-x-0 bottom-0 h-28 bg-linear-to-t from-card to-transparent" />
            </div>
          </div>
        </Reveal>
      </div>
    </Section>
  );
}
