#!/usr/bin/env bash
#
# Absorb git submodules into this repository as regular directories, preserving
# their full commit history under the same paths (e.g. demo-submodule-a/).
#
# Uses git's subtree merge (read-tree) — no extra tools required.
#
# Usage:
#   ./scripts/absorb-submodules.sh [--dry-run]
#
# Requirements:
#   - Run from the repository root (or any path inside it)
#   - Clean working tree (no uncommitted changes)
#   - Network access to submodule remotes (unless already fetched)
#
# After running:
#   - .gitmodules is removed (when empty)
#   - .git/modules/<path> is deleted
#   - Former submodule paths contain normal tracked files
#   - git log -- demo-submodule-a/ shows imported history
#
# Recommended before running:
#   git checkout -b absorb-submodules-backup   # optional safety branch
#   git push origin develop                    # ensure remotes are current
#
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=true
elif [[ -n "${1:-}" ]]; then
  echo "Usage: $0 [--dry-run]" >&2
  exit 1
fi

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
  if ! git diff-index --quiet HEAD --; then
    log "Error: working tree has uncommitted changes. Commit or stash first." >&2
    exit 1
  fi
}

submodule_names() {
  if [[ ! -f .gitmodules ]]; then
    return 0
  fi
  git config -f .gitmodules --get-regexp '^submodule\..*\.path$' 2>/dev/null \
    | sed -E 's/^submodule\.([^.]+)\.path .*/\1/' || true
}

absorb_one() {
  local name="$1"
  local path url branch remote_name

  path="$(git config -f .gitmodules --get "submodule.${name}.path")"
  url="$(git config -f .gitmodules --get "submodule.${name}.url")"
  branch="$(git config -f .gitmodules --get "submodule.${name}.branch" 2>/dev/null || true)"
  branch="${branch:-main}"
  remote_name="absorb-import-${name}"

  log ""
  log "=== Absorbing submodule '${name}' ==="
  log "    path:   ${path}"
  log "    remote: ${url}"
  log "    branch: ${branch}"

  if $DRY_RUN; then
    log "[dry-run] Would fetch, remove submodule metadata, and merge history into ${path}/"
    return 0
  fi

  # Fetch full history from the submodule's canonical remote.
  git remote remove "${remote_name}" 2>/dev/null || true
  git remote add "${remote_name}" "${url}"
  git fetch "${remote_name}" "${branch}"

  if ! git rev-parse --verify "${remote_name}/${branch}" >/dev/null 2>&1; then
    log "Error: ${remote_name}/${branch} not found after fetch." >&2
    git remote remove "${remote_name}" 2>/dev/null || true
    exit 1
  fi

  # Drop submodule registration (gitlink + module metadata).
  git submodule deinit -f "${path}" 2>/dev/null || true
  git rm -f "${path}"
  rm -rf ".git/modules/${path}"
  git config -f .gitmodules --remove-section "submodule.${name}"

  # Merge unrelated histories, keep our tree aside, then import theirs under prefix.
  git merge -s ours --no-commit --allow-unrelated-histories "${remote_name}/${branch}"
  git read-tree --prefix="${path}/" -u "${remote_name}/${branch}"

  if [[ -f .gitmodules ]] && ! git config -f .gitmodules --list >/dev/null 2>&1; then
    git rm -f .gitmodules
  elif [[ -f .gitmodules ]]; then
    git add .gitmodules
  fi

  git commit -m "$(cat <<EOF
Absorb submodule ${name} into monorepo

Import full history from ${url} (${branch}) at ${path}/.
Removes submodule link; directory is now part of this repository.
EOF
)"

  git remote remove "${remote_name}"
  log "Done: ${path}/ (history available via: git log -- ${path}/)"
}

main() {
  require_clean_tree

  local names=()
  while IFS= read -r name; do
    [[ -n "$name" ]] && names+=("$name")
  done < <(submodule_names)

  if [[ ${#names[@]} -eq 0 ]]; then
    log "No submodules defined in .gitmodules — nothing to do."
    exit 0
  fi

  log "Repository: ${ROOT}"
  log "Submodules to absorb: ${names[*]}"
  if $DRY_RUN; then
    log ""
    log "Dry run only — no changes will be made."
  else
    log ""
    log "This will create one commit per submodule and rewrite how history is stored."
    log "Press Ctrl+C within 5 seconds to cancel..."
    sleep 5
  fi

  for name in "${names[@]}"; do
    absorb_one "$name"
  done

  if ! $DRY_RUN; then
    for name in "${names[@]}"; do
      git config --remove-section "submodule.${name}" 2>/dev/null || true
    done

    log ""
    log "All submodules absorbed."
    log "Verify with:"
    log "  git log --oneline -- demo-submodule-a/"
    log "  git log --oneline -- demo-submodule-b/"
    log "  git submodule status    # should report no submodules"
  fi
}

main "$@"
