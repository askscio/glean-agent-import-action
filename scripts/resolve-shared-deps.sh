#!/usr/bin/env bash
set -euo pipefail

# Resolves which agents are affected by changes under SHARED_ROOT.
#
# Required env:
#   AGENT_DIR       — repo-relative path to the agents root (e.g. .glean/agents)
#   SHARED_ROOT     — repo-relative path to the shared resources root (e.g. .glean/common)
#   WORKSPACE_ROOT  — absolute path to the repo root (usually GITHUB_WORKSPACE)
#
# Input (stdin): newline-separated list of changed files under SHARED_ROOT (repo-relative)
# Output (stdout): JSON array of agent folder names affected by shared-root changes
#
# Exit codes:
#   0 — success (may output empty array [])
#   1 — fatal validation error (e.g. roots overlap, symlink escapes repo)

# ── Validate and normalize roots ────────────────────────────────────────────

validate_roots() {
  local ws="$1"
  local agent_abs="$2"
  local shared_abs="$3"

  # Both roots must be inside the workspace
  case "$agent_abs" in
    "$ws"/*) ;;
    *)
      echo "::error::agents_root resolves outside the repo workspace: $agent_abs" >&2
      return 1
      ;;
  esac

  case "$shared_abs" in
    "$ws"/*) ;;
    *)
      echo "::error::shared_root resolves outside the repo workspace: $shared_abs" >&2
      return 1
      ;;
  esac

  # Reject overlap: neither root may be a prefix of the other
  case "$shared_abs/" in
    "$agent_abs/"*)
      echo "::error::shared_root ($shared_abs) is nested inside agents_root ($agent_abs)" >&2
      return 1
      ;;
  esac
  case "$agent_abs/" in
    "$shared_abs/"*)
      echo "::error::agents_root ($agent_abs) is nested inside shared_root ($shared_abs)" >&2
      return 1
      ;;
  esac
}

# ── Discover symlink dependencies for all agents ────────────────────────────

# Builds an associative-array-style output: prints lines of
#   AGENT_FOLDER_NAME<TAB>RESOLVED_TARGET
# for every symlink in each agent subtree that resolves into shared_root.
discover_agent_symlinks() {
  local ws="$1"
  local agent_abs="$2"
  local shared_abs="$3"
  local has_broken_affected=false

  if [ ! -d "$agent_abs" ]; then
    echo "::warning::agents_root does not exist: $agent_abs" >&2
    return 0
  fi

  for agent_dir in "$agent_abs"/*/; do
    [ -d "$agent_dir" ] || continue
    local agent_name
    agent_name=$(basename "$agent_dir")

    # Find all symlinks in this agent's subtree
    while IFS= read -r -d '' symlink; do
      local target
      # Try to resolve the symlink canonically
      if ! target=$(realpath "$symlink" 2>/dev/null); then
        echo "::warning::Broken symlink in agent '$agent_name': $symlink" >&2
        continue
      fi

      # Reject symlinks that escape the repo
      case "$target" in
        "$ws"/*)
          ;;
        *)
          echo "::error::Symlink escapes repo workspace in agent '$agent_name': $symlink -> $target" >&2
          return 1
          ;;
      esac

      # Check if the resolved target is inside shared_root
      case "$target" in
        "$shared_abs"/*)
          printf '%s\t%s\n' "$agent_name" "$target"
          ;;
        "$shared_abs")
          printf '%s\t%s\n' "$agent_name" "$target"
          ;;
      esac
    done < <(find "$agent_dir" -type l -print0 2>/dev/null)
  done
}

# ── Compute affected agents from changed shared paths ───────────────────────

# Takes: dependency map on stdin (AGENT<TAB>TARGET lines), changed shared paths as args
# Outputs: unique agent names, one per line
compute_affected_agents() {
  local shared_abs="$1"
  shift
  local -a changed_paths=("$@")
  local -A affected=()

  # Read all dependency entries into arrays
  local -a dep_agents=()
  local -a dep_targets=()
  while IFS=$'\t' read -r agent target; do
    dep_agents+=("$agent")
    dep_targets+=("$target")
  done

  for changed in "${changed_paths[@]}"; do
    local changed_canonical
    # Resolve changed path to canonical absolute
    if [ -e "$changed" ]; then
      changed_canonical=$(realpath "$changed")
    else
      # File may have been deleted; normalize the path manually
      changed_canonical=$(cd "$shared_abs" 2>/dev/null && realpath -m "$changed" 2>/dev/null || echo "$changed")
    fi

    for i in "${!dep_agents[@]}"; do
      local agent="${dep_agents[$i]}"
      local target="${dep_targets[$i]}"

      # Already affected, skip
      [ "${affected[$agent]+set}" = "set" ] && continue

      # Exact match
      if [ "$target" = "$changed_canonical" ]; then
        affected[$agent]=1
        echo "  Shared-root dependency: agent '$agent' affected by change to '$changed' (exact match)" >&2
        continue
      fi

      # Descendant match: changed path is under the symlink target directory
      case "$changed_canonical" in
        "$target"/*)
          affected[$agent]=1
          echo "  Shared-root dependency: agent '$agent' affected by change under '$target'" >&2
          continue
          ;;
      esac

      # Ancestor match: symlink target is under the changed directory
      case "$target" in
        "$changed_canonical"/*)
          affected[$agent]=1
          echo "  Shared-root dependency: agent '$agent' affected (target '$target' is under changed dir '$changed_canonical')" >&2
          continue
          ;;
      esac
    done
  done

  # Output unique agent names
  for agent in "${!affected[@]}"; do
    echo "$agent"
  done | sort -u
}

# ── Main ────────────────────────────────────────────────────────────────────

main() {
  local ws="${WORKSPACE_ROOT:-.}"
  ws=$(realpath "$ws")

  local agent_dir="${AGENT_DIR:-.glean/agents}"
  local shared_root="${SHARED_ROOT:-.glean/common}"

  # Strip trailing slashes for consistency
  agent_dir="${agent_dir%/}"
  shared_root="${shared_root%/}"

  local agent_abs shared_abs
  agent_abs=$(realpath -m "${ws}/${agent_dir}")
  shared_abs=$(realpath -m "${ws}/${shared_root}")

  validate_roots "$ws" "$agent_abs" "$shared_abs"

  # Read changed shared paths from stdin
  local -a changed_shared_files=()
  while IFS= read -r line || [ -n "$line" ]; do
    [ -z "$line" ] && continue
    changed_shared_files+=("${ws}/${line}")
  done

  if [ ${#changed_shared_files[@]} -eq 0 ]; then
    echo "[]"
    return 0
  fi

  echo "Shared-root changes detected (${#changed_shared_files[@]} files). Scanning agent symlink dependencies..." >&2

  # Discover all symlink dependencies
  local dep_map
  dep_map=$(discover_agent_symlinks "$ws" "$agent_abs" "$shared_abs")

  if [ -z "$dep_map" ]; then
    echo "No agent symlinks resolve into shared_root — no downstream agents affected." >&2
    echo "[]"
    return 0
  fi

  echo "Symlink dependency map:" >&2
  echo "$dep_map" | while IFS=$'\t' read -r a t; do
    echo "  $a -> $t" >&2
  done

  # Compute affected agents
  local affected
  affected=$(echo "$dep_map" | compute_affected_agents "$shared_abs" "${changed_shared_files[@]}")

  if [ -z "$affected" ]; then
    echo "Shared paths changed but no downstream agents depend on them." >&2
    echo "[]"
    return 0
  fi

  echo "Affected agents from shared-root changes:" >&2
  echo "$affected" | while IFS= read -r a; do
    echo "  - $a" >&2
  done

  # Output as JSON array
  echo "$affected" | jq -R -s -c 'split("\n") | map(select(length > 0))'
}

# Allow sourcing for testing without executing main
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main
fi
