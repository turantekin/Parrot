import { hero } from "@/content";
import { DownloadButton } from "./download-button";
import { Reveal } from "./reveal";

export function Hero() {
  return (
    <section id="top" className="tone-teal">
      <div className="mx-auto max-w-6xl px-5 pb-16 pt-16 sm:px-8 sm:pb-24 sm:pt-28">
        <Reveal>
          <h1 className="max-w-4xl font-display text-5xl font-bold leading-[1.02] tracking-tight sm:text-7xl">
            {hero.headline[0]} <span className="block text-tone">{hero.headline[1]}</span>
          </h1>
        </Reveal>
        <Reveal delay={80}>
          <p className="mt-6 max-w-2xl text-xl text-ink-2 sm:text-2xl">{hero.sub}</p>
        </Reveal>
        <Reveal delay={160} className="mt-10">
          <DownloadButton />
        </Reveal>
        <Reveal delay={240}>
          <ul className="mt-16 grid gap-6 border-t border-line pt-6 sm:grid-cols-3">
            {hero.proofs.map((p) => (
              <li key={p.title}>
                <p className="font-semibold">{p.title}</p>
                <p className="mt-1 text-sm text-ink-2">{p.body}</p>
              </li>
            ))}
          </ul>
        </Reveal>
        <Reveal delay={320}>
          <ul className="mt-12 flex flex-wrap gap-x-6 gap-y-2 font-mono text-xs uppercase tracking-wider text-ink-3">
            {hero.trust.map((t) => (
              <li key={t}>{t}</li>
            ))}
          </ul>
        </Reveal>
      </div>
    </section>
  );
}
