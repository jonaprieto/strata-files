#!/usr/bin/env bash
# Publishes the tagged commit as a GitHub release and points Casks/strata.rb at it. homebrew-tap copies that cask, so
# this also asks it to sync. Tag the commit first, as fork-<version>: fork-sync.sh fetches upstream's v<version> tags,
# and a clash with one of those would stop it.
#
# Ad-hoc signed on purpose: a public build must not carry the personal identity fork-sync.sh signs with.
#
#   scripts/fork-release.sh 0.7.6
set -euo pipefail
cd "$(dirname "$0")/.."

version="${1:?Usage: $0 <version>}"
tag="fork-$version"
repo=jonaprieto/strata-files
if [[ -n "$(git status --porcelain)" ]]; then echo "Commit your changes first." >&2; exit 1; fi
if [[ "$(git branch --show-current)" != fork ]]; then echo "Run this from the fork branch." >&2; exit 1; fi
if [[ "$(git rev-parse HEAD)" != "$(git rev-parse "$tag^{commit}")" ]]; then echo "$tag must point at HEAD." >&2; exit 1; fi

STRATA_VERSION="$version" STRATA_BUILD_NUMBER="$(git rev-list --count HEAD)" scripts/build.sh release

app=build/Strata.app
codesign --verify --deep --strict "$app"
signature=$(codesign -dvv "$app" 2>&1)
if [[ "$signature" != *$'\nSignature=adhoc\n'* ]]; then
  echo "Refusing to publish a build that isn't ad-hoc signed." >&2; exit 1
fi
zip="build/Strata-$version.zip"
ditto -c -k --keepParent "$app" "$zip"
sha=$(shasum -a 256 "$zip" | cut -d' ' -f1)

git push origin HEAD "$tag"
# gh won't read tag notes together with -R, and -R keeps this from ever reaching upstream.
gh release create "$tag" "$zip" -R "$repo" --title "Strata fork $version" --verify-tag \
  --notes "$(git tag -l --format='%(contents:body)' "$tag")"

perl -pi -e "s/^  version .*/  version \"$version\"/; s/^  sha256 .*/  sha256 \"$sha\"/" Casks/strata.rb
git commit -q -m "Fork: point the cask at release $version" Casks/strata.rb
git push origin HEAD
gh workflow run sync.yml -R jonaprieto/homebrew-tap
