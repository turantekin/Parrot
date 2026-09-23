import { getRelease } from "@/lib/github";
import { hero, site } from "@/content";
import { Button } from "@/components/ui/button";

/** Links straight at the newest DMG on GitHub. Falls back to the Releases page. */
export async function DownloadButton({ size = "lg" }: { size?: "lg" | "sm" }) {
  const rel = await getRelease();
  const href = rel?.dmgUrl ?? site.releases;
  const label = rel ? `Download Parrot ${rel.version}` : "Download Parrot";
  if (size === "sm") {
    return (
      <Button render={<a href={href} />} nativeButton={false} size="sm" className="rounded-full px-3">
        <span className="sm:hidden">Download</span>
        <span className="hidden sm:inline">{label}</span>
      </Button>
    );
  }
  return (
    <div>
      <Button render={<a href={href} />} nativeButton={false} size="lg" className="h-12 rounded-full px-6 text-base">
        {label} for macOS
      </Button>
      <p className="mt-3 text-sm text-ink-2">
        {rel?.dmgSizeMB ? `${rel.dmgSizeMB} MB. ` : ""}
        {site.requirements}.{" "}
        <a className="underline underline-offset-4 hover:text-tone" href={`${site.repo}#build-from-source`}>
          {hero.buildFromSource}
        </a>
      </p>
    </div>
  );
}
