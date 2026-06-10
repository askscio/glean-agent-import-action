#!/usr/bin/env bash
set -euo pipefail

# Required env: GH_TOKEN, INSTANCE_URL_FE, INSTANCE_URL_BE, PR_NUMBER, REPO
# Optional env: SYNC_WORKFLOW_FILE, PR_HEAD_REF (enables per-agent retry links)

INSTANCE_URL_FE="${INSTANCE_URL_FE%/}"
INSTANCE_URL_BE="${INSTANCE_URL_BE%/}"
BE_ENCODED=$(printf %s "$INSTANCE_URL_BE" | jq -sRr @uri)
MARKER="<!-- glean-agent-sync-action -->"
RESULTS_FILE="$RUNNER_TEMP/agent-sync-results.json"

build_retry_link() {
  local folder="$1"
  [ -n "${SYNC_WORKFLOW_FILE:-}" ] || return 0
  [ -n "${PR_NUMBER:-}" ] || return 0

  local query ref_param=""
  query=$(printf 'agent_folder=%s&is_draft=true&pr_number=%s' "$folder" "$PR_NUMBER" | jq -sRr @uri)
  if [ -n "${PR_HEAD_REF:-}" ]; then
    ref_param="ref=$(printf %s "$PR_HEAD_REF" | jq -sRr @uri)&"
  fi
  printf '[Retry](https://github.com/%s/actions/workflows/%s/dispatch?%squery=%s)' \
    "$REPO" "$SYNC_WORKFLOW_FILE" "$ref_param" "$query"
}

if [ ! -f "$RESULTS_FILE" ]; then
  echo "::warning::No sync results file found — sync step may have crashed before writing results."
  exit 0
fi

TABLE_ROWS=""
while IFS= read -r ROW; do
  AID=$(echo "$ROW" | jq -r '.agentId')
  ANAME=$(echo "$ROW" | jq -r '.agentName // .agentId')
  FOLDER=$(echo "$ROW" | jq -r '.folder // .agentId')
  STATUS=$(echo "$ROW" | jq -r '.status')

  if [ "$STATUS" = "success" ]; then
    STATUS_TEXT=":white_check_mark: Draft Preview"
    LINK="[Preview in Glean](${INSTANCE_URL_FE}/chat/agents/${AID}/edit?qe=${BE_ENCODED})"
  else
    STATUS_TEXT=":x: Draft Preview"
    ERR=$(echo "$ROW" | jq -r '.error // "Failed"')
    LINK="$ERR"
    RETRY=$(build_retry_link "$FOLDER")
    [ -n "$RETRY" ] && LINK="${LINK} · ${RETRY}"
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
