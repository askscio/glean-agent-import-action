#!/usr/bin/env bash
set -euo pipefail

# Required env: AGENT_DIR, EVENT_NAME, PR_BASE_SHA, PUSH_BEFORE_SHA
# Optional env: PR_TITLE, SPECIFIC_AGENT_FOLDER, SHARED_ROOT

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=github_output.sh
source "${_script_dir}/github_output.sh"

# If a specific folder is provided, skip diff detection entirely.
if [ -n "${SPECIFIC_AGENT_FOLDER:-}" ]; then
  ACTUAL_SHA=$(git rev-parse HEAD)
  FOLDERS=$(echo "$SPECIFIC_AGENT_FOLDER" | jq -R -c '[.]')
  github_output_heredoc "folders" "$FOLDERS"
  echo "event=$EVENT_NAME" >> "$GITHUB_OUTPUT"
  echo "commit_sha=$ACTUAL_SHA" >> "$GITHUB_OUTPUT"
  DEFAULT_MSG=$(git log -1 --format='%s' "$ACTUAL_SHA")
  github_output_heredoc "default_message" "$DEFAULT_MSG"
  github_output_heredoc "shared_root_affected" "[]"
  github_output_heredoc "shared_changed_files" "[]"
  echo "Syncing specific agent folder: $SPECIFIC_AGENT_FOLDER"
  exit 0
fi

if [ "$EVENT_NAME" = "pull_request" ]; then
  BASE_SHA="$PR_BASE_SHA"
elif [ "$EVENT_NAME" = "push" ]; then
  BASE_SHA="$PUSH_BEFORE_SHA"
else
  # workflow_dispatch or any other event: sync all agent folders
  BASE_SHA="4b825dc642cb6eb9a060e54bf8d69288fbee4904"  # git empty-tree SHA
fi

if [ "$BASE_SHA" = "0000000000000000000000000000000000000000" ]; then
  BASE_SHA="4b825dc642cb6eb9a060e54bf8d69288fbee4904"  # git empty-tree SHA
fi

# ── Detect direct agent-root changes ────────────────────────────────────────

CHANGED_FILES=$(git diff --name-only --diff-filter=ACMRD "$BASE_SHA" HEAD -- "$AGENT_DIR/")

DIRECT_FOLDERS="[]"
if [ -n "$CHANGED_FILES" ]; then
  # Bash prefix strip (not sed): sed BRE treats \\( as group; literal parens and other
  # metacharacters in AGENT_DIR would not match reliably.
  # Top-level files directly under AGENT_DIR (no subfolder) are intentionally ignored:
  # every agent must live in its own folder, so a bare file is not an agent and must
  # not be treated as one (otherwise it would later be reported as a "deleted agent").
  DIRECT_FOLDERS=$(
    printf '%s\n' "$CHANGED_FILES" | while IFS= read -r line || [ -n "$line" ]; do
      [ -z "$line" ] && continue
      if [[ "$line" == "${AGENT_DIR}/"* ]]; then
        rel="${line#"${AGENT_DIR}/"}"
        [[ "$rel" == */* ]] || continue
        printf '%s\n' "${rel%%/*}"
      fi
    done | sort -u | jq -R -s -c 'split("\n") | map(select(length > 0))'
  )
fi

# ── Detect shared-root changes and resolve downstream agents ────────────────

SHARED_ROOT="${SHARED_ROOT:-.glean/common}"
SHARED_ROOT="${SHARED_ROOT%/}"

SHARED_AFFECTED="[]"
SHARED_CHANGED_JSON="[]"

if [ -n "$SHARED_ROOT" ] && [ "$SHARED_ROOT" != "" ]; then
  SHARED_CHANGED_FILES=$(git diff --name-only --diff-filter=ACMRD "$BASE_SHA" HEAD -- "$SHARED_ROOT/" 2>/dev/null || true)

  if [ -n "$SHARED_CHANGED_FILES" ]; then
    SHARED_CHANGED_JSON=$(printf '%s\n' "$SHARED_CHANGED_FILES" | jq -R -s -c 'split("\n") | map(select(length > 0))')
    echo "Shared-root files changed: $SHARED_CHANGED_JSON"

    WORKSPACE_ROOT="${GITHUB_WORKSPACE:-$(git rev-parse --show-toplevel)}"
    export WORKSPACE_ROOT AGENT_DIR SHARED_ROOT

    SHARED_AFFECTED=$(printf '%s\n' "$SHARED_CHANGED_FILES" | "${_script_dir}/resolve-shared-deps.sh")
    echo "Agents affected by shared-root changes: $SHARED_AFFECTED"
  fi
fi

# ── Union and deduplicate direct + shared-root-triggered agents ─────────────

FOLDERS=$(echo "$DIRECT_FOLDERS" "$SHARED_AFFECTED" | jq -s -c 'add | unique')

if [ "$FOLDERS" = "[]" ] || [ "$FOLDERS" = "null" ]; then
  if [ -n "$CHANGED_FILES" ] || [ "$SHARED_CHANGED_JSON" != "[]" ]; then
    echo "Only top-level files changed or shared changes had no dependents — nothing to sync."
  else
    echo "No agent spec folders changed — nothing to sync."
  fi
  github_output_heredoc "folders" "[]"
  github_output_heredoc "shared_root_affected" "[]"
  github_output_heredoc "shared_changed_files" "$SHARED_CHANGED_JSON"
  exit 0
fi

ACTUAL_SHA=$(git rev-parse HEAD)
github_output_heredoc "folders" "$FOLDERS"
echo "event=$EVENT_NAME" >> "$GITHUB_OUTPUT"
echo "commit_sha=$ACTUAL_SHA" >> "$GITHUB_OUTPUT"
github_output_heredoc "shared_root_affected" "$SHARED_AFFECTED"
github_output_heredoc "shared_changed_files" "$SHARED_CHANGED_JSON"

# Derive a default commit message from PR title or git commit subject
if [ "$EVENT_NAME" = "pull_request" ] && [ -n "${PR_TITLE:-}" ]; then
  github_output_heredoc "default_message" "$PR_TITLE"
else
  DEFAULT_MSG=$(git log -1 --format='%s' "$ACTUAL_SHA")
  github_output_heredoc "default_message" "$DEFAULT_MSG"
fi

# Log summary
DIRECT_COUNT=$(echo "$DIRECT_FOLDERS" | jq 'length')
SHARED_COUNT=$(echo "$SHARED_AFFECTED" | jq 'length')
TOTAL_COUNT=$(echo "$FOLDERS" | jq 'length')
echo "Changed agent folders: $FOLDERS"
echo "  Direct changes: $DIRECT_COUNT agent(s)"
echo "  Shared-root induced: $SHARED_COUNT agent(s)"
echo "  Total (deduplicated): $TOTAL_COUNT agent(s)"

unset _script_dir
