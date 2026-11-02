@AGENTS.md

## This fork

Work on `fork`: it holds our commits on top of `main`, which only mirrors upstream (`cristipufu/strata-files`). Never
push to upstream. `scripts/fork-sync.sh` syncs, builds and installs; `--no-sync` only builds and installs.
