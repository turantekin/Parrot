import { describe, expect, it } from "vitest";
import { pickRelease, type ApiRelease } from "./release";

const dmg = (v: string) => ({
  name: `Parrot-${v}.dmg`,
  browser_download_url: `https://github.com/turantekin/Parrot/releases/download/v${v}/Parrot-${v}.dmg`,
  size: 17 * 1048576,
});
const rel = (over: Partial<ApiRelease> = {}): ApiRelease => ({
  tag_name: "v0.17.1",
  draft: false,
  prerelease: true,
  html_url: "https://github.com/turantekin/Parrot/releases/tag/v0.17.1",
  published_at: "2026-09-03T13:29:01Z",
  assets: [dmg("0.17.1")],
  ...over,
});

describe("pickRelease", () => {
  it("takes the newest non-draft release even when every release is a pre-release", () => {
    const r = pickRelease([
      rel({ tag_name: "v0.17.0", published_at: "2026-09-01T15:47:15Z", assets: [dmg("0.17.0")] }),
      rel(),
    ]);
    expect(r?.version).toBe("0.17.1");
    expect(r?.dmgUrl).toContain("Parrot-0.17.1.dmg");
    expect(r?.dmgSizeMB).toBe(17);
  });
  it("skips drafts", () => {
    const r = pickRelease([rel({ tag_name: "v0.18.0", draft: true, published_at: "2026-10-01T00:00:00Z" }), rel()]);
    expect(r?.tag).toBe("v0.17.1");
  });
  it("copes with a release that has no dmg", () => {
    const r = pickRelease([rel({ assets: [] })]);
    expect(r?.dmgUrl).toBeNull();
    expect(r?.dmgSizeMB).toBeNull();
  });
  it("returns null for an empty list", () => {
    expect(pickRelease([])).toBeNull();
  });
});
