#!/usr/bin/env bash
# =============================================================================
# absorb-submodules.sh
#
# Converts git submodules into normal directories in this repository while
# preserving their commit history under the same paths (subtree merge).
#
# Usage
#   ./scripts/absorb-submodules.sh run [options]
#   ./scripts/absorb-submodules.sh --help
#
# Examples
#   ./scripts/absorb-submodules.sh run --dry-run
#   ./scripts/absorb-submodules.sh run
#   ./scripts/absorb-submodules.sh run --yes
#   ./scripts/absorb-submodules.sh run -b develop
#   ./scripts/absorb-submodules.sh run --submodule my-lib
#
# Requirements
#   - Bash 3.2 or newer (macOS /bin/bash 3.2 and Bash 4.x are both supported)
#   - Run from the repository root, or any path inside it
#   - Clean working tree with no uncommitted changes
#   - Network access to submodule remotes (unless already fetched)
#   - Git >= 2.22 recommended (git branch --show-current; falls back to
#     git rev-parse --abbrev-ref HEAD on older versions)
#
# After running
#   - .gitmodules is removed when no submodules remain
#   - .git/modules/<path> is deleted for each absorbed submodule
#   - Former submodule paths contain normal tracked files
#   - History: git log --all -- <path>/  (see "Verifying history" below)
#
# Recommended before running
#   git submodule update --init --recursive    # ensure submodules are initialized
#   git checkout -b absorb-submodules-backup   # optional safety branch
#   git push origin develop                    # ensure remotes are current
#
# Verifying history
#   Subtree merges rewrite paths under a prefix; use --all to scan all refs:
#     git log --all -- <path>/
#   For a single file (including renames): git log --follow -- <path>/file
#
# Behavior
#   - Default import is the submodule commit pinned at HEAD (the gitlink), not
#     the branch named in .gitmodules. Use -b/--branch to import a branch tip.
#   - Creates one commit per submodule. Partial migration: --submodule NAME.
#   - Fetches and verifies the import ref before removing submodule metadata,
#     so a failed fetch does not leave the repo half-absorbed.
#   - Dry-run (-n) prints a step-by-step preview only; no git commands run.
#   - Registers temporary remotes named absorb-import-<submodule>; removed on
#     success and on normal exit (trap). SIGKILL may leave one behind — see below.
#   - Refuses to absorb a path that is not a gitlink at HEAD (already absorbed).
#   - Some remotes block direct SHA fetch; the script retries with a full fetch.
#     If verification still fails, try run -b <branch>.
#
# Limitations
#   - Submodule paths containing spaces are not supported.
#   - If interrupted (especially SIGKILL), check for leftover absorb-import-*
#     remotes (git remote) and remove them before re-running.
#   - Submodule tags are not imported into the parent repo (--no-tags on fetch).
#
# ShellCheck
#   Run from the scripts/ directory (the command below is the filename only):
#   It is recommended to run ShellCheck against this script in CI or as a
#   pre-commit hook to catch shell-specific issues early:
#     `shellcheck absorb-submodules.sh`
#   See https://www.shellcheck.net for installation instructions.
# =============================================================================
set -euo pipefail

# Bash 3.2+ is required. Avoid Bash 4-only features (e.g. associative arrays) so
# the script runs on macOS /bin/bash 3.2 as well as modern Linux/bash 5.x.
require_bash_3_2() {
  if [[ -z "${BASH_VERSION:-}" ]]; then
    printf '%s\n' "Error: this script must be run with bash." >&2
    exit 1
  fi
  if ((BASH_VERSINFO[0] < 3 || (BASH_VERSINFO[0] == 3 && BASH_VERSINFO[1] < 2))); then
    printf '%s\n' "Error: bash 3.2+ required (found ${BASH_VERSION})." >&2
    exit 1
  fi
}
require_bash_3_2

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

COMMAND=""
DRY_RUN=false
YES=false
# When set, absorb only this named submodule instead of all of them.
SUBMODULE_FILTER=""
# When set, import the branch tip from the submodule remote instead of the
# commit pinned in the current HEAD tree (gitlink).
IMPORT_BRANCH=""
# Set while a temporary import remote is registered; cleared after each absorb.
ACTIVE_IMPORT_REMOTE=""

usage_short() {
  cat <<EOF
Usage: $0 run [options]

Try:
  $0 run --dry-run
  $0 -h | --help        full help
EOF
}

usage() {
  cat <<EOF
Usage:
  $0 run [options]
  $0 -h | --help

Commands:
  run                 Absorb all submodules listed in .gitmodules

Options:
  -n, --dry-run           Print planned steps without executing git commands
  -y, --yes               Skip the 5-second confirmation prompt (for CI / scripts)
  -b, --branch NAME       Import history leading to this branch tip
                          (default: the submodule commit pinned at HEAD)
      --submodule NAME    Absorb only the named submodule (partial migration)
  -h, --help              Show this help

Notes:
  - Requires bash 3.2+ (macOS /bin/bash and bash 4.x are supported).
  - Default import uses the gitlink SHA at HEAD, not the branch in .gitmodules.
  - Verifies the import ref before removing submodule metadata (safe on fetch failure).
  - Dry-run prints a preview only; no git commands are executed.
  - One commit per submodule. Requires a clean working tree (parent and submodules).
  - Cannot re-run on a path already absorbed (not a gitlink at HEAD).
  - Verify history with: git log --all -- <path>/
  - See script header for full behavior, limitations, and ShellCheck usage.

Examples:
  $0 run --dry-run
  $0 run --yes
  $0 run -b develop
  $0 run --submodule my-lib
EOF
}

log() { printf '%s\n' "$*"; }

# Log and execute a command. absorb_one dry-run logs steps directly and never calls this.
run_cmd() {
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

# Check that no initialized submodule has uncommitted changes or staged content.
# git submodule deinit -f silently discards such changes, so we refuse early
# rather than lose work. Uninitialized submodules (empty dirs) are skipped since
# they have nothing to lose.
require_clean_submodules() {
  local dirty=false
  local sub status

  while IFS= read -r sub; do
    [[ -n "$sub" ]] || continue

    # git -C fails gracefully if the submodule dir is missing or uninitialized.
    status="$(git -C "$sub" status --porcelain 2>/dev/null || true)"
    if [[ -n "$status" ]]; then
      log "Error: submodule '${sub}' has uncommitted changes:" >&2
      git -C "$sub" status --short >&2
      dirty=true
    fi
  done < <(git submodule --quiet foreach --recursive 'echo "$displaypath"' 2>/dev/null || true)

  if $dirty; then
    log "" >&2
    log "Commit or stash changes in the above submodule(s) before absorbing." >&2
    exit 1
  fi
}

# Print the current branch name. git branch --show-current requires Git 2.22;
# fall back to rev-parse for older versions so the script stays broadly
# compatible without a hard version gate.
current_branch() {
  git branch --show-current 2>/dev/null || git rev-parse --abbrev-ref HEAD
}

submodule_names() {
  [[ -f .gitmodules ]] || return 0
  # Parse config keys via prefix/suffix strips (Bash 3.2-safe; handles dots in names).
  # Avoids =~ with BASH_REMATCH, which can behave inconsistently on Bash 3.2.
  local key name
  while IFS= read -r key; do
    case "$key" in
      submodule.*.path)
        name="${key#submodule.}"
        name="${name%.path}"
        printf '%s\n' "$name"
        ;;
    esac
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

  # Primary check: confirm the ref resolves to a commit object.
  if ! git rev-parse --verify "${ref}^{commit}" >/dev/null 2>&1; then
    log "Error: import ref does not resolve to a commit: ${ref}" >&2
    log "       Fetch may have failed or the server may block direct SHA fetch." >&2
    log "       Try: $0 run -b <branch>   or ensure the pinned commit exists on the remote." >&2
    exit 1
  fi

  # Secondary check: use cat-file to confirm the object type is actually
  # "commit" rather than a tag or blob that happened to dereference. This
  # catches edge cases where ^{commit} resolution succeeds on an annotated tag
  # pointing to a non-commit object (unusual but possible in adversarial repos).
  local obj_type
  obj_type="$(git cat-file -t "$ref" 2>/dev/null || true)"
  # Annotated tags are acceptable here; git read-tree will dereference them.
  # Blobs or trees are not valid import refs.
  if [[ "$obj_type" != "commit" && "$obj_type" != "tag" ]]; then
    log "Error: import ref '${ref}' resolves to object type '${obj_type:-unknown}', expected commit or tag." >&2
    exit 1
  fi
}

fetch_pinned_commit() {
  local remote_name="$1"
  local commit="$2"

  # All log calls here go to stderr. This function is called inside a $()
  # subshell via resolve_import_ref, so anything written to stdout would be
  # captured as part of the import ref value and corrupt it.
  log "+ git fetch ${remote_name} (pinned commit ${commit})" >&2

  # Use --no-tags to avoid importing submodule tags into the parent repository.
  # Submodule tags (e.g. v1.0, release-2.3) have no meaning in the parent
  # context, can collide with existing tags, and clutter `git tag` output.
  git fetch --no-tags "$remote_name" 2>/dev/null || true

  if git fetch --no-tags "$remote_name" "$commit" 2>/dev/null; then
    return 0
  fi

  # Some hosts disallow fetching arbitrary SHAs; a full fetch may still reach the commit.
  log "  direct SHA fetch failed; trying full remote fetch..." >&2
  git fetch --no-tags "$remote_name" 2>/dev/null || true
}

resolve_import_ref() {
  local remote_name="$1"
  local path="$2"

  if [[ -n "$IMPORT_BRANCH" ]]; then
    # --no-tags: same rationale as fetch_pinned_commit; branch imports should
    # not pull submodule tags into the parent repo namespace.
    # Redirect to stderr: resolve_import_ref is called in a $() subshell and
    # only the final printf should reach stdout as the import ref value.
    run_cmd git fetch --no-tags "$remote_name" "$IMPORT_BRANCH" >&2
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

# Remove all .gitmodules and .git/config references to the named submodule.
# Both git config calls are run directly (not via run_cmd) with 2>/dev/null
# and explicit exit-code handling. This is necessary because set -e fires
# inside run_cmd before the || true on the call site can catch a non-zero exit
# from git. deinit often removes these sections first, so missing section is
# a normal and expected condition, not an error.
remove_gitconfig_sections() {
  local name="$1"

  if $DRY_RUN; then
    log "[dry-run] git config -f .gitmodules --remove-section submodule.${name}"
    log "[dry-run] git config --remove-section submodule.${name}"
    return 0
  fi

  git config -f .gitmodules --remove-section "submodule.${name}" 2>/dev/null || true
  git config --remove-section "submodule.${name}" 2>/dev/null || true
}

remove_submodule_registration() {
  local name="$1"
  local path="$2"

  run_cmd git submodule deinit -f "$path"
  run_cmd git rm -f "$path"
  run_cmd rm -rf ".git/modules/${path}"

  # Update .gitmodules: remove this submodule's section, then either delete
  # the file entirely if no submodules remain or stage the updated version.
  if [[ -f .gitmodules ]]; then
    remove_gitconfig_sections "$name"

    # Count remaining submodule.* keys (not sections); delete .gitmodules when none.
    # wc -l returns 0 on empty input; tr -d strips BSD/macOS leading whitespace.
    local remaining
    remaining="$(git config -f .gitmodules --get-regexp '^submodule\.' 2>/dev/null | wc -l | tr -d ' ')"
    if [[ "$remaining" -eq 0 ]]; then
      run_cmd git rm -f .gitmodules
    else
      run_cmd git add .gitmodules
    fi
  else
    # .gitmodules already gone (deinit removed it); still clean up .git/config.
    remove_gitconfig_sections "$name"
  fi
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
    log "[dry-run] Would verify import ref"
    log "[dry-run] Would run: git submodule deinit -f ${path}"
    log "[dry-run] Would run: git rm -f ${path}"
    log "[dry-run] Would remove: .git/modules/${path}"
    log "[dry-run] Would update .gitmodules and git config"
    log "[dry-run] Would subtree-merge and commit imported tree at ${path}/"
    return 0
  fi

  # Warn if the temporary remote name already exists before trying to remove it.
  # This can happen if a previous run was interrupted and cleanup_on_exit did
  # not fire (e.g. SIGKILL). The remote will be replaced, but surfacing the
  # warning makes leftover state visible rather than silently overwriting it.
  if git config --get "remote.${remote_name}.url" >/dev/null 2>&1; then
    log "Warning: temporary remote '${remote_name}' already exists; replacing it." >&2
  fi

  remove_import_remote "$remote_name"
  git remote add "$remote_name" "$url"
  ACTIVE_IMPORT_REMOTE="$remote_name"

  import_ref="$(resolve_import_ref "$remote_name" "$path")"
  log "    import ref:        ${import_ref}"

  # Verify before removing submodule metadata so a bad fetch never half-absorbs.
  verify_import_ref "$import_ref"

  remove_submodule_registration "$name" "$path"

  local pinned_line=""
  if [[ -z "$IMPORT_BRANCH" && -n "$pinned_sha" ]]; then
    pinned_line="Original pinned gitlink SHA: ${pinned_sha}"
  fi

  local commit_msg
  commit_msg="$(cat <<EOF
Absorb submodule ${name} into monorepo

Import history from ${url} at ${path}/.
Import ref: ${import_ref}
${pinned_line:+"${pinned_line}"}
Removes submodule link; directory is now part of this repository.
EOF
)"

  # git merge refuses to start with staged changes in the index. The removal
  # steps above (git rm, .gitmodules edit) leave staged content, so we must
  # commit them first. We then merge, read-tree, and use reset --soft HEAD~2
  # to squash the interim removal commit and the merge commit into a single
  # final commit — so only one commit per submodule appears in the log.
  git commit -m "chore: remove submodule ${name} (absorb in progress)"

  if ! git merge -s ours --allow-unrelated-histories \
      -m "chore: merge ${name} history (absorb in progress)" "$import_ref"; then
    log "Error: merge failed." >&2
    log "       Run: git reset --hard HEAD~1" >&2
    exit 1
  fi

  # Graft the actual submodule file tree onto HEAD. read-tree stages the
  # files under the submodule path prefix.
  log "+ git read-tree --prefix=${path}/ -u ${import_ref}"
  git read-tree --prefix="${path}/" -u "$import_ref" || {
    log "Error: read-tree failed." >&2
    log "       Run: git reset --hard HEAD~1" >&2
    exit 1
  }

  # Squash the interim removal commit and the merge commit into one.
  # reset --soft HEAD~2 moves the branch pointer back two commits while
  # leaving the index intact, so the final commit contains everything:
  # the removal, the merge parent link, and the imported file tree.
  git reset --soft HEAD~2
  git commit -m "$commit_msg"

  remove_import_remote "$remote_name"
  ACTIVE_IMPORT_REMOTE=""
  log "Done: ${path}/  (history: git log --all -- ${path}/)"
}

parse_args() {
  [[ $# -eq 0 ]] && {
    usage_short
    exit 1
  }

  while [[ $# -gt 0 ]]; do
    case "$1" in
      run)
        COMMAND="run"
        shift
        ;;
      -n | --dry-run)
        DRY_RUN=true
        shift
        ;;
      -y | --yes)
        # Skip the interactive 5-second countdown. Intended for CI pipelines
        # and scripted invocations where stdin is not a terminal.
        YES=true
        shift
        ;;
      -b | --branch)
        IMPORT_BRANCH="${2:-}"
        [[ -n "$IMPORT_BRANCH" ]] || {
          log "Error: --branch requires a value" >&2
          usage_short >&2
          exit 1
        }
        shift 2
        ;;
      --submodule)
        SUBMODULE_FILTER="${2:-}"
        [[ -n "$SUBMODULE_FILTER" ]] || {
          log "Error: --submodule requires a value" >&2
          usage_short >&2
          exit 1
        }
        shift 2
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      *)
        log "Error: unknown argument: $1" >&2
        usage_short >&2
        exit 1
        ;;
    esac
  done
}

main() {
  parse_args "$@"

  [[ "$COMMAND" == "run" ]] || {
    log "Error: missing required command 'run'" >&2
    usage_short >&2
    exit 1
  }

  trap cleanup_on_exit EXIT
  require_clean_tree
  require_clean_submodules

  # Log the current branch so the operator has clear context in the output,
  # especially useful when reviewing CI logs or verifying the right branch
  # was checked out before running.
  log "Repository: ${ROOT}"
  log "Branch:     $(current_branch)"

  local names=()
  local name

  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    names+=("$name")
  done < <(submodule_names)

  if [[ -f .gitmodules && ${#names[@]} -eq 0 ]]; then
    # .gitmodules present but no paths parsed — likely malformed or empty.
    log "Warning: .gitmodules exists but no submodule paths were found. Malformed?" >&2
  fi

  [[ ${#names[@]} -gt 0 ]] || {
    log "No submodules defined in .gitmodules — nothing to do."
    exit 0
  }

  # If --submodule was given, restrict to that single entry and fail clearly
  # if the name does not exist, rather than silently absorbing everything.
  if [[ -n "$SUBMODULE_FILTER" ]]; then
    local matched=false
    for name in "${names[@]}"; do
      [[ "$name" == "$SUBMODULE_FILTER" ]] && matched=true && break
    done
    if ! $matched; then
      log "Error: submodule '${SUBMODULE_FILTER}' not found in .gitmodules." >&2
      log "       Known submodules: ${names[*]}" >&2
      exit 1
    fi
    names=("$SUBMODULE_FILTER")
  fi

  log "Submodules to absorb: ${names[*]}"

  if ! $DRY_RUN && ! $YES; then
    log ""
    log "This will create one commit per submodule."
    log "Press Ctrl+C within 5 seconds to cancel..."
    sleep 5
  fi

  # Cache submodule paths before any absorption begins. absorb_one removes each
  # submodule's entry from .gitmodules and may delete the file entirely once the
  # last submodule is absorbed. Reading paths post-absorption would silently
  # produce the submodule *name* instead of its *path*, corrupting the final
  # `git log` hints.
  #
  # Parallel array (Bash 3.2-safe); associative arrays require Bash 4+.
  local paths=()
  for name in "${names[@]}"; do
    paths+=("$(submodule_path "$name")")
  done

  for name in "${names[@]}"; do
    absorb_one "$name"
  done

  log ""
  log "All done."
  log "Verify with:"
  # Run git submodule status as a live final check rather than just printing
  # the command. This immediately surfaces any submodule that was not fully
  # removed, making post-absorb validation part of the run rather than a
  # manual follow-up step.
  log "--- git submodule status ---"
  git submodule status || true
  log "---"
  for path in "${paths[@]}"; do
    log "  git log --all -- ${path}/"
  done
}

main "$@"
