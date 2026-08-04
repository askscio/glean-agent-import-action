#!/usr/bin/env bash
set -euo pipefail

# Required env: GH_TOKEN, INSTANCE_URL_FE, COMMIT_SHA, REPO

INSTANCE_URL_FE="${INSTANCE_URL_FE%/}"
MARKER="<!-- glean-agent-sync-action-run -->"
RESULTS_FILE="$RUNNER_TEMP/agent-sync-results.json"

if [ ! -f "$RESULTS_FILE" ]; then
  echo "::warning::No sync results file found — sync step may have crashed before writing results."
  exit 0
fi

PR_NUMBER=$(gh api "repos/${REPO}/commits/${COMMIT_SHA}/pulls" \
  --jq '.[0].number // empty' 2>/dev/null || true)

if [ -z "$PR_NUMBER" ]; then
  echo "No PR found for commit ${COMMIT_SHA} — skipping run link comment."
  exit 0
fi

TABLE_ROWS=""
HAS_FAILURE=false
while IFS= read -r ROW; do
  ANAME=$(echo "$ROW" | jq -r '.agentName // .agentId')
  AID=$(echo "$ROW" | jq -r '.agentId')
  STATUS=$(echo "$ROW" | jq -r '.status')
  SYNC_MODE=$(echo "$ROW" | jq -r '.mode // empty')

  if [ "$STATUS" = "success" ]; then
    LINK="[Run in Glean](${INSTANCE_URL_FE}/chat/agents/${AID})"
    if [ "$SYNC_MODE" = "published" ]; then
      STATUS_TEXT=":rocket: Published"
    elif [ "$SYNC_MODE" = "draft_preview" ]; then
      STATUS_TEXT=":pencil: Preview"
      LINK="[Preview in Glean](${INSTANCE_URL_FE}/chat/agents/$(echo "$ROW" | jq -r '.previewId')/preview)"
    else
      STATUS_TEXT=":white_check_mark: Staged"
    fi
  else
    HAS_FAILURE=true
    STATUS_TEXT=":x: Sync failed"
    LINK=$(echo "$ROW" | jq -r '.error // "Failed"')
  fi

  TABLE_ROWS+="| \`${ANAME}\` | ${STATUS_TEXT} | ${LINK} |"$'\n'
done < <(jq -c '.[]' "$RESULTS_FILE")

if [ "$HAS_FAILURE" = "true" ]; then
  HEADING="## Glean Agent Sync — Completed with errors"
else
  HEADING="## Glean Agent Sync — Sync complete"
fi

{
  echo "${MARKER}"
  echo "${HEADING}"
  echo ""
  echo "| Agent | Status | Link |"
  echo "|-------|--------|------|"
  echo -n "$TABLE_ROWS"
  echo ""
  echo "*Updated by glean-io/agent-sync-action*"
} > "$RUNNER_TEMP/agent-sync-merge-comment.md"

EXISTING_COMMENT_ID=$(gh api "repos/${REPO}/issues/${PR_NUMBER}/comments" --paginate \
  --jq ".[] | select(.body | contains(\"${MARKER}\")) | .id" | head -1)

if [ -n "$EXISTING_COMMENT_ID" ]; then
  gh api "repos/${REPO}/issues/comments/${EXISTING_COMMENT_ID}" \
    -X PATCH -F body=@"$RUNNER_TEMP/agent-sync-merge-comment.md"
else
  gh api "repos/${REPO}/issues/${PR_NUMBER}/comments" \
    -X POST -F body=@"$RUNNER_TEMP/agent-sync-merge-comment.md"
fi
