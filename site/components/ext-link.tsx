import type { ComponentProps } from "react";
import { isExternal, withUtm } from "@/lib/links";

/**
 * The one anchor for links that leave the page: new tab, no opener or referrer leak,
 * and UTM tags on every outbound http(s) link. mailto and #anchors pass through untouched.
 * Spreads every prop (including ref) so it also works as a Base UI `render` element.
 */
export function ExtLink({ href, utm, ...props }: ComponentProps<"a"> & { href: string; utm?: string }) {
  if (!isExternal(href)) return <a href={href} {...props} />;
  return <a href={withUtm(href, utm)} target="_blank" rel="noopener noreferrer" {...props} />;
}
