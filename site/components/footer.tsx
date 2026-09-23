import { footer, site } from "@/content";

export function Footer() {
  return (
    <footer className="tone-teal border-t border-line">
      <div className="mx-auto flex max-w-6xl flex-col gap-6 px-5 py-10 text-sm text-ink-2 sm:flex-row sm:items-center sm:justify-between sm:px-8">
        <ul className="flex flex-wrap gap-x-5 gap-y-2">
          {footer.links.map((l) => <li key={l.label}><a href={l.href} className="hover:text-tone">{l.label}</a></li>)}
        </ul>
        <p>
          {footer.note} <a href={site.repo} className="hover:text-tone">{site.name} on GitHub</a>
        </p>
      </div>
    </footer>
  );
}
