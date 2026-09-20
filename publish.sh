#!/usr/bin/env bash
# Build the course and publish it to the public GitHub Pages site.
#
#   ./publish.sh
#
# The source repo (this one) is private. The rendered HTML is pushed to a
# separate public repo, which GitHub Pages serves. Pages cannot serve from a
# private repo without Enterprise, hence the split.
#
# Live site: https://maanavkhaitan.github.io/agent-engineering-course-site/
set -euo pipefail

SITE_REPO="MaanavKhaitan/agent-engineering-course-site"
GH_USER="MaanavKhaitan"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Pages serves a project site from /<repo-name>/, so the build needs a matching
# baseurl. Derive it from the repo name so the two can never drift apart —
# getting this wrong yields a live site with no CSS and dead navigation.
BASEURL="/${SITE_REPO##*/}"

# ${VAR,,} would be cleaner but needs bash 4; macOS ships bash 3.2.
SITE_URL="https://$(printf %s "$GH_USER" | tr '[:upper:]' '[:lower:]').github.io${BASEURL}/"

step() { printf '\n==> %s\n' "$1"; }

step "Checking Docker"
if ! docker info >/dev/null 2>&1; then
  echo "Docker isn't running. Starting Docker Desktop…"
  open -a Docker
  until docker info >/dev/null 2>&1; do sleep 2; done
  echo "Docker ready."
fi

step "Building site (baseurl: $BASEURL)"
docker run --rm -v "$SRC":/site -w /site \
  -e BUNDLE_PATH=/site/vendor/bundle \
  ruby:3.3 bash -lc "bundle install --quiet && bundle exec jekyll build --destination /site/_site --baseurl '$BASEURL'"

# A build that silently produced nothing would otherwise wipe the live site.
page_count=$(find "$SRC/_site" -maxdepth 1 -name '*.html' | wc -l | tr -d ' ')
[ "$page_count" -gt 0 ] || { echo "Build produced no HTML pages — aborting."; exit 1; }
echo "Built $page_count pages."

step "Verifying pages are set to noindex"
missing=0
for f in "$SRC"/_site/*.html; do
  grep -q 'name="robots" content="noindex' "$f" || { echo "  no noindex: $(basename "$f")"; missing=1; }
done
[ "$missing" -eq 0 ] || { echo "Some pages would be indexable — aborting. See _includes/head_custom.html."; exit 1; }
echo "All $page_count pages carry noindex."

step "Publishing to $SITE_REPO"
# The osxkeychain credential helper may resolve to a different GitHub account
# than the one that owns the site repo, which fails the push with a 403. Use an
# explicit token for GH_USER instead of whatever the helper hands back.
TOKEN="$(gh auth token --user "$GH_USER" 2>/dev/null || true)"
[ -n "$TOKEN" ] || { echo "No gh token for $GH_USER. Run: gh auth login --user $GH_USER"; exit 1; }
AUTH_URL="https://x-access-token:${TOKEN}@github.com/${SITE_REPO}.git"

PUB="$(mktemp -d)"
trap 'rm -rf "$PUB"' EXIT   # temp clone holds a token in its remote; always clean up

git clone -q --depth 1 "$AUTH_URL" "$PUB"
cd "$PUB"
git config user.name "$GH_USER"
git config user.email "maanav@infiniteworlds.xyz"

# Replace the published tree wholesale so deleted pages actually disappear.
find . -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
cp -R "$SRC/_site/." .
touch .nojekyll   # the HTML is already built; don't let Pages run Jekyll again

git add -A
if git diff --cached --quiet; then
  echo "No changes to publish — site is already up to date."
  exit 0
fi

git commit -qm "Publish site: $(date -u '+%Y-%m-%d %H:%M UTC')"
git push -q "$AUTH_URL" HEAD:main
echo "Pushed $(git rev-parse --short HEAD)."

step "Waiting for GitHub Pages to serve the new build"
for _ in $(seq 1 60); do
  if curl -sfL --max-time 10 "$SITE_URL" | grep -q 'content="noindex'; then
    echo "Live: $SITE_URL"
    exit 0
  fi
  sleep 10
done
echo "Pushed, but the site didn't update within 10 minutes. Check:"
echo "  gh api repos/$SITE_REPO/pages/builds/latest --jq .status,.error.message"
exit 1
