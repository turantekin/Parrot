import { cacheLife } from "next/cache";
import { pickRelease, type ApiRelease, type Release } from "./release";

const API = "https://api.github.com/repos/turantekin/Parrot";

function headers(): Record<string, string> {
  const h: Record<string, string> = { Accept: "application/vnd.github+json" };
  if (process.env.GITHUB_TOKEN) h.Authorization = `Bearer ${process.env.GITHUB_TOKEN}`;
  return h;
}

/** Newest release, refreshed about hourly. Null when GitHub is unreachable. */
export async function getRelease(): Promise<Release | null> {
  "use cache";
  cacheLife("hours");
  try {
    const res = await fetch(`${API}/releases?per_page=10`, { headers: headers() });
    if (!res.ok) return null;
    return pickRelease((await res.json()) as ApiRelease[]);
  } catch {
    return null;
  }
}

/** Star count, refreshed about hourly. Null when GitHub is unreachable. */
export async function getStars(): Promise<number | null> {
  "use cache";
  cacheLife("hours");
  try {
    const res = await fetch(API, { headers: headers() });
    if (!res.ok) return null;
    const j = (await res.json()) as { stargazers_count?: unknown };
    return typeof j.stargazers_count === "number" ? j.stargazers_count : null;
  } catch {
    return null;
  }
}
