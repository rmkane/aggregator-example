<!-- omit in toc -->
# absorb-submodules.sh

Converts git submodules into normal tracked directories while preserving their full commit history via a subtree merge. Designed for monorepo migrations where you want the history available but don't want to rewrite SHAs.

<!-- omit in toc -->
## Table of Contents

- [How it works](#how-it-works)
- [Why subtree merge instead of rewriting history](#why-subtree-merge-instead-of-rewriting-history)
- [Requirements](#requirements)
- [Before running](#before-running)
- [Usage](#usage)
  - [Commands](#commands)
  - [Options](#options)
  - [Examples](#examples)
- [Default import mode vs. `--branch`](#default-import-mode-vs---branch)
- [The `reset` command](#the-reset-command)
- [Browsing history after absorption](#browsing-history-after-absorption)
- [What the output looks like](#what-the-output-looks-like)
- [Limitations](#limitations)
- [ShellCheck](#shellcheck)

## How it works

For each submodule the script:

1. Fetches the submodule remote into a temporary local remote
2. Verifies the import ref resolves to a real commit before touching anything
3. Removes the submodule registration (`deinit`, `git rm`, `.git/modules` cleanup)
4. Commits the removal to clear the index (git refuses to merge with staged changes)
5. Merges the submodule history using the `ours` strategy — this records a merge parent link in the graph, preserving history reachability without rewriting any SHAs
6. Grafts the submodule's file tree under its original path via `git read-tree`
7. Squashes the two interim commits into one clean final commit via `reset --soft HEAD~2`

The result is one commit per submodule with the files in place, `.gitmodules` cleaned up, and the full original history reachable through the merge parent.

## Why subtree merge instead of rewriting history

Tools like `git filter-repo` can rewrite submodule history so paths are prefixed from the start, making plain `git log` work naturally. The tradeoff is that all SHAs change — breaking tags, external references, and any repo that forked from the submodule.

This script takes the conservative approach: no SHAs are rewritten, everything is preserved verbatim, and the merge parent link keeps the history provably connected. The cost is a slightly different query to browse that history (see [Browsing history](#browsing-history-after-absorption) below).

## Requirements

- Bash 3.2 or newer (macOS `/bin/bash` 3.2 and Bash 4.x/5.x are all supported)
- Git 2.22+ recommended (`git branch --show-current`; falls back gracefully on older versions)
- Network access to submodule remotes (unless already fetched locally)
- Clean working tree in both the parent repo and all submodules

## Before running

```bash
# Ensure submodules are initialized and up to date
git submodule update --init --recursive

# Optional but recommended: create a safety branch
git checkout -b absorb-submodules-backup

# Ensure remotes are current
git push origin develop
```

## Usage

```bash
./scripts/absorb-submodules.sh <command> [options]
```

### Commands

| Command | Description |
| ------- | ----------- |
| `run` | Absorb all submodules listed in `.gitmodules` |
| `reset` | Undo a previous run: reset to origin and reinitialize submodules |

### Options

| Option | Description |
| ------ | ----------- |
| `-n`, `--dry-run` | Print planned steps without executing any git commands |
| `-y`, `--yes` | Skip the 5-second confirmation prompt (for CI / scripts) |
| `-b`, `--branch NAME` | Import the tip of this branch instead of the pinned gitlink SHA |
| `--submodule NAME` | Absorb only the named submodule (partial migration) |
| `-h`, `--help` | Show full help |

### Examples

```bash
# Preview what will happen without making any changes
./scripts/absorb-submodules.sh run --dry-run

# Run against all submodules
./scripts/absorb-submodules.sh run

# Run non-interactively (CI)
./scripts/absorb-submodules.sh run --yes

# Import the develop branch tip instead of the pinned commit
./scripts/absorb-submodules.sh run -b develop

# Absorb only one submodule
./scripts/absorb-submodules.sh run --submodule my-lib

# Undo a previous run (preview)
./scripts/absorb-submodules.sh reset --dry-run

# Undo a previous run
./scripts/absorb-submodules.sh reset
```

## Default import mode vs. `--branch`

By default the script imports the exact commit pinned in the parent repo's `HEAD` tree (the gitlink SHA). This is the safest option — you get exactly what the parent repo was pointing at.

If you pass `-b develop`, the script fetches and imports the current tip of that branch on the submodule remote instead. Use this when the pinned commit is behind and you want to bring in the latest work before absorbing.

## The `reset` command

If a run fails partway through or you want to undo a completed absorption, `reset` detects how many commits the current branch is ahead of its upstream and resets exactly that many:

```bash
./scripts/absorb-submodules.sh reset --dry-run   # preview first
./scripts/absorb-submodules.sh reset
```

This works whether one submodule was absorbed or all of them, because it measures the actual divergence from origin rather than assuming a fixed commit count. After resetting, it runs `git submodule update --init --recursive` to restore the submodule state.

## Browsing history after absorption

Because the script uses a subtree merge rather than history rewriting, you need `--all` to traverse the merge parent chain when querying history:

```bash
# All commits that touched a given submodule path
git log --all -- demo-submodule-a/

# History of a specific file (following renames)
git log --all --follow -- demo-submodule-a/src/main/java/org/acme/App.java

# Visual graph in the terminal
git log --all --graph --oneline -- demo-submodule-a/

# Full visual graph in gitk
gitk --all -- demo-submodule-a/
```

The `--all` flag tells git to walk every ref including merge parents, which is where the submodule's original commits live. Without it, `git log` only sees the absorb commit itself.

GUI tools like GitKraken, SourceTree, and Tower all support `--all`-style graph views and will show the full merge parent chain visually. The merge commit appears as a node with two parents — one pointing forward into the monorepo's history, and one dropping back into the submodule's original commit chain.

## What the output looks like

```none
Repository: /path/to/repo
Branch:     develop
Submodules to absorb: my-lib shared-utils

=== Absorbing submodule 'my-lib' ===
    path:              my-lib
    remote:            git@github.com:org/my-lib.git
    .gitmodules branch:develop (informational unless -b is used)
    import mode:       pinned gitlink at HEAD
+ git fetch absorb-import-my-lib (pinned commit abc1234...)
    import ref:        abc1234...
+ git submodule deinit -f my-lib
+ git rm -f my-lib
+ git rm -f .gitmodules
[develop a1b2c3d] Absorb submodule my-lib into monorepo
 12 files changed, 340 insertions(+)
Done: my-lib/  (history: git log --all -- my-lib/)

...

All done.
--- git submodule status ---
---
  git log --all -- my-lib/
  git log --all -- shared-utils/
```

## Limitations

- Submodule paths containing spaces are not supported
- If interrupted by SIGKILL, a temporary remote named `absorb-import-<name>` may be left behind — remove it with `git remote remove absorb-import-<name>` before re-running
- Submodule tags are intentionally not imported into the parent repo (`--no-tags`); they have no meaning in the parent context and can collide with existing tags
- The script will refuse to re-absorb a path that is no longer a gitlink at HEAD — use `reset` to restore the submodule state first if needed

## ShellCheck

It is recommended to run ShellCheck against this script in CI or as a pre-commit hook:

```bash
shellcheck scripts/absorb-submodules.sh
```

See [shellcheck.net](https://www.shellcheck.net) for installation instructions.
