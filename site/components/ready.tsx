import Image from "next/image";
import { ready } from "@/content";
import { DownloadButton } from "./download-button";
import { Reveal } from "./reveal";
import { Section } from "./section";

export function Ready() {
  return (
    <Section id="ready" tone="teal" title={ready.title} lede={ready.lede} align="center">
      <ol className="grid gap-8 sm:grid-cols-3">
        {ready.steps.map((s, i) => (
          <Reveal key={s.n} delay={i * 100}>
            <li>
              <div className="frame frame-sm">
                <div className="h-56 overflow-hidden bg-card">
                  <Image src={s.img} alt={s.title} width={s.width} height={s.height} className="h-full w-full object-cover object-top" />
                </div>
              </div>
              <p className="mt-5 font-semibold"><span className="mr-2 font-mono text-ink-3">{s.n}.</span>{s.title}</p>
              <p className="mt-1 text-sm text-ink-2">{s.body}</p>
            </li>
          </Reveal>
        ))}
      </ol>
      <Reveal delay={300} className="mt-16">
        <DownloadButton center />
      </Reveal>
    </Section>
  );
}
