import { describe, expect, it } from "vitest";
import { isExternal, withUtm } from "./links";

describe("withUtm", () => {
  it("tags outbound links and names the spot on the page", () => {
    const u = new URL(withUtm("https://github.com/turantekin/Parrot", "nav-github"));
    expect(u.searchParams.get("utm_source")).toBe("parrot-landing");
    expect(u.searchParams.get("utm_medium")).toBe("website");
    expect(u.searchParams.get("utm_campaign")).toBe("landing-page");
    expect(u.searchParams.get("utm_content")).toBe("nav-github");
    expect(u.origin + u.pathname).toBe("https://github.com/turantekin/Parrot");
  });
  it("keeps existing params and never overwrites a UTM already on the link", () => {
    const u = new URL(withUtm("https://example.com/?ref=x&utm_source=keep", "footer"));
    expect(u.searchParams.get("ref")).toBe("x");
    expect(u.searchParams.get("utm_source")).toBe("keep");
    expect(u.searchParams.get("utm_medium")).toBe("website");
  });
  it("keeps the hash and the download filename intact", () => {
    expect(withUtm("https://github.com/turantekin/Parrot#build-from-source", "hero")).toBe(
      "https://github.com/turantekin/Parrot?utm_source=parrot-landing&utm_medium=website&utm_campaign=landing-page&utm_content=hero#build-from-source",
    );
    expect(withUtm("https://github.com/turantekin/Parrot/releases/download/v0.18.0/Parrot-0.18.0.dmg")).toContain("/Parrot-0.18.0.dmg?utm_source=");
  });
  it("leaves mailto and anchors alone", () => {
    expect(withUtm("mailto:uygar@turantekin.co.uk")).toBe("mailto:uygar@turantekin.co.uk");
    expect(withUtm("#top")).toBe("#top");
    expect(isExternal("mailto:x@y.z")).toBe(false);
    expect(isExternal("https://x.y")).toBe(true);
  });
});
