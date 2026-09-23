import { ledger, site } from "@/content";
import { ExtLink } from "./ext-link";
import { Reveal } from "./reveal";
import { Section } from "./section";

export function Ledger() {
  return (
    <Section id="privacy" tone="teal" title={ledger.title} lede={ledger.lede} align="center" dark>
      <Reveal>
        <dl className="mx-auto max-w-4xl divide-y divide-line overflow-hidden rounded-2xl border border-line bg-card font-mono text-sm">
          {ledger.rows.map((r) => (
            <div key={r.what} className="grid gap-1 px-5 py-4 sm:grid-cols-[230px_1fr] sm:gap-6">
              <dt className="text-xs uppercase tracking-wider text-ink-2 sm:pt-0.5">{r.what}</dt>
              <dd>{r.where}</dd>
            </div>
          ))}
        </dl>
      </Reveal>
      <div className="mx-auto mt-12 grid max-w-4xl gap-10 lg:grid-cols-2 lg:gap-16">
        <Reveal>
          <div className="space-y-4 text-lg">
            {ledger.closers.map((c) => <p key={c}>{c}</p>)}
            <ExtLink href={site.security} utm="privacy-security-policy" className="inline-block font-semibold text-tone underline-offset-4 hover:underline">{ledger.securityLink}</ExtLink>
          </div>
        </Reveal>
        <Reveal delay={80}>
          <ul className="grid grid-cols-2 gap-3">
            {ledger.facts.map((f) => <li key={f} className="rounded-xl border border-line bg-card p-4 text-sm">{f}</li>)}
          </ul>
        </Reveal>
      </div>
    </Section>
  );
}
