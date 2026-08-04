#!/usr/bin/env bash
set -euo pipefail

# Required env: GH_TOKEN, INSTANCE_URL_FE, INSTANCE_URL_BE, PR_NUMBER, REPO
# Optional env: SYNC_WORKFLOW_FILE (enables the Retry button link to the workflow page)

INSTANCE_URL_FE="${INSTANCE_URL_FE%/}"
INSTANCE_URL_BE="${INSTANCE_URL_BE%/}"
BE_ENCODED=$(printf %s "$INSTANCE_URL_BE" | jq -sRr @uri)
MARKER="<!-- glean-agent-sync-action -->"
RESULTS_FILE="$RUNNER_TEMP/agent-sync-results.json"

# Plain workflow-page link. GitHub ignores workflow_dispatch input prefills via
# URL query params, so we only link to the page; inputs are entered there or via
# the copyable /glean-retry command below.
RETRY_WORKFLOW_URL=""
if [ -n "${SYNC_WORKFLOW_FILE:-}" ]; then
  RETRY_WORKFLOW_URL="https://github.com/${REPO}/actions/workflows/${SYNC_WORKFLOW_FILE}"
fi

if [ ! -f "$RESULTS_FILE" ]; then
  echo "::warning::No sync results file found — sync step may have crashed before writing results."
  exit 0
fi

HAS_FAILURES=false
TABLE_ROWS=""
RETRY_COMMANDS=""

while IFS= read -r ROW; do
  AID=$(echo "$ROW" | jq -r '.agentId')
  ANAME=$(echo "$ROW" | jq -r '.agentName // .agentId')
  FOLDER=$(echo "$ROW" | jq -r '.folder // .agentId')
  STATUS=$(echo "$ROW" | jq -r '.status')

  if [ "$STATUS" = "success" ]; then
    STATUS_TEXT=":white_check_mark: Draft Preview"
    # Fall back to the real agent when no transient id came back — never to /edit, its durable draft.
    PID=$(echo "$ROW" | jq -r '.previewId // ""')
    [ -z "$PID" ] && PID="$AID"
    PREVIEW="[Preview in Glean](${INSTANCE_URL_FE}/chat/agents/${PID}/preview?qe=${BE_ENCODED})"
    RETRY="—"
  else
    HAS_FAILURES=true
    STATUS_TEXT=":x: Draft Preview"
    ERR=$(echo "$ROW" | jq -r '.error // "Failed"')
    PREVIEW="$ERR"
    if [ -n "$RETRY_WORKFLOW_URL" ]; then
      RETRY="[**Retry** ↗](${RETRY_WORKFLOW_URL})"
    else
      RETRY="\`/glean-retry ${FOLDER}\`"
    fi
    RETRY_COMMANDS+="/glean-retry ${FOLDER}"$'\n'
  fi

  TABLE_ROWS+="| \`${ANAME}\` | ${STATUS_TEXT} | ${PREVIEW} | ${RETRY} |"$'\n'
done < <(jq -c '.[]' "$RESULTS_FILE")

{
  echo "${MARKER}"
  echo "## Glean Agent Sync — Draft Preview"
  echo ""
  echo "| Agent | Status | Preview | Retry |"
  echo "|-------|--------|---------|-------|"
  echo -n "$TABLE_ROWS"
  echo ""
  if [ "$HAS_FAILURES" = "true" ]; then
    echo "### Retry a failed agent"
    echo ""
    if [ -n "$RETRY_WORKFLOW_URL" ]; then
      echo "Click the **Retry** button above to open the [Glean Agent Sync workflow](${RETRY_WORKFLOW_URL}), then **Run workflow** with the agent folder and PR number."
      echo ""
      echo "Or, for a one-click retry, post one of these as a **new comment** on this PR (use the copy button on the code block):"
    else
      echo "Post one of these as a **new comment** on this PR (use the copy button on the code block):"
    fi
    echo ""
    while IFS= read -r CMD; do
      [ -z "$CMD" ] && continue
      echo "\`\`\`"
      echo "$CMD"
      echo "\`\`\`"
    done <<< "$RETRY_COMMANDS"
    echo ""
    echo "[Open PR conversation ↗](https://github.com/${REPO}/pull/${PR_NUMBER})"
    echo ""
  fi
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
