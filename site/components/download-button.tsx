import { getRelease } from "@/lib/github";
import { hero, site } from "@/content";
import { Button } from "@/components/ui/button";
import { ExtLink } from "./ext-link";

/** Links straight at the newest DMG on GitHub. Falls back to the Releases page. */
export async function DownloadButton({ size = "lg", center = false, utm = "download" }: { size?: "lg" | "sm"; center?: boolean; utm?: string }) {
  const rel = await getRelease();
  const href = rel?.dmgUrl ?? site.releases;
  const label = rel ? `Download Parrot ${rel.version}` : "Download Parrot";
  if (size === "sm") {
    return (
      <Button render={<ExtLink href={href} utm={utm} />} nativeButton={false} size="sm" className="rounded-full px-3.5">
        <span className="sm:hidden">Download</span>
        <span className="hidden sm:inline">{label}</span>
      </Button>
    );
  }
  return (
    <div className={center ? "flex flex-col items-center text-center" : ""}>
      <Button render={<ExtLink href={href} utm={utm} />} nativeButton={false} size="lg" className="h-12 rounded-full px-6 text-base">
        {label} for macOS
      </Button>
      <p className="mt-3 text-sm text-ink-2">
        {rel?.dmgSizeMB ? `${rel.dmgSizeMB} MB. ` : ""}
        {site.requirements}.{" "}
        <ExtLink className="underline underline-offset-4 hover:text-tone" href={`${site.repo}#build-from-source`} utm={`${utm}-source`}>
          {hero.buildFromSource}
        </ExtLink>
      </p>
    </div>
  );
}
