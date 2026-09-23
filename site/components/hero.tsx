import Image from "next/image";
import { AudioLines, BotOff, Lock } from "lucide-react";
import { hero } from "@/content";
import { Demo } from "./demo";
import { DownloadButton } from "./download-button";
import { Reveal } from "./reveal";

const icons = [BotOff, Lock, AudioLines];

export function Hero() {
  return (
    <section id="top" className="tone-teal">
      <div className="mx-auto max-w-6xl px-5 pt-16 sm:px-8 sm:pt-24">
        <div className="mx-auto max-w-3xl text-center">
          <Reveal>
            <h1 className="text-[2rem] font-semibold leading-[1.05] tracking-[-0.025em] sm:text-6xl sm:leading-[1.02] md:text-7xl">
              {hero.headline[0]}
              <br />
              {hero.headline[1]}
            </h1>
          </Reveal>
          <Reveal delay={80}>
            <p className="mx-auto mt-6 max-w-xl text-lg text-ink-2 sm:text-xl">{hero.sub}</p>
          </Reveal>
          <Reveal delay={160} className="mt-8">
            <DownloadButton center utm="hero-download" />
          </Reveal>
        </div>

        <Reveal delay={240} className="mt-14 sm:mt-20">
          {/* Overlaps only the gradient band above the tabs, never the tab labels. */}
          <div className="relative z-10 mx-auto -mb-4 w-[92px] sm:-mb-5 sm:w-[116px]">
            <Image src="/icon.png" alt="" width={116} height={116} priority className="drop-shadow-[0_18px_30px_rgba(0,0,0,0.25)]" />
          </div>
          <Demo />
        </Reveal>

        <Reveal delay={320}>
          <ul className="mx-auto mt-20 grid max-w-5xl gap-8 sm:grid-cols-3">
            {hero.proofs.map((p, i) => {
              const Icon = icons[i];
              return (
                <li key={p.title}>
                  <Icon className="size-5 text-ink" />
                  <p className="mt-3 font-semibold">{p.title}</p>
                  <p className="mt-1 text-sm text-ink-2">{p.body}</p>
                </li>
              );
            })}
          </ul>
        </Reveal>
        <Reveal delay={400}>
          <ul className="mx-auto mt-14 flex max-w-5xl flex-wrap gap-x-6 gap-y-2 font-mono text-xs uppercase tracking-wider text-ink-3">
            {hero.trust.map((t) => <li key={t}>{t}</li>)}
          </ul>
        </Reveal>
      </div>
    </section>
  );
}
