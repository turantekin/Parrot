import { footer, site } from "@/content";
import { ExtLink } from "./ext-link";

export function Footer() {
  return (
    <footer className="tone-teal border-t border-line">
      <div className="mx-auto flex max-w-6xl flex-col gap-6 px-5 py-10 text-sm text-ink-2 sm:flex-row sm:items-center sm:justify-between sm:px-8">
        <ul className="flex flex-wrap gap-x-5 gap-y-2">
          {footer.links.map((l) => <li key={l.label}><ExtLink href={l.href} utm={`footer-${l.label.toLowerCase().replace(/\s+/g, "-")}`} className="hover:text-tone">{l.label}</ExtLink></li>)}
        </ul>
        <p>
          {footer.note} <ExtLink href={site.repo} utm="footer-github" className="hover:text-tone">{site.name} on GitHub</ExtLink>
        </p>
      </div>
    </footer>
  );
}
