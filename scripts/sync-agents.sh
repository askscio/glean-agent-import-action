#!/usr/bin/env bash
set -euo pipefail

# Required env: API_TOKEN, AGENT_DIR, EVENT_NAME, COMMIT_SHA, INSTANCE_URL_BE, FOLDERS_JSON
# Optional env: DEFAULT_MESSAGE (from PR title or git commit subject), DEFAULT_SYNC_MODE, FORCE_DRAFT, PR_AUTHOR, PR_RETRY

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=github_output.sh
source "${_script_dir}/github_output.sh"
unset _script_dir
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONVERTER="${SCRIPT_DIR}/agent_converter.py"

INSTANCE_URL_BE="${INSTANCE_URL_BE%/}"
RESULTS="[]"
HAS_FAILURE=false

append_result() {
  local filter="$1"
  shift
  RESULTS=$(echo "$RESULTS" | jq -c "$@" "$filter" | jq -c --arg folder "$FOLDER" '.[-1] |= . + {folder: $folder}')
}

build_sync_request_workflow() {
  local agent_id="$1"
  local spec_json="$2"
  local commit_sha="$3"
  local publish="$4"   # boolean: true = publish immediately, false = stage only
  local message="$5"
  local git_author_id="$6"

  echo "$spec_json" | jq -c \
    --arg id "$agent_id" \
    --arg sha "$commit_sha" \
    --argjson publish "$publish" \
    --arg msg "$message" \
    --arg author "$git_author_id" \
    '{
      id: $id,
      gitCommitSha: $sha,
      workflowSource: "GIT",
      name: .rootWorkflow.name,
      description: .rootWorkflow.description,
      icon: .rootWorkflow.icon,
      schema: .rootWorkflow.schema
    } + if ($author | length) > 0 then {gitAuthorId: $author} else {} end
      + if $publish then {stagingOptions: {publish: true, commitMessage: $msg}}
        else {stagingOptions: {save: true, commitMessage: $msg}}
        end'
}

build_sync_request_automode() {
  local agent_id="$1"
  local converter_json="$2"
  local commit_sha="$3"
  local publish="$4"   # boolean: true = publish immediately, false = stage only
  local message="$5"
  local git_author_id="$6"

  echo "$converter_json" | jq -c \
    --arg id "$agent_id" \
    --arg sha "$commit_sha" \
    --argjson publish "$publish" \
    --arg msg "$message" \
    --arg author "$git_author_id" \
    '. + {
      id: $id,
      gitCommitSha: $sha,
      workflowSource: "GIT"
    } + if ($author | length) > 0 then {gitAuthorId: $author} else {} end
      + if $publish then {stagingOptions: {publish: true, commitMessage: $msg}}
        else {stagingOptions: {save: true, commitMessage: $msg}}
        end'
}

# Stored separately from the parent, so a preview never touches its draft/staged/published state.
build_preview_request_workflow() {
  local agent_id="$1"
  local spec_json="$2"

  echo "$spec_json" | jq -c \
    --arg parent "$agent_id" \
    '{
      transient: true,
      parentWorkflowId: $parent,
      workflowNamespace: "AGENT",
      name: .rootWorkflow.name,
      description: .rootWorkflow.description,
      icon: .rootWorkflow.icon,
      schema: .rootWorkflow.schema
    }'
}

build_preview_request_automode() {
  local agent_id="$1"
  local converter_json="$2"

  # The real agent id must not ride along as the new workflow's own id.
  echo "$converter_json" | jq -c \
    --arg parent "$agent_id" \
    'del(.id) + {
      transient: true,
      parentWorkflowId: $parent,
      workflowNamespace: "AGENT"
    }'
}

# Infers agent type from folder structure.
# Prints "automode"  if spec.yaml is present (autonomous agent),
#        "workflow"  if a .json spec file is present (workflow agent),
#        "ambiguous" if both are found,
#        "unknown"   if neither is found.
detect_agent_mode() {
  local folder_path="$1"
  local has_spec_yaml=false
  local has_json=false

  [ -f "${folder_path}/spec.yaml" ] && has_spec_yaml=true

  for f in "${folder_path}"/*.json; do
    [ -f "$f" ] && has_json=true && break
  done

  if [ "$has_spec_yaml" = true ] && [ "$has_json" = true ]; then
    echo "ambiguous"
  elif [ "$has_spec_yaml" = true ]; then
    echo "automode"
  elif [ "$has_json" = true ]; then
    echo "workflow"
  else
    echo "unknown"
  fi
}

while IFS= read -r FOLDER; do
  FOLDER_PATH="${AGENT_DIR}/${FOLDER}"
  AGENT_DISPLAY_NAME="$FOLDER"

  if [ ! -d "$FOLDER_PATH" ]; then
    echo "::error::Agent folder ${FOLDER_PATH} was deleted but cannot be auto-retired. Switch the agent back to UI-managed mode in Agent Builder before removing the folder."
    append_result '. + [{"agentId": $aid, "agentName": $name, "agentMode": "unknown", "mode": "deleted", "status": "error", "error": "folder deleted — switch to UI-managed mode to retire"}]' \
      --arg aid "$FOLDER" \
      --arg name "$AGENT_DISPLAY_NAME" 
    HAS_FAILURE=true
    continue
  fi

  AGENT_MODE=$(detect_agent_mode "$FOLDER_PATH")
  if [ "$AGENT_MODE" = "ambiguous" ]; then
    echo "::error::Cannot determine agent type for ${FOLDER_PATH} — found both spec.yaml (autonomous) and .json files (workflow). Remove one."
    append_result '. + [{"agentId": $aid, "agentName": $name, "agentMode": "ambiguous", "mode": "unknown", "status": "error", "error": "both spec.yaml and .json found — remove one to disambiguate"}]' \
      --arg aid "$FOLDER" \
      --arg name "$AGENT_DISPLAY_NAME" 
    HAS_FAILURE=true
    continue
  elif [ "$AGENT_MODE" = "unknown" ]; then
    echo "::error::Cannot determine agent type for ${FOLDER_PATH} — expected either spec.yaml (autonomous agent) or a .json spec file (workflow agent)."
    append_result '. + [{"agentId": $aid, "agentName": $name, "agentMode": "unknown", "mode": "unknown", "status": "error", "error": "no spec.yaml or .json found — add one"}]' \
      --arg aid "$FOLDER" \
      --arg name "$AGENT_DISPLAY_NAME" 
    HAS_FAILURE=true
    continue
  fi

  # glean-sync.yaml is required for workflow agents; optional for autonomous agents.
  SYNC_FILE="${FOLDER_PATH}/glean-sync.yaml"
  AGENT_ID=""
  MESSAGE=""
  AGENT_SYNC_MODE=""

  if [ -f "$SYNC_FILE" ]; then
    AGENT_ID=$(yq '."agent-id" // ""' "$SYNC_FILE")
    MESSAGE=$(yq '.message // ""' "$SYNC_FILE")
    AGENT_SYNC_MODE=$(yq '."sync-mode" // ""' "$SYNC_FILE")
  elif [ "$AGENT_MODE" = "workflow" ]; then
    echo "::error::Missing glean-sync.yaml in ${FOLDER_PATH} — workflow agents require a glean-sync.yaml with at least an agent-id field."
    append_result '. + [{"agentId": $aid, "agentName": $name, "agentMode": $agentMode, "mode": "unknown", "status": "error", "error": "missing glean-sync.yaml — add one with at least agent-id"}]' \
      --arg aid "$FOLDER" \
      --arg name "$AGENT_DISPLAY_NAME" \
      --arg agentMode "$AGENT_MODE" 
    HAS_FAILURE=true
    continue
  fi

  # For autonomous agents without a glean-sync.yaml, derive the agent ID from spec.yaml directly.
  if [ "$AGENT_MODE" = "automode" ] && [ -z "$AGENT_ID" ]; then
    AGENT_ID=$(yq '.id // ""' "${FOLDER_PATH}/spec.yaml" 2>/dev/null || echo "")
  fi

  if [ -z "$MESSAGE" ]; then
    MESSAGE="${DEFAULT_MESSAGE:-}"
  fi

  if [ -z "$AGENT_ID" ]; then
    echo "::error::Missing agent-id in ${FOLDER} — set the id field in spec.yaml or add a glean-sync.yaml with an agent-id field."
    append_result '. + [{"agentId": $aid, "agentName": $name, "agentMode": $agentMode, "mode": "unknown", "status": "error", "error": "missing agent-id — set id in spec.yaml or add agent-id to glean-sync.yaml"}]' \
      --arg aid "$FOLDER" \
      --arg name "$AGENT_DISPLAY_NAME" \
      --arg agentMode "$AGENT_MODE" 
    HAS_FAILURE=true
    continue
  fi

  # Resolve sync mode: per-agent glean-sync.yaml → action input
  EFFECTIVE_SYNC_MODE="${AGENT_SYNC_MODE:-${DEFAULT_SYNC_MODE}}"
  if [ "$EFFECTIVE_SYNC_MODE" != "staged" ] && [ "$EFFECTIVE_SYNC_MODE" != "published" ]; then
    echo "::error::Invalid sync-mode value '${EFFECTIVE_SYNC_MODE}' in ${FOLDER} (sync-mode field of glean-sync.yaml) — must be 'staged' or 'published'."
    append_result '. + [{"agentId": $aid, "agentName": $name, "agentMode": $agentMode, "mode": "unknown", "status": "error", "error": $err}]' \
      --arg aid "$AGENT_ID" \
      --arg name "$AGENT_DISPLAY_NAME" \
      --arg agentMode "$AGENT_MODE" \
      --arg err "invalid sync-mode value '${EFFECTIVE_SYNC_MODE}' in sync-mode field of glean-sync.yaml — must be staged or published" 
    HAS_FAILURE=true
    continue
  fi

  PUBLISH=false
  MODE="draft_preview"
  if [ "${FORCE_DRAFT:-false}" = "true" ]; then
    MODE="draft_preview"
  elif [ "$EVENT_NAME" = "workflow_dispatch" ] && [ -n "${PR_RETRY:-}" ]; then
    MODE="draft_preview"
  elif [ "$EVENT_NAME" != "pull_request" ]; then
    if [ "$EFFECTIVE_SYNC_MODE" = "published" ]; then
      PUBLISH=true
      MODE="published"
    else
      PUBLISH=false
      MODE="staged"
    fi
  fi

  IS_PREVIEW=false
  REQUEST_URL="${INSTANCE_URL_BE}/rest/api/v1/agents/${AGENT_ID}"
  if [ "$MODE" = "draft_preview" ]; then
    IS_PREVIEW=true
    REQUEST_URL="${INSTANCE_URL_BE}/rest/api/v1/agents"
  fi

  if [ "$AGENT_MODE" = "workflow" ]; then
    JSON_SPEC_FILES=()
    for JSON_FILE in "${FOLDER_PATH}"/*.json; do
      [ -f "$JSON_FILE" ] && JSON_SPEC_FILES+=("$JSON_FILE")
    done

    if [ "${#JSON_SPEC_FILES[@]}" -gt 1 ]; then
      echo "::error::Multiple .json files found in ${FOLDER_PATH} — exactly one spec file is allowed per agent folder."
      append_result '. + [{"agentId": $aid, "agentName": $name, "agentMode": $agentMode, "mode": "unknown", "status": "error", "error": "multiple .json files found — keep exactly one spec file"}]' \
        --arg aid "$AGENT_ID" \
        --arg name "$AGENT_DISPLAY_NAME" \
        --arg agentMode "$AGENT_MODE" 
      HAS_FAILURE=true
      continue
    fi

    SPEC_FILE="${JSON_SPEC_FILES[0]}"

    SPEC_JSON=$(cat "$SPEC_FILE")
    if ! echo "$SPEC_JSON" | jq empty 2>/dev/null; then
      echo "::error::Invalid JSON in ${SPEC_FILE}"
      append_result '. + [{"agentId": $aid, "agentName": $name, "agentMode": $agentMode, "mode": "unknown", "status": "error", "error": "invalid JSON in spec file"}]' \
        --arg aid "$AGENT_ID" \
        --arg name "$AGENT_DISPLAY_NAME" \
        --arg agentMode "$AGENT_MODE" 
      HAS_FAILURE=true
      continue
    fi

    WORKFLOW_NAME=$(echo "$SPEC_JSON" | jq -r '.rootWorkflow.name // ""')
    [ -n "$WORKFLOW_NAME" ] && AGENT_DISPLAY_NAME="$WORKFLOW_NAME"

    if [ "$IS_PREVIEW" = "true" ]; then
      REQUEST_BODY=$(build_preview_request_workflow "$AGENT_ID" "$SPEC_JSON")
    else
      REQUEST_BODY=$(build_sync_request_workflow "$AGENT_ID" "$SPEC_JSON" "$COMMIT_SHA" "$PUBLISH" "$MESSAGE" "${PR_AUTHOR:-}")
    fi

  elif [ "$AGENT_MODE" = "automode" ]; then
    CONVERTER_STDERR_FILE="$RUNNER_TEMP/converter-stderr-${FOLDER}.txt"
    set +e
    CONVERTER_OUTPUT=$(uv run "$CONVERTER" to-json "$FOLDER" --dir "$AGENT_DIR" 2>"$CONVERTER_STDERR_FILE")
    CONVERTER_EXIT=$?
    set -e

    if [ $CONVERTER_EXIT -ne 0 ]; then
      CONVERTER_ERR=$(cat "$CONVERTER_STDERR_FILE" 2>/dev/null || echo "unknown converter error")
      echo "::error::Converter failed for ${FOLDER} — ${CONVERTER_ERR}"
      append_result '. + [{"agentId": $aid, "agentName": $name, "agentMode": $agentMode, "mode": $mode, "status": "error", "error": $err}]' \
        --arg aid "$AGENT_ID" \
        --arg name "$AGENT_DISPLAY_NAME" \
        --arg agentMode "$AGENT_MODE" \
        --arg mode "$MODE" \
        --arg err "Converter failed: $CONVERTER_ERR" 
      HAS_FAILURE=true
      continue
    fi

    if ! echo "$CONVERTER_OUTPUT" | jq empty 2>/dev/null; then
      echo "::error::Converter produced invalid JSON for ${FOLDER} — check spec.yaml and instructions.md"
      append_result '. + [{"agentId": $aid, "agentName": $name, "agentMode": $agentMode, "mode": $mode, "status": "error", "error": "converter produced invalid JSON"}]' \
        --arg aid "$AGENT_ID" \
        --arg name "$AGENT_DISPLAY_NAME" \
        --arg agentMode "$AGENT_MODE" \
        --arg mode "$MODE" 
      HAS_FAILURE=true
      continue
    fi

    # When glean-sync.yaml is present, verify its agent-id matches spec.yaml to catch drift.
    if [ -f "$SYNC_FILE" ]; then
      SPEC_YAML_ID=$(yq '.id // ""' "${FOLDER_PATH}/spec.yaml" 2>/dev/null || echo "")
      if [ -n "$SPEC_YAML_ID" ] && [ "$SPEC_YAML_ID" != "$AGENT_ID" ]; then
        echo "::error::Agent ID mismatch in ${FOLDER} — glean-sync.yaml has '${AGENT_ID}' but spec.yaml has '${SPEC_YAML_ID}'. These must match."
        append_result '. + [{"agentId": $aid, "agentName": $name, "agentMode": $agentMode, "mode": $mode, "status": "error", "error": $err}]' \
          --arg aid "$AGENT_ID" \
          --arg name "$AGENT_DISPLAY_NAME" \
          --arg agentMode "$AGENT_MODE" \
          --arg mode "$MODE" \
          --arg err "Agent ID mismatch: glean-sync.yaml='$AGENT_ID' spec.yaml='$SPEC_YAML_ID'" 
        HAS_FAILURE=true
        continue
      fi
    fi

    AUTOMODE_NAME=$(echo "$CONVERTER_OUTPUT" | jq -r '.name // ""')
    [ -n "$AUTOMODE_NAME" ] && AGENT_DISPLAY_NAME="$AUTOMODE_NAME"

    if [ "$IS_PREVIEW" = "true" ]; then
      REQUEST_BODY=$(build_preview_request_automode "$AGENT_ID" "$CONVERTER_OUTPUT")
    else
      REQUEST_BODY=$(build_sync_request_automode "$AGENT_ID" "$CONVERTER_OUTPUT" "$COMMIT_SHA" "$PUBLISH" "$MESSAGE" "${PR_AUTHOR:-}")
    fi
  fi

  echo "Agent: $AGENT_ID (folder: $FOLDER)"
  echo "  Mode: $MODE | AgentMode: $AGENT_MODE | Message: $MESSAGE"
  echo "  Request body:"
  echo "$REQUEST_BODY" | jq .

  # Capture curl failures (DNS, TLS, timeout, connection reset, ...) without
  # tripping `set -e` so the loop can record a per-agent error and continue.
  # Write body to a file to avoid ARG_MAX limits when the spec is large.
  CURL_ERR_FILE="$RUNNER_TEMP/sync-curl-error-${FOLDER}.txt"
  CURL_BODY_FILE="$RUNNER_TEMP/sync-body-${FOLDER}.json"
  printf '%s' "$REQUEST_BODY" > "$CURL_BODY_FILE"
  CURL_EXIT=0
  HTTP_CODE=$(curl -sS --connect-timeout 10 --max-time 60 \
    -o "$RUNNER_TEMP/sync-response-${FOLDER}.json" -w '%{http_code}' \
    -X POST "${REQUEST_URL}" \
    -H "Authorization: Bearer ${API_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "@${CURL_BODY_FILE}" 2>"$CURL_ERR_FILE") || CURL_EXIT=$?

  if [ "$CURL_EXIT" -ne 0 ] || ! [[ "$HTTP_CODE" =~ ^[0-9]+$ ]]; then
    CURL_ERR=$(tr '\n' ' ' < "$CURL_ERR_FILE" 2>/dev/null | sed 's/[[:space:]]*$//')
    [ -z "$CURL_ERR" ] && CURL_ERR="curl exited $CURL_EXIT"
    echo "::error::Network error syncing agent $AGENT_ID: $CURL_ERR"
    append_result '. + [{"agentId": $aid, "agentName": $name, "agentMode": $agentMode, "mode": $mode, "status": "error", "error": $err}]' \
      --arg aid "$AGENT_ID" \
      --arg name "$AGENT_DISPLAY_NAME" \
      --arg agentMode "$AGENT_MODE" \
      --arg mode "$MODE" \
      --arg err "network error: $CURL_ERR" 
    HAS_FAILURE=true
    continue
  fi

  if [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 300 ]; then
    echo "  Synced successfully (HTTP $HTTP_CODE)"
    PREVIEW_ID=""
    if [ "$IS_PREVIEW" = "true" ]; then
      PREVIEW_ID=$(jq -r '.workflow.id // ""' "$RUNNER_TEMP/sync-response-${FOLDER}.json" 2>/dev/null || echo "")
      # No transient id means the isolated preview was not created — usually
      # agents.transientWorkflows being disabled server-side. There is nothing safe to
      # link, so fail rather than point the reviewer at the real agent.
      if [ -z "$PREVIEW_ID" ]; then
        echo "::error::Preview for ${AGENT_ID} returned no transient workflow id — check that agents.transientWorkflows is enabled on ${INSTANCE_URL_BE}."
        append_result '. + [{"agentId": $aid, "agentName": $name, "agentMode": $agentMode, "mode": $mode, "status": "error", "error": $err}]' \
          --arg aid "$AGENT_ID" \
          --arg name "$AGENT_DISPLAY_NAME" \
          --arg agentMode "$AGENT_MODE" \
          --arg mode "$MODE" \
          --arg err "preview returned no transient workflow id"
        HAS_FAILURE=true
        continue
      fi
      echo "  Transient preview workflow: $PREVIEW_ID"
    fi
    append_result '. + [{"agentId": $aid, "agentName": $name, "agentMode": $agentMode, "mode": $mode, "message": $msg, "previewId": $pid, "status": "success"}]' \
      --arg aid "$AGENT_ID" \
      --arg name "$AGENT_DISPLAY_NAME" \
      --arg agentMode "$AGENT_MODE" \
      --arg mode "$MODE" \
      --arg msg "$MESSAGE" \
      --arg pid "$PREVIEW_ID"
  else
    RESP_BODY=$(cat "$RUNNER_TEMP/sync-response-${FOLDER}.json" 2>/dev/null || echo "no response body")
    echo "::error::Failed to sync agent $AGENT_ID (HTTP $HTTP_CODE): $RESP_BODY"
    append_result '. + [{"agentId": $aid, "agentName": $name, "agentMode": $agentMode, "mode": $mode, "status": "error", "error": $err}]' \
      --arg aid "$AGENT_ID" \
      --arg name "$AGENT_DISPLAY_NAME" \
      --arg agentMode "$AGENT_MODE" \
      --arg mode "$MODE" \
      --arg err "HTTP $HTTP_CODE" 
    HAS_FAILURE=true
  fi
done < <(echo "$FOLDERS_JSON" | jq -r '.[]')

echo "$RESULTS" > "$RUNNER_TEMP/agent-sync-results.json"
github_output_heredoc "synced-agents" "$RESULTS"

if [ "$HAS_FAILURE" = "true" ]; then
  echo "::error::One or more agents failed to sync"
  exit 1
fi
