import { site } from "@/content";

/** True for links that leave the page: http(s) to another origin. mailto and #anchors are not. */
export function isExternal(href: string): boolean {
  return /^https?:\/\//i.test(href);
}

/** Appends the site's UTM tags to an outbound link. Existing query params, including any UTMs, are kept. */
export function withUtm(href: string, content?: string): string {
  if (!isExternal(href)) return href;
  const url = new URL(href);
  const tags: Record<string, string | undefined> = {
    utm_source: site.utm.source,
    utm_medium: site.utm.medium,
    utm_campaign: site.utm.campaign,
    utm_content: content,
  };
  for (const [k, v] of Object.entries(tags)) {
    if (v && !url.searchParams.has(k)) url.searchParams.set(k, v);
  }
  return url.toString();
}
