import { letter } from "@/content";
import { Reveal } from "./reveal";

export function Letter() {
  return (
    <section id="why" className="tone-green bg-band py-24 sm:py-32">
      <div className="mx-auto max-w-2xl px-5 sm:px-8">
        <Reveal>
          <p className="font-mono text-xs uppercase tracking-[0.2em] text-tone">{letter.kicker}</p>
          <h2 className="mt-3 text-4xl font-semibold tracking-[-0.02em] sm:text-5xl">{letter.greeting}</h2>
          <div className="mt-8 space-y-5 text-lg leading-relaxed text-ink sm:text-xl">
            {letter.paragraphs.map((p) => <p key={p.slice(0, 24)}>{p}</p>)}
          </div>
          <p className="mt-8 text-xl font-semibold">{letter.signoff}</p>
          <p className="mt-8 border-t border-line pt-6 text-base text-ink-2">{letter.ps}</p>
          <ul className="mt-5 flex flex-wrap gap-x-6 gap-y-2 text-base">
            {letter.links.map((l) => (
              <li key={l.label}><a href={l.href} className="font-medium text-tone underline-offset-4 hover:underline">{l.label}</a></li>
            ))}
          </ul>
        </Reveal>
      </div>
    </section>
  );
}
