#!/usr/bin/env bash
# ==============================================================================
# Filename: scripts/absorb-submodules.sh
# Description: Absorb submodules into the aggregator project
# Usage: ./scripts/absorb-submodules.sh
# Example: ./scripts/absorb-submodules.sh absorb -b develop
# Example: ./scripts/absorb-submodules.sh absorb -n
# Example: ./scripts/absorb-submodules.sh absorb -h
# ==============================================================================
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

COMMAND=""
DRY_RUN=false
IMPORT_BRANCH=""

usage() {
  cat <<EOF
Usage:
  $0 absorb [options]
  $0 -h | --help

Commands:
  absorb              Absorb configured git submodules

Options:
  -n, --dry-run       Print actions without changing anything
  -b, --branch NAME   Import submodule history from this branch
                      Default: import the pinned submodule commit from HEAD
  -h, --help          Show this help

Examples:
  $0 absorb --dry-run
  $0 absorb
  $0 absorb -b develop
EOF
}

log() { printf '%s\n' "$*"; }

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

  git config -f .gitmodules --get-regexp '^submodule\..*\.path$' 2>/dev/null \
    | sed -E 's/^submodule\.(.*)\.path .*/\1/' || true
}

resolve_import_ref() {
  local remote_name="$1"
  local path="$2"

  if [[ -n "$IMPORT_BRANCH" ]]; then
    git fetch "$remote_name" "$IMPORT_BRANCH"
    printf '%s\n' "${remote_name}/${IMPORT_BRANCH}"
    return 0
  fi

  local commit
  commit="$(git ls-tree HEAD "$path" | awk '{print $3}')"

  if [[ -z "$commit" ]]; then
    log "Error: could not resolve gitlink commit for ${path}" >&2
    exit 1
  fi

  git fetch "$remote_name" --tags
  git fetch "$remote_name" "$commit" 2>/dev/null || true

  printf '%s\n' "$commit"
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
  log "    path:             ${path}"
  log "    remote:           ${url}"
  log "    configured branch:${branch:-<none>}"
  log "    import branch:    ${IMPORT_BRANCH:-<pinned gitlink commit>}"

  if $DRY_RUN; then
    log "[dry-run] Would fetch history, remove submodule metadata, and import files into ${path}/"
    return 0
  fi

  git remote remove "$remote_name" 2>/dev/null || true
  git remote add "$remote_name" "$url"

  import_ref="$(resolve_import_ref "$remote_name" "$path")"

  log "    import ref:       ${import_ref}"

  git merge -s ours --no-commit --allow-unrelated-histories "$import_ref"

  git submodule deinit -f "$path" 2>/dev/null || true
  git rm -f "$path"
  rm -rf ".git/modules/${path}"

  git config -f .gitmodules --remove-section "submodule.${name}" 2>/dev/null || true

  git read-tree --prefix="${path}/" -u "$import_ref"

  if [[ -f .gitmodules ]] && ! git config -f .gitmodules --list >/dev/null 2>&1; then
    git rm -f .gitmodules
  elif [[ -f .gitmodules ]]; then
    git add .gitmodules
  fi

  git commit -m "$(cat <<EOF
Absorb submodule ${name} into monorepo

Import history from ${url} at ${path}/.
Import ref: ${import_ref}

Removes submodule link; directory is now part of this repository.
EOF
)"

  git remote remove "$remote_name"
  git config --remove-section "submodule.${name}" 2>/dev/null || true

  log "Done: ${path}/"
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
      -n|--dry-run)
        DRY_RUN=true
        shift
        ;;
      -b|--branch)
        IMPORT_BRANCH="${2:-}"
        [[ -z "$IMPORT_BRANCH" ]] && {
          log "Error: --branch requires a value" >&2
          exit 1
        }
        shift 2
        ;;
      -h|--help)
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
  log "  git log --all -- path/to/module"
}

main "$@"