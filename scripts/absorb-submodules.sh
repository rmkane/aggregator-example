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
#   - git log -- <path>/ shows imported history (e.g. demo-submodule-a/)
#
# Recommended before running
#   git checkout -b absorb-submodules-backup   # optional safety branch
#   git push origin develop                    # ensure remotes are current
# =============================================================================
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

COMMAND=""
DRY_RUN=false
# When set, import the branch tip from the submodule remote instead of the
# commit pinned in the current HEAD tree (gitlink).
IMPORT_BRANCH=""

usage() {
  cat <<EOF
Usage:
  $0 absorb [options]
  $0 --help

Commands:
  absorb              Absorb all submodules listed in .gitmodules

Options:
  -n, --dry-run       Print planned git commands without executing them
  -b, --branch NAME   Import history leading to this branch tip
                      (default: the submodule commit pinned at HEAD)
  -h, --help          Show this help

Notes:
  - Default import uses the gitlink SHA recorded in HEAD, not the branch
    named in .gitmodules. That matches what the aggregator actually pins.
  - Creates one commit per submodule. Requires a clean working tree.
  - Run from a backup branch before pushing to a shared remote.

Examples:
  $0 absorb --dry-run
  $0 absorb
  $0 absorb -b develop
EOF
}

log() { printf '%s\n' "$*"; }

# Log and optionally execute a command (used for consistent dry-run output).
run() {
  if $DRY_RUN; then
    log "[dry-run] $*"
  else
    log "+ $*"
    "$@"
  fi
}

require_clean_tree() {
  [[ -z "$(git status --porcelain)" ]] && return 0
  log "Error: working tree is not clean. Commit or stash first." >&2
  exit 1
}

submodule_names() {
  [[ -f .gitmodules ]] || return 0
  # List submodule section names (e.g. demo-submodule-a) from .gitmodules paths.
  git config -f .gitmodules --get-regexp '^submodule\..*\.path$' 2>/dev/null \
    | sed -E 's/^submodule\.([^.]+)\.path .*/\1/' || true
}

remove_import_remote() {
  local remote_name="$1"
  # Idempotent: remote may not exist on the first submodule or after a failed run.
  git remote remove "$remote_name" 2>/dev/null || true
}

verify_import_ref() {
  local ref="$1"
  # Ensure the ref resolves to a commit before we touch the index or merge.
  if ! git rev-parse --verify "${ref}^{commit}" >/dev/null 2>&1; then
    log "Error: import ref does not resolve to a commit: ${ref}" >&2
    log "       Fetch may have failed or the branch/commit does not exist on the remote." >&2
    exit 1
  fi
}

resolve_import_ref() {
  local remote_name="$1"
  local path="$2"

  if [[ -n "$IMPORT_BRANCH" ]]; then
    # Explicit branch: import the remote branch tip (may differ from pinned gitlink).
    run git fetch "$remote_name" "$IMPORT_BRANCH"
    printf '%s\n' "${remote_name}/${IMPORT_BRANCH}"
    return 0
  fi

  # Default: import exactly what this repo pins for the submodule at HEAD.
  local commit
  commit="$(git ls-tree HEAD "$path" | awk '{print $3}')"

  if [[ -z "$commit" ]]; then
    log "Error: no gitlink for ${path} at HEAD — is it registered as a submodule?" >&2
    exit 1
  fi

  # Fetch the commit and its ancestors from the remote so 'git log -- path/' has history.
  run git fetch "$remote_name" "$commit"

  printf '%s\n' "$commit"
}

remove_submodule_registration() {
  local name="$1"
  local path="$2"

  # Drop submodule checkout metadata before we replace the gitlink with real files.
  run git submodule deinit -f "$path"
  run git rm -f "$path"
  run rm -rf ".git/modules/${path}"

  # Remove from .gitmodules; delete the file when no sections remain.
  if [[ -f .gitmodules ]]; then
    git config -f .gitmodules --remove-section "submodule.${name}" 2>/dev/null || true
    if [[ -f .gitmodules ]] && ! git config -f .gitmodules --list >/dev/null 2>&1; then
      git rm -f .gitmodules
    else
      git add .gitmodules
    fi
  fi

  # deinit does not always remove the local submodule.* config block.
  if ! $DRY_RUN; then
    git config --remove-section "submodule.${name}" 2>/dev/null || true
  fi
}

absorb_one() {
  local name="$1"
  local path url branch remote_name import_ref

  path="$(git config -f .gitmodules --get "submodule.${name}.path")"
  url="$(git config -f .gitmodules --get "submodule.${name}.url")"
  branch="$(git config -f .gitmodules --get "submodule.${name}.branch" 2>/dev/null || true)"
  remote_name="absorb-import-${name}"

  log ""
  log "=== Absorbing submodule '${name}' ==="
  log "    path:              ${path}"
  log "    remote:            ${url}"
  log "    .gitmodules branch:${branch:-<none>} (informational unless -b is used)"
  log "    import mode:       ${IMPORT_BRANCH:+branch ${IMPORT_BRANCH}}${IMPORT_BRANCH:-pinned gitlink at HEAD}"

  # Temporary remote — avoids mutating existing remotes; removed after each absorb.
  if $DRY_RUN; then
    log "[dry-run] git remote remove/add ${remote_name} -> ${url}"
    run git fetch "$remote_name" "${IMPORT_BRANCH:-<pinned-commit>}"
    log "[dry-run] Would verify import ref, remove submodule registration,"
    log "[dry-run] subtree-merge history, and commit imported tree at ${path}/"
    return 0
  fi

  remove_import_remote "$remote_name"
  git remote add "$remote_name" "$url"

  import_ref="$(resolve_import_ref "$remote_name" "$path")"
  log "    import ref:        ${import_ref}"
  verify_import_ref "$import_ref"

  # Remove gitlink and submodule machinery first so merge/read-tree operate on a clean index.
  remove_submodule_registration "$name" "$path"

  # Subtree merge: record a merge commit without taking their tree yet (strategy ours).
  run git merge -s ours --no-commit --allow-unrelated-histories "$import_ref"

  # Overlay their tree at the submodule path; prefixes paths in historical commits.
  run git read-tree --prefix="${path}/" -u "$import_ref"

  git commit -m "$(cat <<EOF
Absorb submodule ${name} into monorepo

Import history from ${url} at ${path}/.
Import ref: ${import_ref}

Removes submodule link; directory is now part of this repository.
EOF
)"

  remove_import_remote "$remote_name"
  log "Done: ${path}/  (history: git log -- ${path}/)"
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

  require_clean_tree

  local names=()
  while IFS= read -r name; do
    [[ -n "$name" ]] && names+=("$name")
  done < <(submodule_names)

  [[ ${#names[@]} -gt 0 ]] || {
    log "No submodules defined in .gitmodules — nothing to do."
    exit 0
  }

  log "Repository: ${ROOT}"
  log "Submodules to absorb: ${names[*]}"

  if ! $DRY_RUN; then
    log ""
    log "This will create one commit per submodule."
    log "Press Ctrl+C within 5 seconds to cancel..."
    sleep 5
  fi

  for name in "${names[@]}"; do
    absorb_one "$name"
  done

  log ""
  log "All done."
  log "Verify with:"
  log "  git submodule status"
  log "  git log -- demo-submodule-a/"
  log "  git log -- demo-submodule-b/"
}

main "$@"
