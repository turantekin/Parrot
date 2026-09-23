import { copyFileSync, mkdirSync, readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const site = dirname(dirname(fileURLToPath(import.meta.url)));
const repo = dirname(site);
const imgSrc = join(repo, "docs/help/img");
const imgDst = join(site, "public/img");
mkdirSync(imgDst, { recursive: true });
for (const f of readdirSync(imgSrc)) {
  if (f.endsWith(".png")) copyFileSync(join(imgSrc, f), join(imgDst, f));
}
const icon = join(repo, "Parrot/Assets.xcassets/AppIcon.appiconset/icon_512.png");
copyFileSync(icon, join(site, "public/icon.png"));
copyFileSync(icon, join(site, "app/icon.png"));
console.log("assets synced");
