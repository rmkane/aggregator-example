#!/usr/bin/env bash
# =============================================================================
# absorb-submodules.sh
#
# Converts git submodules into normal directories in this repository while
# preserving their commit history under the same paths (subtree merge).
#
# Usage
#   ./scripts/absorb-submodules.sh absorb [options]
#   ./scripts/absorb-submodules.sh --help
#
# Examples
#   ./scripts/absorb-submodules.sh absorb --dry-run
#   ./scripts/absorb-submodules.sh absorb
#   ./scripts/absorb-submodules.sh absorb -b develop
#
# Requirements
#   - Run from the repository root, or any path inside it
#   - Clean working tree with no uncommitted changes
#   - Network access to submodule remotes (unless already fetched)
#
# After running
#   - .gitmodules is removed when no submodules remain
#   - .git/modules/<path> is deleted for each absorbed submodule
#   - Former submodule paths contain normal tracked files
#   - History: git log --all -- <path>/  (see "Verifying history" below)
#
# Recommended before running
#   git checkout -b absorb-submodules-backup   # optional safety branch
#   git push origin develop                    # ensure remotes are current
#
# Verifying history
#   Subtree merges rewrite paths under a prefix; use --all to scan all refs:
#     git log --all -- <path>/
#   For a single file (including renames): git log --follow -- <path>/file
#
# Limitations
#   - Submodule paths containing spaces are not supported.
#   - If interrupted, re-run after cleaning any leftover absorb-import-* remote
#     (git remote list); the script also removes them on exit when possible.
# =============================================================================
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

COMMAND=""
DRY_RUN=false
# When set, import the branch tip from the submodule remote instead of the
# commit pinned in the current HEAD tree (gitlink).
IMPORT_BRANCH=""
# Set while a temporary import remote is registered; cleared after each absorb.
ACTIVE_IMPORT_REMOTE=""

usage() {
  cat <<EOF
Usage:
  $0 absorb [options]
  $0 --help

Commands:
  absorb              Absorb all submodules listed in .gitmodules

Options:
  -n, --dry-run       Print planned steps without executing git commands
  -b, --branch NAME   Import history leading to this branch tip
                      (default: the submodule commit pinned at HEAD)
  -h, --help          Show this help

Notes:
  - Default import uses the gitlink SHA at HEAD, not the branch in .gitmodules.
  - Creates one commit per submodule. Requires a clean working tree.
  - Verify history with: git log --all -- <path>/

Examples:
  $0 absorb --dry-run
  $0 absorb
  $0 absorb -b develop
EOF
}

log() { printf '%s\n' "$*"; }

# Log and execute a command (skipped in dry-run except where noted).
run() {
  if $DRY_RUN; then
    log "[dry-run] $*"
  else
    log "+ $*"
    "$@"
  fi
}

cleanup_on_exit() {
  # Remove temporary import remote if the script exits early (error or Ctrl+C).
  if [[ -n "${ACTIVE_IMPORT_REMOTE:-}" ]]; then
    log "Cleaning up temporary remote: ${ACTIVE_IMPORT_REMOTE}" >&2
    remove_import_remote "$ACTIVE_IMPORT_REMOTE"
    ACTIVE_IMPORT_REMOTE=""
  fi
}

require_clean_tree() {
  [[ -z "$(git status --porcelain)" ]] && return 0
  log "Error: working tree is not clean. Commit or stash first." >&2
  exit 1
}

submodule_names() {
  [[ -f .gitmodules ]] || return 0
  # Parse config keys (handles submodule names that contain dots, e.g. foo.bar).
  local key
  while IFS= read -r key; do
    [[ "$key" =~ ^submodule\.(.+)\.path$ ]] || continue
    printf '%s\n' "${BASH_REMATCH[1]}"
  done < <(git config -f .gitmodules --name-only --get-regexp '^submodule\..+\.path$' 2>/dev/null || true)
}

submodule_path() {
  git config -f .gitmodules --get "submodule.${1}.path"
}

remove_import_remote() {
  git remote remove "${1}" 2>/dev/null || true
}

assert_is_gitlink() {
  local path="$1"
  local mode
  mode="$(git ls-tree HEAD "$path" 2>/dev/null | awk '{print $1}')"

  if [[ "$mode" == "160000" ]]; then
    return 0
  fi

  log "Error: ${path} is not a submodule gitlink at HEAD (mode=${mode:-<missing>})." >&2
  if [[ -n "$mode" ]]; then
    log "       It may already have been absorbed on this branch." >&2
  fi
  exit 1
}

verify_import_ref() {
  local ref="$1"
  if ! git rev-parse --verify "${ref}^{commit}" >/dev/null 2>&1; then
    log "Error: import ref does not resolve to a commit: ${ref}" >&2
    log "       Fetch may have failed or the server may block direct SHA fetch." >&2
    log "       Try: $0 absorb -b <branch>   or ensure the pinned commit exists on the remote." >&2
    exit 1
  fi
}

fetch_pinned_commit() {
  local remote_name="$1"
  local commit="$2"

  log "+ git fetch ${remote_name} (pinned commit ${commit})"
  git fetch "$remote_name" --tags 2>/dev/null || true

  if git fetch "$remote_name" "$commit" 2>/dev/null; then
    return 0
  fi

  # Some hosts disallow fetching arbitrary SHAs; a full fetch may still reach the commit.
  log "  direct SHA fetch failed; trying full remote fetch..."
  git fetch "$remote_name" 2>/dev/null || true
}

resolve_import_ref() {
  local remote_name="$1"
  local path="$2"

  if [[ -n "$IMPORT_BRANCH" ]]; then
    run git fetch "$remote_name" "$IMPORT_BRANCH"
    printf '%s\n' "${remote_name}/${IMPORT_BRANCH}"
    return 0
  fi

  local commit
  commit="$(git ls-tree HEAD "$path" | awk '{print $3}')"

  if [[ -z "$commit" ]]; then
    log "Error: no gitlink for ${path} at HEAD." >&2
    exit 1
  fi

  fetch_pinned_commit "$remote_name" "$commit"
  printf '%s\n' "$commit"
}

remove_submodule_registration() {
  local name="$1"
  local path="$2"

  run git submodule deinit -f "$path"
  run git rm -f "$path"
  run rm -rf ".git/modules/${path}"

  if [[ -f .gitmodules ]]; then
    # FIX: route through run() so dry-run captures these steps too.
    run git config -f .gitmodules --remove-section "submodule.${name}"

    # FIX: count remaining submodule keys rather than relying on --list exit
    # code, which also fails on whitespace-only or comment-only files and would
    # silently delete a partially-valid .gitmodules.
    local remaining
    remaining=$(git config -f .gitmodules --get-regexp '^submodule\.' 2>/dev/null | wc -l || echo 0)
    if [[ "$remaining" -eq 0 ]]; then
      run git rm -f .gitmodules
    else
      run git add .gitmodules
    fi
  fi

  # FIX: route through run() so dry-run captures this step too.
  run git config --remove-section "submodule.${name}" 2>/dev/null || true
}

absorb_one() {
  local name="$1"
  local path url branch remote_name import_ref pinned_sha

  path="$(submodule_path "$name")"
  url="$(git config -f .gitmodules --get "submodule.${name}.url")"
  branch="$(git config -f .gitmodules --get "submodule.${name}.branch" 2>/dev/null || true)"
  remote_name="absorb-import-${name}"
  pinned_sha="$(git ls-tree HEAD "$path" | awk '{print $3}')"

  log ""
  log "=== Absorbing submodule '${name}' ==="
  log "    path:              ${path}"
  log "    remote:            ${url}"
  log "    .gitmodules branch:${branch:-<none>} (informational unless -b is used)"
  log "    import mode:       ${IMPORT_BRANCH:+branch ${IMPORT_BRANCH}}${IMPORT_BRANCH:-pinned gitlink at HEAD}"

  assert_is_gitlink "$path"

  if $DRY_RUN; then
    log "[dry-run] Would add temporary remote: ${remote_name} -> ${url}"
    if [[ -n "$IMPORT_BRANCH" ]]; then
      log "[dry-run] Would fetch branch: ${IMPORT_BRANCH}"
    else
      log "[dry-run] Would fetch pinned gitlink: ${pinned_sha}"
    fi
    log "[dry-run] Would verify import ref, remove submodule registration,"
    log "[dry-run] subtree-merge history, and commit imported tree at ${path}/"
    return 0
  fi

  remove_import_remote "$remote_name"
  git remote add "$remote_name" "$url"
  ACTIVE_IMPORT_REMOTE="$remote_name"

  import_ref="$(resolve_import_ref "$remote_name" "$path")"
  log "    import ref:        ${import_ref}"

  # FIX: verify the import ref *before* any destructive steps. If the ref is
  # bad at this point (bad fetch, server restriction, etc.) the submodule
  # registration would already have been removed, leaving the tree in a
  # half-absorbed state with no easy recovery.
  verify_import_ref "$import_ref"

  remove_submodule_registration "$name" "$path"

  if ! git merge -s ours --no-commit --allow-unrelated-histories "$import_ref"; then
    # cleanup_on_exit handles the remote; advise on the merge state only.
    log "Error: merge failed. Run: git merge --abort" >&2
    exit 1
  fi

  # FIX: surface a clear recovery hint if read-tree fails. At this point the
  # merge has been staged; aborting the merge and hard-resetting HEAD restores
  # the index and working tree to the pre-absorb state for this submodule.
  log "+ git read-tree --prefix=${path}/ -u ${import_ref}"
  git read-tree --prefix="${path}/" -u "$import_ref" || {
    log "Error: read-tree failed." >&2
    log "       Run: git merge --abort" >&2
    exit 1
  }

  # FIX: only emit the pinned-SHA line when it is actually set (i.e. not using
  # --branch mode), so the commit message does not contain a trailing blank line
  # when IMPORT_BRANCH is set and pinned_line is empty.
  local pinned_line=""
  if [[ -z "$IMPORT_BRANCH" && -n "$pinned_sha" ]]; then
    pinned_line="Original pinned gitlink SHA: ${pinned_sha}"
  fi

  git commit -m "$(cat <<EOF
Absorb submodule ${name} into monorepo

Import history from ${url} at ${path}/.
Import ref: ${import_ref}
${pinned_line:+"${pinned_line}"}
Removes submodule link; directory is now part of this repository.
EOF
)"

  remove_import_remote "$remote_name"
  ACTIVE_IMPORT_REMOTE=""
  log "Done: ${path}/  (history: git log --all -- ${path}/)"
}

parse_args() {
  [[ $# -eq 0 ]] && {
    usage
    exit 0
  }

  while [[ $# -gt 0 ]]; do
    case "$1" in
      absorb)
        COMMAND="absorb"
        shift
        ;;
      -n | --dry-run)
        DRY_RUN=true
        shift
        ;;
      -b | --branch)
        IMPORT_BRANCH="${2:-}"
        [[ -n "$IMPORT_BRANCH" ]] || {
          log "Error: --branch requires a value" >&2
          exit 1
        }
        shift 2
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      *)
        log "Unknown argument: $1" >&2
        echo
        usage
        exit 1
        ;;
    esac
  done
}

main() {
  parse_args "$@"

  [[ "$COMMAND" == "absorb" ]] || {
    log "Error: missing required command 'absorb'" >&2
    echo
    usage
    exit 1
  }

  trap cleanup_on_exit EXIT
  require_clean_tree

  local names=()
  local name path

  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    names+=("$name")
  done < <(submodule_names)

  [[ ${#names[@]} -gt 0 ]] || {
    log "No submodules defined in .gitmodules — nothing to do."
    exit 0
  }

  # FIX: warn explicitly when .gitmodules exists but yielded no submodule
  # paths, which most likely indicates a malformed or partially-edited file.
  if [[ -f .gitmodules && ${#names[@]} -eq 0 ]]; then
    log "Warning: .gitmodules exists but no submodule paths were found. Malformed?" >&2
  fi

  log "Repository: ${ROOT}"
  log "Submodules to absorb: ${names[*]}"

  if ! $DRY_RUN; then
    log ""
    log "This will create one commit per submodule."
    log "Press Ctrl+C within 5 seconds to cancel..."
    sleep 5
  fi

  # Absorb each submodule and collect its resolved path for the final summary.
  # The paths array is built here rather than upfront so it stays in sync with
  # the names that were actually processed.
  local paths=()
  for name in "${names[@]}"; do
    absorb_one "$name"
    paths+=("$(git config -f .gitmodules --get "submodule.${name}.path" 2>/dev/null || echo "$name")")
  done

  log ""
  log "All done."
  log "Verify with:"
  log "  git submodule status    # should report no submodules"
  for path in "${paths[@]}"; do
    log "  git log --all -- ${path}/"
  done
}

main "$@"
