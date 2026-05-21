#!/usr/bin/env bash
set -euo pipefail

# Required env: AGENT_DIR, EVENT_NAME, PR_BASE_SHA, PUSH_BEFORE_SHA
# Optional env: PR_TITLE, SPECIFIC_AGENT_FOLDER

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=github_output.sh
source "${_script_dir}/github_output.sh"
unset _script_dir

# If a specific folder is provided, skip diff detection entirely.
if [ -n "${SPECIFIC_AGENT_FOLDER:-}" ]; then
  ACTUAL_SHA=$(git rev-parse HEAD)
  FOLDERS=$(echo "$SPECIFIC_AGENT_FOLDER" | jq -R -c '[.]')
  github_output_heredoc "folders" "$FOLDERS"
  echo "event=$EVENT_NAME" >> "$GITHUB_OUTPUT"
  echo "commit_sha=$ACTUAL_SHA" >> "$GITHUB_OUTPUT"
  DEFAULT_MSG=$(git log -1 --format='%s' "$ACTUAL_SHA")
  github_output_heredoc "default_message" "$DEFAULT_MSG"
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

CHANGED_FILES=$(git diff --name-only --diff-filter=ACMRD "$BASE_SHA" HEAD -- "$AGENT_DIR/")
if [ -z "$CHANGED_FILES" ]; then
  echo "No agent spec folders changed — nothing to sync."
  github_output_heredoc "folders" "[]"
  exit 0
fi

# Bash prefix strip (not sed): sed BRE treats \\( as group; literal parens and other
# metacharacters in AGENT_DIR would not match reliably.
# Top-level files directly under AGENT_DIR (no subfolder) are intentionally ignored:
# every agent must live in its own folder, so a bare file is not an agent and must
# not be treated as one (otherwise it would later be reported as a "deleted agent").
FOLDERS=$(
  printf '%s\n' "$CHANGED_FILES" | while IFS= read -r line || [ -n "$line" ]; do
    [ -z "$line" ] && continue
    if [[ "$line" == "${AGENT_DIR}/"* ]]; then
      rel="${line#"${AGENT_DIR}/"}"
      [[ "$rel" == */* ]] || continue
      printf '%s\n' "${rel%%/*}"
    fi
  done | sort -u | jq -R -s -c 'split("\n") | map(select(length > 0))'
)

if [ "$FOLDERS" = "[]" ]; then
  echo "Only top-level files in ${AGENT_DIR} changed — nothing to sync."
  github_output_heredoc "folders" "[]"
  exit 0
fi

ACTUAL_SHA=$(git rev-parse HEAD)
github_output_heredoc "folders" "$FOLDERS"
echo "event=$EVENT_NAME" >> "$GITHUB_OUTPUT"
echo "commit_sha=$ACTUAL_SHA" >> "$GITHUB_OUTPUT"

# Derive a default commit message from PR title or git commit subject
if [ "$EVENT_NAME" = "pull_request" ] && [ -n "${PR_TITLE:-}" ]; then
  github_output_heredoc "default_message" "$PR_TITLE"
else
  DEFAULT_MSG=$(git log -1 --format='%s' "$ACTUAL_SHA")
  github_output_heredoc "default_message" "$DEFAULT_MSG"
fi

echo "Changed agent folders: $FOLDERS"
