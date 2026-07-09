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

EMPTY_TREE_SHA="4b825dc642cb6eb9a060e54bf8d69288fbee4904"

if [ "$BASE_SHA" = "0000000000000000000000000000000000000000" ]; then
  BASE_SHA="$EMPTY_TREE_SHA"  # git empty-tree SHA
fi

# What counts as "changed by this PR/push" needs two conditions, because a single
# git diff misfires on the two ways a branch accumulates commits it didn't author:
#
#   1. Base branch advanced after the branch was cut (long-lived / stacked PRs):
#      a two-dot `git diff BASE_TIP HEAD` reports files that landed on the base
#      *after* the branch point. Fix: diff against merge-base(BASE, HEAD) so only
#      the branch's own commits count (equivalent to `git diff BASE...HEAD`).
#
#   2. A messy rebase pulls master commits onto the branch with rewritten SHAs.
#      Those are unreachable from the real base tip, so merge-base *cannot*
#      exclude them — they look like the branch's own commits. But their content
#      matches what's already on the base, so they do not diverge from BASE_TIP.
#      Fix: also require the file to differ from the base-branch tip.
#
# So a file is "changed" iff it appears in BOTH merge-base..HEAD (the branch's own
# commits) AND BASE_TIP..HEAD (real divergence from the base). Intersecting the
# two neutralizes both base-advance and rebase-duplicate noise, which otherwise
# create draft versions on many agents the PR never touched.
DIFF_BASE="$BASE_SHA"
if [ "$BASE_SHA" != "$EMPTY_TREE_SHA" ]; then
  MERGE_BASE="$(git merge-base "$BASE_SHA" HEAD 2>/dev/null || true)"
  if [ -z "$MERGE_BASE" ]; then
    # Shallow checkout/fetch: deepen progressively (bounded) until the branch
    # point is present in local history, then recompute the merge-base.
    HEAD_SHA="$(git rev-parse HEAD)"
    for depth in 100 500 2000; do
      git fetch -q --deepen="$depth" origin "$BASE_SHA" "$HEAD_SHA" 2>/dev/null || true
      MERGE_BASE="$(git merge-base "$BASE_SHA" HEAD 2>/dev/null || true)"
      [ -n "$MERGE_BASE" ] && break
    done
  fi
  if [ -n "$MERGE_BASE" ]; then
    DIFF_BASE="$MERGE_BASE"
  else
    echo "WARN: no merge-base for ${BASE_SHA}..HEAD (shallow or unrelated history); diffing against base tip, which may over-report cross-branch changes."
  fi
fi

# Changed files under a path, comparing a given base against HEAD.
changed_files_under() {
  git diff --name-only --diff-filter=ACMRD "$1" HEAD -- "$2/" 2>/dev/null || true
}

# Files this PR/push actually changed under a path: the intersection of the
# branch's own commits (DIFF_BASE = merge-base) and real divergence from the base
# tip (BASE_SHA) — see the two-condition rationale above. When DIFF_BASE ==
# BASE_SHA (empty-tree base, or a push whose `before` is HEAD's ancestor) the
# intersection is a no-op, so push/dispatch behavior is unchanged.
changed_files_for_scope() {
  local path="$1" own tip
  own="$(changed_files_under "$DIFF_BASE" "$path")"
  if [ "$DIFF_BASE" = "$BASE_SHA" ]; then
    printf '%s' "$own"
    return
  fi
  tip="$(changed_files_under "$BASE_SHA" "$path")"
  comm -12 <(printf '%s\n' "$own" | sed '/^$/d' | sort -u) \
           <(printf '%s\n' "$tip" | sed '/^$/d' | sort -u)
}

# ── Detect direct agent-root changes ────────────────────────────────────────

CHANGED_FILES=$(changed_files_for_scope "$AGENT_DIR")

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
  SHARED_CHANGED_FILES=$(changed_files_for_scope "$SHARED_ROOT")

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
