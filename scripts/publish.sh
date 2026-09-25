#!/bin/bash
# Publish a release that users will actually receive.
#
#   scripts/publish.sh 0.14.1                  # notes generated from commits
#   scripts/publish.sh 0.14.1 notes.md         # notes from a file
#
# If the notes file starts with "# Parrot 0.14.1: <tagline>", that line becomes
# the release title and is left out of the notes. openparrot.app shows the
# tagline in its "New in" pill. Without it the title is just "Parrot 0.14.1".
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

VERSION="${1:?usage: scripts/publish.sh <version, e.g. 0.14.1> [notes-file]}"
NOTES_FILE="${2:-}"
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
    gh release create "v$VERSION" "$DMG" --repo "$REPO" --prerelease --target master \
      --title "$TITLE" --notes-file "$NOTES_FILE"
  else
    gh release create "v$VERSION" "$DMG" --repo "$REPO" --prerelease --target master \
      --title "Parrot $VERSION" --generate-notes
  fi
fi

# 2. Then the feed, which is what existing installs read.
if git diff --quiet HEAD -- docs/appcast.xml; then
  echo "==> appcast already committed"
else
  echo "==> committing the appcast"
  git add docs/appcast.xml
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

# 4. Tell the website. Help sync copies docs/help from this tag; Site draft
#    writes the site copy as a draft PR to review. Both also run daily, so a
#    failure here only delays them.
echo
for wf in help-sync.yml site-draft.yml; do
  if gh workflow run "$wf" --repo turantekin/parrot-site >/dev/null 2>&1; then
    echo "==> started $wf on parrot-site"
  else
    echo "!! couldn't start $wf on parrot-site; its daily run will catch up" >&2
  fi
done
echo "  PRs to review: https://github.com/turantekin/parrot-site/pulls"
