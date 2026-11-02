#!/usr/bin/env bash
# Brings this fork up to upstream and installs it as /Applications/Strata.app.
#
# main mirrors upstream and only fast-forwards; fork holds our commits, rebased on main. A rebase conflict stops here:
# fix it, `git rebase --continue`, run again. rerere remembers the fix, so the same conflict never comes back.
#
#   scripts/fork-sync.sh            # sync, build, install
#   scripts/fork-sync.sh --no-sync  # build and install what's checked out
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "${1:-}" != "--no-sync" ]]; then
  if [[ -n "$(git status --porcelain)" ]]; then echo "Commit or stash your changes first." >&2; exit 1; fi
  if [[ "$(git branch --show-current)" != fork ]]; then echo "Run this from the fork branch." >&2; exit 1; fi
  git config rerere.enabled true
  git fetch upstream
  git fetch . upstream/main:main
  git push origin main
  git rebase main
  git push --force-with-lease origin fork
fi

# find-identity -v still lists revoked certificates, with a CSSMERR note.
STRATA_SIGNING_IDENTITY="${STRATA_SIGNING_IDENTITY:-$(security find-identity -v -p codesigning |
  awk '/Apple Development/ && !/CSSMERR/ { print $2; exit }')}"
export STRATA_SIGNING_IDENTITY
scripts/build.sh release

# Quit politely and stop if Strata stays open: it may be asking about a transfer, so it's never killed.
if pgrep -x Strata >/dev/null; then
  osascript -e 'tell application id "dev.strata.app" to quit' >/dev/null 2>&1 || true
  for _ in $(seq 1 100); do pgrep -x Strata >/dev/null || break; sleep 0.1; done
  if pgrep -x Strata >/dev/null; then
    echo "Strata is still open. Quit it and run scripts/fork-sync.sh --no-sync." >&2
    exit 1
  fi
fi

new=/Applications/Strata.app.new
rm -rf "$new"
ditto build/Strata.app "$new"
rm -rf /Applications/Strata.app
mv "$new" /Applications/Strata.app
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Strata.app
open /Applications/Strata.app
