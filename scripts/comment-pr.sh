#!/usr/bin/env bash
set -euo pipefail

# Required env: GH_TOKEN, INSTANCE_URL_FE, INSTANCE_URL_BE, PR_NUMBER, REPO

INSTANCE_URL_FE="${INSTANCE_URL_FE%/}"
INSTANCE_URL_BE="${INSTANCE_URL_BE%/}"
BE_ENCODED=$(printf %s "$INSTANCE_URL_BE" | jq -sRr @uri)
MARKER="<!-- glean-agent-sync-action -->"
RESULTS_FILE="$RUNNER_TEMP/agent-sync-results.json"

if [ ! -f "$RESULTS_FILE" ]; then
  echo "::warning::No sync results file found — sync step may have crashed before writing results."
  exit 0
fi

TABLE_ROWS=""
while IFS= read -r ROW; do
  AID=$(echo "$ROW" | jq -r '.agentId')
  ANAME=$(echo "$ROW" | jq -r '.agentName // .agentId')
  STATUS=$(echo "$ROW" | jq -r '.status')

  if [ "$STATUS" = "success" ]; then
    STATUS_TEXT=":white_check_mark: Draft Preview"
    PID=$(echo "$ROW" | jq -r '.previewId // ""')
    [ -z "$PID" ] && PID="$AID"
    LINK="[Preview in Glean](${INSTANCE_URL_FE}/chat/agents/${PID}/preview?qe=${BE_ENCODED})"
  else
    STATUS_TEXT=":x: Draft Preview"
    LINK=$(echo "$ROW" | jq -r '.error // "Failed"')
  fi

  TABLE_ROWS+="| \`${ANAME}\` | ${STATUS_TEXT} | ${LINK} |"$'\n'
done < <(jq -c '.[]' "$RESULTS_FILE")

{
  echo "${MARKER}"
  echo "## Glean Agent Sync — Draft Preview"
  echo ""
  echo "| Agent | Status | Preview |"
  echo "|-------|--------|---------|"
  echo -n "$TABLE_ROWS"
  echo ""
  echo "*Updated by glean-io/agent-sync-action*"
} > "$RUNNER_TEMP/agent-sync-comment.md"

EXISTING_COMMENT_ID=$(gh api "repos/${REPO}/issues/${PR_NUMBER}/comments" --paginate \
  --jq ".[] | select(.body | contains(\"${MARKER}\")) | .id" | head -1)

if [ -n "$EXISTING_COMMENT_ID" ]; then
  gh api "repos/${REPO}/issues/comments/${EXISTING_COMMENT_ID}" \
    -X PATCH -F body=@"$RUNNER_TEMP/agent-sync-comment.md"
else
  gh api "repos/${REPO}/issues/${PR_NUMBER}/comments" \
    -X POST -F body=@"$RUNNER_TEMP/agent-sync-comment.md"
fi
