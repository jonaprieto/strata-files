#!/usr/bin/env bash
# Profiles the git workbench and the pane paths it touches, before and after.
#
#   scripts/benchmark-git.sh            # HEAD against main
#   scripts/benchmark-git.sh v0.8.0     # HEAD against another commit
#   scripts/benchmark-git.sh --head     # HEAD only (no base build)
#
# The pane benchmarks (navigating a folder of 5,000 items, validating menus) run unchanged at the base commit, in a
# worktree of its own, and at HEAD, so both sides are measured the same way on the same machine. The git benchmarks
# time the status view on a 3,000-file repository against the git commands it runs. Debug builds, medians in
# milliseconds. Never run alongside another test run. For where time goes, record in Instruments' Time Profiler with
# Points of Interest: git loads, writes and the main-thread apply are signposted (subsystem dev.strata.app,
# category git), and debug builds log every main-thread stall over 0.1 s (log stream --predicate 'category == "stalls"').
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
base="${1:-main}"
results=$(mktemp -d "${TMPDIR:-/tmp}/strata-git-benchmark.XXXXXX")
cleanup() {
  if [[ -n "${worktree:-}" ]]; then git worktree remove --force "$worktree" >/dev/null 2>&1 || true; fi
  rm -rf "$results"
}
trap cleanup EXIT

run() { # <folder> <filter> <output>
  (cd "$1" && STRATA_BENCHMARK=1 swift test --filter "$2" 2>&1) | grep '^BENCH ' | sed 's/^BENCH //' > "$3"
}

echo "HEAD ($(git rev-parse --short HEAD)): building and measuring…"
# One suite at a time: suites run in parallel, and git's work would slow the pane's timings.
run . 'PaneBenchmarks' "$results/head"
run . 'GitBenchmarks' "$results/head-git"
cat "$results/head-git" >> "$results/head"

if [[ "$base" != "--head" ]]; then
  worktree="$results/base"
  git worktree add --detach "$worktree" "$base" >/dev/null
  mkdir -p "$worktree/Tests/StrataTests/Benchmarks"
  cp Tests/StrataTests/Benchmarks/PaneBenchmarks.swift "$worktree/Tests/StrataTests/Benchmarks/"
  echo "$base ($(git rev-parse --short "$base")): building and measuring (a full build of its own)…"
  run "$worktree" 'PaneBenchmarks' "$results/base-times"
fi

printf '\n%-24s %12s %12s %9s\n' benchmark "$base" HEAD change
while read -r name now; do
  before=$(awk -v n="$name" '$1 == n { print $2 }' "$results/base-times" 2>/dev/null || true)
  if [[ -n "$before" ]]; then
    change=$(awk -v a="$before" -v b="$now" 'BEGIN { printf "%+.1f%%", (b - a) / a * 100 }')
    printf '%-24s %10s ms %10s ms %9s\n' "$name" "$before" "$now" "$change"
  else
    printf '%-24s %12s %10s ms %9s\n' "$name" "-" "$now" "new"
  fi
done < "$results/head"
