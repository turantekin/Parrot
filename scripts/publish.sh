#!/bin/bash
# Publish a release that users will actually receive.
#
#   scripts/publish.sh 0.14.1                  # notes generated from commits
#   scripts/publish.sh 0.14.1 notes.md         # notes from a file
#   scripts/publish.sh 0.14.1 notes.md plan.md # and draft the website from a plan
#
# If the notes file starts with "# Parrot 0.14.1: <tagline>", that line becomes
# the release title and is left out of the notes. openparrot.app shows the
# tagline in its "New in" pill. Without it the title is just "Parrot 0.14.1".
#
# The plan file is the site plan agreed in the release chat (/release-docs
# step 5): which new features go where on openparrot.app. With it, the site's
# "Site draft" workflow writes that copy as a draft PR. Without it, only the
# help sync starts.
#
# Run this after scripts/release.sh has built and notarized the DMG.
#
# Why this exists: since 0.14.0 a release is three steps, not two, and the
# third is invisible. The GitHub release is what people download; docs/appcast.xml
# is what installed copies read. Push only the first and the release exists but
# nobody's Parrot ever hears about it — a silent failure that looks exactly
# like a successful release. This does both, in the order that can't strand
# anyone, and refuses to claim success until it has fetched the live feed and
# followed its download link.
set -euo pipefail

VERSION="${1:?usage: scripts/publish.sh <version, e.g. 0.14.1> [notes-file] [site-plan-file]}"
NOTES_FILE="${2:-}"
PLAN_FILE="${3:-}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="turantekin/Parrot"
FEED="https://turantekin.github.io/Parrot/appcast.xml"
cd "$ROOT"

# GitHub Pages serves the feed from master:/docs, so an appcast committed
# anywhere else reaches nobody — and the release would look published.
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[ "$BRANCH" = master ] || {
  echo "!! on branch '$BRANCH' — publish from master, which is what Pages serves" >&2
  exit 1
}

DMG="dist/Parrot-$VERSION.dmg"
[ -f "$DMG" ] || { echo "!! $DMG missing — run scripts/release.sh $VERSION first" >&2; exit 1; }
# The Claude Desktop install file rides along when release.sh made one.
ASSETS=("$DMG")
[ -f dist/Parrot.mcpb ] && ASSETS+=(dist/Parrot.mcpb)

# A DMG that isn't stapled means notarization was skipped, which would ship
# users a build Gatekeeper rejects.
if ! xcrun stapler validate "$DMG" >/dev/null 2>&1; then
  echo "!! $DMG is not notarized/stapled — did you use SKIP_NOTARIZE?" >&2
  exit 1
fi

# The appcast must already describe THIS version; release.sh writes it.
grep -q "<sparkle:shortVersionString>$VERSION<" docs/appcast.xml || {
  echo "!! docs/appcast.xml doesn't mention $VERSION — re-run scripts/release.sh $VERSION" >&2
  exit 1
}

# Checked before anything is published, so a typo can't leave the site behind.
if [ -n "$PLAN_FILE" ] && [ ! -s "$PLAN_FILE" ]; then
  echo "!! site plan $PLAN_FILE is missing or empty" >&2
  exit 1
fi

TITLE="Parrot $VERSION"
if [ -n "$NOTES_FILE" ]; then
  [ -f "$NOTES_FILE" ] || { echo "!! notes file $NOTES_FILE not found" >&2; exit 1; }
  FIRST="$(head -1 "$NOTES_FILE")"
  if [[ "$FIRST" == "# Parrot $VERSION: "* ]]; then
    TITLE="${FIRST#\# }"
    BODY="$(mktemp)"
    tail -n +2 "$NOTES_FILE" | sed '/./,$!d' > "$BODY"  # drop the title and the blank lines after it
    NOTES_FILE="$BODY"
  fi
fi

# 1. The GitHub release first. The appcast points at this download, so it has
#    to exist before any Parrot is told to fetch it.
if gh release view "v$VERSION" --repo "$REPO" >/dev/null 2>&1; then
  echo "==> release v$VERSION already exists, leaving it alone"
else
  echo "==> creating GitHub release v$VERSION"
  if [ -n "$NOTES_FILE" ]; then
    gh release create "v$VERSION" "${ASSETS[@]}" --repo "$REPO" --prerelease --target master \
      --title "$TITLE" --notes-file "$NOTES_FILE"
  else
    gh release create "v$VERSION" "${ASSETS[@]}" --repo "$REPO" --prerelease --target master \
      --title "Parrot $VERSION" --generate-notes
  fi
fi

# 2. Then the feed, which is what existing installs read.
if git diff --quiet HEAD -- docs/appcast.xml; then
  echo "==> appcast already committed"
else
  echo "==> committing the appcast"
  git add docs/appcast.xml
  [ -f server.json ] && git add server.json
  git commit -q -m "Appcast: publish $VERSION to the update feed"
fi
git push -q origin master
echo "==> appcast pushed"

# 3. Prove it. GitHub Pages takes a moment to redeploy, so poll rather than
#    assume — an unverified publish is how the silent failure happens.
echo "==> waiting for the live feed to serve $VERSION"
for _ in $(seq 1 40); do
  if curl -fsS "$FEED" 2>/dev/null | grep -q "<sparkle:shortVersionString>$VERSION<"; then
    LIVE=yes; break
  fi
  sleep 15
done
[ "${LIVE:-}" = yes ] || { echo "!! $FEED still doesn't advertise $VERSION" >&2; exit 1; }

# And that the link it hands out actually resolves — a signed appcast pointing
# at a 404 updates nobody.
URL="$(curl -fsS "$FEED" | sed -n 's/.*enclosure url="\([^"]*\)".*/\1/p' | head -1)"
curl -fsIL "$URL" -o /dev/null || { echo "!! feed's download URL is unreachable: $URL" >&2; exit 1; }

echo
echo "Published $VERSION."
echo "  release: https://github.com/$REPO/releases/tag/v$VERSION"
echo "  feed:    $FEED (live, download link resolves)"
echo "  Installed copies will offer it within a day."

# 4. Tell the website. The release is out, so a failure here only warns.
#    Help sync copies docs/help from this tag (it also runs daily).
#    Site draft writes the copy from the site plan, and runs only with one.
#    The deploy hook rebuilds openparrot.app, so it shows the new version now.
SITE="turantekin/parrot-site"
echo
if gh workflow run help-sync.yml --repo "$SITE" >/dev/null 2>&1; then
  echo "==> started the help sync on parrot-site"
else
  echo "!! couldn't start the help sync; its daily run will catch up" >&2
fi
# The site caches the release list for an hour. A fresh build (no build
# cache) shows the new version and download now. The hook URL triggers
# production builds, so it lives in the login Keychain, never in this repo.
if HOOK="$(security find-generic-password -s parrot-site-deploy-hook -w 2>/dev/null)"; then
  if curl -fsS -X POST "$HOOK?buildCache=false" >/dev/null 2>&1; then
    echo "==> rebuilding openparrot.app so it shows $VERSION"
  else
    echo "!! couldn't start the site rebuild; it shows $VERSION within the hour anyway" >&2
  fi
else
  echo "==> no parrot-site-deploy-hook in the Keychain, so openparrot.app shows $VERSION within the hour"
fi
DRAFT="gh workflow run site-draft.yml --repo $SITE -F plan=@$PLAN_FILE"
if [ -z "$PLAN_FILE" ]; then
  echo "==> no site plan, so no website draft. Update the site in a parrot-site chat with /after-release."
elif gh workflow run site-draft.yml --repo "$SITE" -F "plan=@$PLAN_FILE" >/dev/null 2>&1; then
  echo "==> started the website draft from $PLAN_FILE"
else
  echo "!! couldn't start the website draft. Retry with: $DRAFT" >&2
fi
echo "  PRs to review: https://github.com/$SITE/pulls"

# 5. List this version in the official MCP registry, which MCP directories and
#    apps read. Needs mcp-publisher (brew). Its registry login expires within
#    minutes, so log in fresh with the gh CLI's token every time. Warn only.
echo
if ! grep -q "\"version\": \"$VERSION\"" server.json 2>/dev/null; then
  echo "!! server.json doesn't name $VERSION, so the MCP registry keeps the old version" >&2
elif ! command -v mcp-publisher >/dev/null; then
  echo "!! mcp-publisher missing (brew install mcp-publisher), so the MCP registry keeps the old version" >&2
elif MCP_OUT="$(mcp-publisher login github --token "$(gh auth token)" 2>&1 && mcp-publisher publish 2>&1)"; then
  echo "==> listed $VERSION in the MCP registry"
else
  # A re-run for the same version lands here too: "cannot publish duplicate version".
  echo "!! MCP registry publish failed: $(echo "$MCP_OUT" | tail -1)" >&2
  echo "   Retry with: mcp-publisher login github && mcp-publisher publish" >&2
fi
