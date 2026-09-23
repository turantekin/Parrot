export type ApiRelease = {
  tag_name: string;
  draft: boolean;
  prerelease: boolean;
  html_url: string;
  published_at: string;
  assets: { name: string; browser_download_url: string; size: number }[];
};

export type Release = {
  version: string;
  tag: string;
  url: string;
  dmgUrl: string | null;
  dmgSizeMB: number | null;
  publishedAt: string;
};

/** Newest non-draft release. Pre-releases count: every Parrot release so far is one. */
export function pickRelease(list: ApiRelease[]): Release | null {
  const r = list
    .filter((x) => !x.draft)
    .sort((a, b) => b.published_at.localeCompare(a.published_at))[0];
  if (!r) return null;
  const dmg = r.assets.find((a) => a.name.endsWith(".dmg"));
  return {
    version: r.tag_name.replace(/^v/, ""),
    tag: r.tag_name,
    url: r.html_url,
    dmgUrl: dmg?.browser_download_url ?? null,
    dmgSizeMB: dmg ? Math.round(dmg.size / 1048576) : null,
    publishedAt: r.published_at,
  };
}
