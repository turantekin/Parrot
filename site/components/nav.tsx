import Image from "next/image";
import { nav, site } from "@/content";
import { DownloadButton } from "./download-button";
import { StarCount } from "./star-count";

export function Nav() {
  return (
    <header className="sticky top-0 z-40 border-b border-line/70 bg-paper/85 backdrop-blur">
      <div className="mx-auto flex h-14 max-w-6xl items-center justify-between px-5 sm:px-8">
        <a href="#top" className="flex items-center gap-2.5 text-lg font-semibold">
          <Image src="/icon.png" alt="" width={28} height={28} className="rounded-[7px]" priority />
          {site.name}
        </a>
        <nav className="flex items-center gap-5 text-sm">
          <a href={site.help} className="hidden hover:text-tone sm:inline">{nav.help}</a>
          <a href={site.repo} className="flex items-center hover:text-tone">
            {nav.github}
            <span className="hidden sm:inline"><StarCount /></span>
          </a>
          <DownloadButton size="sm" />
        </nav>
      </div>
    </header>
  );
}
