import { letter } from "@/content";
import { Reveal } from "./reveal";

export function Letter() {
  return (
    <section id="why" className="tone-green py-20 sm:py-28">
      <div className="mx-auto max-w-3xl px-5 sm:px-8">
        <Reveal>
          <p className="font-mono text-xs uppercase tracking-[0.2em] text-tone">{letter.kicker}</p>
          <div className="mt-6 rounded-2xl border border-line bg-card p-7 font-serif text-xl leading-relaxed sm:p-12 sm:text-2xl">
            <p className="font-display text-3xl font-bold sm:text-4xl">{letter.greeting}</p>
            {letter.paragraphs.map((p) => <p key={p.slice(0, 24)} className="mt-5">{p}</p>)}
            <p className="mt-8 font-display text-2xl italic">{letter.signoff}</p>
            <p className="mt-8 border-t border-line pt-6 text-lg text-ink-2">{letter.ps}</p>
            <ul className="mt-5 flex flex-wrap gap-x-6 gap-y-2 font-sans text-base">
              {letter.links.map((l) => (
                <li key={l.label}><a href={l.href} className="text-tone underline-offset-4 hover:underline">{l.label}</a></li>
              ))}
            </ul>
          </div>
        </Reveal>
      </div>
    </section>
  );
}
