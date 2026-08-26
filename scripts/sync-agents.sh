#!/usr/bin/env bash
set -euo pipefail

# Required env: API_TOKEN, AGENT_DIR, EVENT_NAME, COMMIT_SHA, INSTANCE_URL_BE, FOLDERS_JSON
# Optional env: DEFAULT_MESSAGE, DEFAULT_SYNC_MODE, FORCE_DRAFT, PR_AUTHOR, PR_RETRY

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=github_output.sh
source "${script_dir}/github_output.sh"

INSTANCE_URL_BE="${INSTANCE_URL_BE%/}"
RESULTS="[]"
HAS_FAILURE=false

append_result() {
  local filter="$1"
  shift
  RESULTS=$(echo "$RESULTS" | jq -c "$@" "$filter" | jq -c --arg folder "$FOLDER" '.[-1] |= . + {folder: $folder}')
}

package_agent_bundle() {
  local folder_path="$1" bundle_file="$2" materialized bundle_root repo_root target resolved
  command -v zip >/dev/null 2>&1 || {
    echo "::error::The zip utility is required to import agent folders; install zip on the runner."
    return 1
  }

  repo_root="$(git -C "$folder_path" rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$repo_root" ] || {
    echo "::error::Unable to determine the checked-out repository boundary for ${folder_path}."
    return 1
  }
  materialized="$(mktemp -d "${RUNNER_TEMP}/agent-bundle.XXXXXX")"
  BUNDLE_MATERIALIZED_DIRS+=("$materialized")
  bundle_root="$materialized/$(basename "$folder_path")"
  mkdir -p "$bundle_root"

  while IFS= read -r -d '' target; do
    resolved="$(realpath "$target")"
    case "$resolved" in
      "$repo_root"|"$repo_root"/*) ;;
      *)
        echo "::error::Agent ${FOLDER} contains symlink ${target#"$repo_root"/} resolving outside the checked-out repository."
        return 1
        ;;
    esac
  done < <(find "$folder_path" -type l -print0)

  cp -aL "$folder_path"/. "$bundle_root"/
  rm -f "$bundle_root/glean-sync.yaml"
  (
    cd "$materialized"
    zip -q -r "$bundle_file" .
  )
}

cleanup_bundles() {
  local dir
  for dir in "${BUNDLE_MATERIALIZED_DIRS[@]:-}"; do
    [ -n "$dir" ] && rm -rf "$dir"
  done
}

BUNDLE_MATERIALIZED_DIRS=()
trap cleanup_bundles EXIT

while IFS= read -r FOLDER; do
  FOLDER_PATH="${AGENT_DIR}/${FOLDER}"
  AGENT_DISPLAY_NAME="$FOLDER"
  RESPONSE_FILE="${RUNNER_TEMP}/sync-response-${FOLDER}.json"
  CURL_ERR_FILE="${RUNNER_TEMP}/sync-curl-error-${FOLDER}.txt"
  BUNDLE_FILE="${RUNNER_TEMP}/agent-${FOLDER}.zip"

  if [ ! -d "$FOLDER_PATH" ]; then
    echo "::error::Agent folder ${FOLDER_PATH} was deleted but cannot be auto-retired. Switch the agent back to UI-managed mode in Agent Builder before removing the folder."
    append_result '. + [{"agentId": $aid, "agentName": $name, "agentMode": "unknown", "mode": "deleted", "status": "error", "error": "folder deleted — switch to UI-managed mode to retire"}]' --arg aid "$FOLDER" --arg name "$AGENT_DISPLAY_NAME"
    HAS_FAILURE=true
    continue
  fi

  AGENT_MODE="automode"
  if [ ! -f "${FOLDER_PATH}/spec.yaml" ]; then
    echo "::error::Missing spec.yaml in ${FOLDER_PATH} — every agent folder must contain a spec.yaml."
    append_result '. + [{"agentId": $aid, "agentName": $name, "agentMode": "unknown", "mode": "unknown", "status": "error", "error": "no spec.yaml found — add one"}]' --arg aid "$FOLDER" --arg name "$AGENT_DISPLAY_NAME"
    HAS_FAILURE=true
    continue
  fi

  SYNC_FILE="${FOLDER_PATH}/glean-sync.yaml"
  AGENT_ID=""
  MESSAGE=""
  AGENT_SYNC_MODE=""
  if [ -f "$SYNC_FILE" ]; then
    AGENT_ID=$(yq '."agent-id" // ""' "$SYNC_FILE")
    MESSAGE=$(yq '.message // ""' "$SYNC_FILE")
    AGENT_SYNC_MODE=$(yq '."sync-mode" // ""' "$SYNC_FILE")
  fi
  SPEC_YAML_ID=$(yq '.id // ""' "${FOLDER_PATH}/spec.yaml" 2>/dev/null || echo "")
  [ -n "$AGENT_ID" ] || AGENT_ID="$SPEC_YAML_ID"
  [ -n "$MESSAGE" ] || MESSAGE="${DEFAULT_MESSAGE:-}"

  if [ -z "$AGENT_ID" ]; then
    echo "::error::Missing agent-id in ${FOLDER} — set the id field in spec.yaml or add a glean-sync.yaml with an agent-id field."
    append_result '. + [{"agentId": $aid, "agentName": $name, "agentMode": $agentMode, "mode": "unknown", "status": "error", "error": "missing agent-id — set id in spec.yaml or add agent-id to glean-sync.yaml"}]' --arg aid "$FOLDER" --arg name "$AGENT_DISPLAY_NAME" --arg agentMode "$AGENT_MODE"
    HAS_FAILURE=true
    continue
  fi
  if [ -f "$SYNC_FILE" ] && [ -n "$SPEC_YAML_ID" ] && [ "$SPEC_YAML_ID" != "$AGENT_ID" ]; then
    echo "::error::Agent ID mismatch in ${FOLDER} — glean-sync.yaml has '${AGENT_ID}' but spec.yaml has '${SPEC_YAML_ID}'. These must match."
    append_result '. + [{"agentId": $aid, "agentName": $name, "agentMode": $agentMode, "mode": "unknown", "status": "error", "error": $err}]' --arg aid "$AGENT_ID" --arg name "$FOLDER" --arg agentMode "$AGENT_MODE" --arg err "Agent ID mismatch: glean-sync.yaml='$AGENT_ID' spec.yaml='$SPEC_YAML_ID'"
    HAS_FAILURE=true
    continue
  fi

  EFFECTIVE_SYNC_MODE="${AGENT_SYNC_MODE:-${DEFAULT_SYNC_MODE}}"
  if [ "$EFFECTIVE_SYNC_MODE" != "staged" ] && [ "$EFFECTIVE_SYNC_MODE" != "published" ]; then
    echo "::error::Invalid sync-mode value '${EFFECTIVE_SYNC_MODE}' in ${FOLDER} — must be 'staged' or 'published'."
    append_result '. + [{"agentId": $aid, "agentName": $name, "agentMode": $agentMode, "mode": "unknown", "status": "error", "error": $err}]' --arg aid "$AGENT_ID" --arg name "$FOLDER" --arg agentMode "$AGENT_MODE" --arg err "invalid sync-mode value '${EFFECTIVE_SYNC_MODE}' — must be staged or published"
    HAS_FAILURE=true
    continue
  fi

  MODE="draft_preview"
  if [ "${FORCE_DRAFT:-false}" != "true" ] && { [ "$EVENT_NAME" != "pull_request" ] && { [ "$EVENT_NAME" != "workflow_dispatch" ] || [ -z "${PR_RETRY:-}" ]; }; }; then
    MODE="$EFFECTIVE_SYNC_MODE"
  fi
  IS_PREVIEW=false
  REQUEST_URL="${INSTANCE_URL_BE}/rest/api/v1/agents/${AGENT_ID}/import"
  if [ "$MODE" = "draft_preview" ]; then
    IS_PREVIEW=true
  fi

  if ! package_agent_bundle "$FOLDER_PATH" "$BUNDLE_FILE"; then
    append_result '. + [{"agentId": $aid, "agentName": $name, "agentMode": $agentMode, "mode": $mode, "status": "error", "error": $err}]' --arg aid "$AGENT_ID" --arg name "$FOLDER" --arg agentMode "$AGENT_MODE" --arg mode "$MODE" --arg err "failed to package agent bundle"
    HAS_FAILURE=true
    continue
  fi

  AGENT_DISPLAY_NAME=$(yq '.name // ""' "${FOLDER_PATH}/spec.yaml" 2>/dev/null || echo "")
  [ -n "$AGENT_DISPLAY_NAME" ] || AGENT_DISPLAY_NAME="$FOLDER"
  echo "Agent: $AGENT_ID (folder: $FOLDER)"
  echo "  Mode: $MODE | AgentMode: $AGENT_MODE | Message: $MESSAGE"

  CURL_ARGS=(curl -sS --connect-timeout 10 --max-time 60 -o "$RESPONSE_FILE" -w '%{http_code}' -X POST "$REQUEST_URL" -H "Authorization: Bearer ${API_TOKEN}" -F "bundle=@${BUNDLE_FILE};type=application/zip")
  if [ "$IS_PREVIEW" = "true" ]; then
    CURL_ARGS+=(-F "transient=true" -F "parentWorkflowId=${AGENT_ID}")
  else
    CURL_ARGS+=(-F "syncMode=$(printf '%s' "$EFFECTIVE_SYNC_MODE" | tr '[:lower:]' '[:upper:]')")
  fi
  [ -n "${COMMIT_SHA:-}" ] && CURL_ARGS+=(-F "gitCommitSha=${COMMIT_SHA}")
  [ -n "${PR_AUTHOR:-}" ] && CURL_ARGS+=(-F "gitAuthorId=${PR_AUTHOR}")
  [ -n "$MESSAGE" ] && CURL_ARGS+=(-F "commitMessage=${MESSAGE}")

  CURL_EXIT=0
  HTTP_CODE=$("${CURL_ARGS[@]}" 2>"$CURL_ERR_FILE") || CURL_EXIT=$?
  if [ "$CURL_EXIT" -ne 0 ] || ! [[ "$HTTP_CODE" =~ ^[0-9]+$ ]]; then
    CURL_ERR=$(tr '\n' ' ' < "$CURL_ERR_FILE" 2>/dev/null | sed 's/[[:space:]]*$//')
    [ -n "$CURL_ERR" ] || CURL_ERR="curl exited $CURL_EXIT"
    echo "::error::Network error syncing agent $AGENT_ID: $CURL_ERR"
    append_result '. + [{"agentId": $aid, "agentName": $name, "agentMode": $agentMode, "mode": $mode, "status": "error", "error": $err}]' --arg aid "$AGENT_ID" --arg name "$AGENT_DISPLAY_NAME" --arg agentMode "$AGENT_MODE" --arg mode "$MODE" --arg err "network error: $CURL_ERR"
    HAS_FAILURE=true
    continue
  fi

  EXPECTED_STATUS="UPDATED"
  [ "$IS_PREVIEW" = "true" ] && EXPECTED_STATUS="DRAFT_PREVIEW"
  ACTUAL_STATUS=$(jq -r '.status // .workflowResult.status // ""' "$RESPONSE_FILE" 2>/dev/null || echo "")
  if [ "$HTTP_CODE" -lt 200 ] || [ "$HTTP_CODE" -ge 300 ]; then
    RESP_BODY=$(cat "$RESPONSE_FILE" 2>/dev/null || echo "no response body")
    echo "::error::Failed to sync agent $AGENT_ID (HTTP $HTTP_CODE): $RESP_BODY"
    append_result '. + [{"agentId": $aid, "agentName": $name, "agentMode": $agentMode, "mode": $mode, "status": "error", "error": $err}]' --arg aid "$AGENT_ID" --arg name "$AGENT_DISPLAY_NAME" --arg agentMode "$AGENT_MODE" --arg mode "$MODE" --arg err "HTTP $HTTP_CODE"
    HAS_FAILURE=true
    continue
  fi
  if [ "$ACTUAL_STATUS" != "$EXPECTED_STATUS" ] && { [ "$EXPECTED_STATUS" != "UPDATED" ] || [ "$ACTUAL_STATUS" != "CREATED" ]; }; then
    echo "::error::Import for ${AGENT_ID} returned unexpected status '${ACTUAL_STATUS}' (expected ${EXPECTED_STATUS})."
    append_result '. + [{"agentId": $aid, "agentName": $name, "agentMode": $agentMode, "mode": $mode, "status": "error", "error": $err}]' --arg aid "$AGENT_ID" --arg name "$AGENT_DISPLAY_NAME" --arg agentMode "$AGENT_MODE" --arg mode "$MODE" --arg err "unexpected import status '${ACTUAL_STATUS}'"
    HAS_FAILURE=true
    continue
  fi

  PREVIEW_ID=""
  if [ "$IS_PREVIEW" = "true" ]; then
    PREVIEW_ID=$(jq -r '.workflowResult.workflow.id // ""' "$RESPONSE_FILE" 2>/dev/null || echo "")
    if [ -z "$PREVIEW_ID" ]; then
      echo "::error::Preview for ${AGENT_ID} returned no transient workflow id."
      append_result '. + [{"agentId": $aid, "agentName": $name, "agentMode": $agentMode, "mode": $mode, "status": "error", "error": "preview returned no transient workflow id"}]' --arg aid "$AGENT_ID" --arg name "$AGENT_DISPLAY_NAME" --arg agentMode "$AGENT_MODE" --arg mode "$MODE"
      HAS_FAILURE=true
      continue
    fi
  fi
  echo "  Synced successfully (HTTP $HTTP_CODE)"
  append_result '. + [{"agentId": $aid, "agentName": $name, "agentMode": $agentMode, "mode": $mode, "message": $msg, "previewId": $pid, "status": "success"}]' --arg aid "$AGENT_ID" --arg name "$AGENT_DISPLAY_NAME" --arg agentMode "$AGENT_MODE" --arg mode "$MODE" --arg msg "$MESSAGE" --arg pid "$PREVIEW_ID"
done < <(echo "$FOLDERS_JSON" | jq -r '.[]')

echo "$RESULTS" > "$RUNNER_TEMP/agent-sync-results.json"
github_output_heredoc "synced-agents" "$RESULTS"
if [ "$HAS_FAILURE" = "true" ]; then
  echo "::error::One or more agents failed to sync"
  exit 1
fi
