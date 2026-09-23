import { footer } from "@/content";
import { DownloadButton } from "./download-button";
import { Reveal } from "./reveal";

export function Footer() {
  return (
    <footer id="download" className="tone-teal border-t border-line">
      <div className="mx-auto max-w-6xl px-5 py-20 sm:px-8">
        <Reveal>
          <h2 className="font-display text-4xl font-bold tracking-tight sm:text-5xl">{footer.title}</h2>
          <p className="mt-3 text-lg text-ink-2">{footer.lede}</p>
          <div className="mt-8"><DownloadButton /></div>
        </Reveal>
        <div className="mt-16 flex flex-col gap-6 border-t border-line pt-8 text-sm text-ink-2 sm:flex-row sm:items-center sm:justify-between">
          <ul className="flex flex-wrap gap-x-5 gap-y-2">
            {footer.links.map((l) => <li key={l.label}><a href={l.href} className="hover:text-tone">{l.label}</a></li>)}
          </ul>
          <p>{footer.note}</p>
        </div>
      </div>
    </footer>
  );
}
