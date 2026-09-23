import { getStars } from "@/lib/github";

/** Live star count from GitHub. Renders nothing if the API is unreachable. */
export async function StarCount() {
  const stars = await getStars();
  if (stars === null) return null;
  return (
    <span className="ml-1.5 rounded-full bg-secondary px-2 py-0.5 font-mono text-xs text-ink-2">
      ★ {stars.toLocaleString("en-US")}
    </span>
  );
}
