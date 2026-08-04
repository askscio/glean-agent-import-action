#!/usr/bin/env bash
set -euo pipefail

# Mocked tests for sync-agents.sh.
# `curl`, `yq` and `uv` are stubbed on PATH so nothing leaves the machine: the curl
# stub records the request URL and body and replays a canned response. These assert
# the split between PR previews (which create an isolated transient workflow) and
# merge syncs (which mutate the real agent) — crossing those wires would write PR
# content into an agent's durable draft/staged/published state.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC_SCRIPT="${SCRIPT_DIR}/../scripts/sync-agents.sh"
BE_URL="https://acme-be.glean.com"

PASS=0
FAIL=0
ERRORS=""

# ── Helpers ─────────────────────────────────────────────────────────────────

assert_eq() {
  local test_name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  PASS: $test_name"
    PASS=$((PASS+1))
  else
    echo "  FAIL: $test_name"
    echo "    Expected: $expected"
    echo "    Actual:   $actual"
    FAIL=$((FAIL+1))
    ERRORS+="  - $test_name\n"
  fi
}

# Every test starts from the same known env so a previous test's overrides cannot leak.
reset_env() {
  EVENT_NAME="pull_request"
  DEFAULT_SYNC_MODE="staged"
  FORCE_DRAFT="false"
  PR_RETRY=""
  MOCK_RESPONSE='{"workflow":{"id":"transient-999"}}'
  MOCK_HTTP_CODE="200"
}

# new_sandbox <workflow|automode> [sync_mode] — echoes the sandbox root.
# Callers read $root/capture/{url,body.json} and $root/tmp/agent-sync-results.json.
new_sandbox() {
  local agent_mode="$1" sync_mode="${2:-staged}" root
  root=$(mktemp -d)
  mkdir -p "$root/bin" "$root/capture" "$root/tmp" "$root/agents/test-bench"

  if [ "$agent_mode" = "workflow" ]; then
    cat > "$root/agents/test-bench/agent.json" <<'JSON'
{
  "rootWorkflow": {
    "name": "Test Bench Agent",
    "description": "an agent used by tests",
    "icon": {"color": "#123456"},
    "schema": {"goal": "do the thing"}
  }
}
JSON
  else
    printf 'id: agent-123\nname: Auto Bench Agent\n' > "$root/agents/test-bench/spec.yaml"
  fi

  printf 'agent-id: agent-123\nmessage: sync from git\nsync-mode: %s\n' "$sync_mode" \
    > "$root/agents/test-bench/glean-sync.yaml"

  cat > "$root/bin/curl" <<'CURL'
#!/usr/bin/env bash
out=""
url=""
body=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -d) body="${2#@}"; shift 2 ;;
    -X|-H) shift 2 ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
printf '%s' "$url" > "$CAPTURE_DIR/url"
if [ -n "$body" ]; then
  cp "$body" "$CAPTURE_DIR/body.json"
fi
resp="${MOCK_RESPONSE:-}"
if [ -z "$resp" ]; then
  resp='{}'
fi
if [ -n "$out" ]; then
  printf '%s' "$resp" > "$out"
fi
printf '%s' "${MOCK_HTTP_CODE:-200}"
CURL

  # Minimal reader for `yq '.key // ""' <file>` against flat key: value YAML.
  cat > "$root/bin/yq" <<'YQ'
#!/usr/bin/env bash
key=$(printf '%s' "$1" | sed -E 's/^\.//; s/[[:space:]]*\/\/.*$//; s/^"//; s/"$//')
file="${2:-}"
if [ ! -f "$file" ]; then
  printf '\n'
  exit 0
fi
sed -nE "s/^${key}:[[:space:]]*(.*)$/\1/p" "$file" | head -1 | sed -E 's/^"//; s/"$//'
YQ

  # Stands in for the auto-mode converter (`uv run ... to-json`).
  cat > "$root/bin/uv" <<'UV'
#!/usr/bin/env bash
printf '%s' "$MOCK_CONVERTER_OUTPUT"
UV

  chmod +x "$root/bin/curl" "$root/bin/yq" "$root/bin/uv"
  echo "$root"
}

run_sync() {
  local root="$1"
  (
    cd "$root" &&
    PATH="$root/bin:$PATH" \
    CAPTURE_DIR="$root/capture" \
    RUNNER_TEMP="$root/tmp" \
    GITHUB_OUTPUT="$root/tmp/github_output" \
    API_TOKEN="test-token" \
    AGENT_DIR="agents" \
    COMMIT_SHA="deadbeef" \
    INSTANCE_URL_BE="$BE_URL" \
    FOLDERS_JSON='["test-bench"]' \
    DEFAULT_MESSAGE="pr title" \
    DEFAULT_SYNC_MODE="$DEFAULT_SYNC_MODE" \
    EVENT_NAME="$EVENT_NAME" \
    FORCE_DRAFT="$FORCE_DRAFT" \
    PR_RETRY="$PR_RETRY" \
    MOCK_RESPONSE="$MOCK_RESPONSE" \
    MOCK_HTTP_CODE="$MOCK_HTTP_CODE" \
    MOCK_CONVERTER_OUTPUT="${MOCK_CONVERTER_OUTPUT:-}" \
      bash "$SYNC_SCRIPT" >/dev/null 2>&1
  ) || true
}

captured_url() { cat "$1/capture/url" 2>/dev/null || echo "MISSING"; }
captured_body() { cat "$1/capture/body.json" 2>/dev/null || echo '{}'; }
result_field() { jq -r "$2" "$1/tmp/agent-sync-results.json" 2>/dev/null || echo "MISSING"; }

# ── Tests ───────────────────────────────────────────────────────────────────

test_pr_preview_creates_transient_workflow() {
  echo "Test: PR preview creates a transient workflow"
  local r body
  reset_env
  r=$(new_sandbox workflow)
  run_sync "$r"

  assert_eq "posts to the create-agent endpoint" \
    "${BE_URL}/rest/api/v1/agents" "$(captured_url "$r")"

  body=$(captured_body "$r")
  assert_eq "transient is true" "true" "$(echo "$body" | jq -c '.transient')"
  assert_eq "parentWorkflowId is the real agent" \
    '"agent-123"' "$(echo "$body" | jq -c '.parentWorkflowId')"
  assert_eq "workflowNamespace is AGENT" \
    '"AGENT"' "$(echo "$body" | jq -c '.workflowNamespace')"
  assert_eq "preview carries the branch definition" \
    '"do the thing"' "$(echo "$body" | jq -c '.schema.goal')"
  assert_eq "preview does not claim the real agent id" \
    "null" "$(echo "$body" | jq -c '.id')"
  assert_eq "preview neither stages nor publishes" \
    "null" "$(echo "$body" | jq -c '.stagingOptions')"

  assert_eq "previewId comes from the response workflow id" \
    "transient-999" "$(result_field "$r" '.[0].previewId')"
  assert_eq "preview recorded as a success" \
    "success" "$(result_field "$r" '.[0].status')"
  rm -rf "$r"
}

test_automode_preview_reparents_agent() {
  echo "Test: auto-mode PR preview reparents instead of reusing the agent id"
  local r body
  reset_env
  MOCK_CONVERTER_OUTPUT='{"id":"agent-123","name":"Auto Bench Agent","schema":{"goal":"auto goal"}}'
  r=$(new_sandbox automode)
  run_sync "$r"

  assert_eq "posts to the create-agent endpoint" \
    "${BE_URL}/rest/api/v1/agents" "$(captured_url "$r")"

  body=$(captured_body "$r")
  assert_eq "transient is true" "true" "$(echo "$body" | jq -c '.transient')"
  assert_eq "parentWorkflowId is the real agent" \
    '"agent-123"' "$(echo "$body" | jq -c '.parentWorkflowId')"
  assert_eq "workflowNamespace is AGENT" \
    '"AGENT"' "$(echo "$body" | jq -c '.workflowNamespace')"
  assert_eq "the converter's id is dropped" "null" "$(echo "$body" | jq -c '.id')"
  assert_eq "definition is preserved" \
    '"auto goal"' "$(echo "$body" | jq -c '.schema.goal')"
  assert_eq "previewId captured" \
    "transient-999" "$(result_field "$r" '.[0].previewId')"
  unset MOCK_CONVERTER_OUTPUT
  rm -rf "$r"
}

test_staged_merge_updates_real_agent() {
  echo "Test: staged merge still updates the real agent"
  local r body
  reset_env
  EVENT_NAME="push"
  DEFAULT_SYNC_MODE="staged"
  r=$(new_sandbox workflow staged)
  run_sync "$r"

  assert_eq "posts to the per-agent endpoint" \
    "${BE_URL}/rest/api/v1/agents/agent-123" "$(captured_url "$r")"

  body=$(captured_body "$r")
  assert_eq "no transient flag on merge" "null" "$(echo "$body" | jq -c '.transient')"
  assert_eq "no parentWorkflowId on merge" "null" "$(echo "$body" | jq -c '.parentWorkflowId')"
  assert_eq "targets the real agent id" '"agent-123"' "$(echo "$body" | jq -c '.id')"
  assert_eq "stages a save" "true" "$(echo "$body" | jq -c '.stagingOptions.save')"
  assert_eq "mode recorded as staged" "staged" "$(result_field "$r" '.[0].mode')"
  rm -rf "$r"
}

test_published_merge_updates_real_agent() {
  echo "Test: published merge still publishes the real agent"
  local r body
  reset_env
  EVENT_NAME="push"
  DEFAULT_SYNC_MODE="published"
  r=$(new_sandbox workflow published)
  run_sync "$r"

  assert_eq "posts to the per-agent endpoint" \
    "${BE_URL}/rest/api/v1/agents/agent-123" "$(captured_url "$r")"

  body=$(captured_body "$r")
  assert_eq "no transient flag on publish" "null" "$(echo "$body" | jq -c '.transient')"
  assert_eq "publishes" "true" "$(echo "$body" | jq -c '.stagingOptions.publish')"
  assert_eq "mode recorded as published" "published" "$(result_field "$r" '.[0].mode')"
  rm -rf "$r"
}

test_retry_dispatch_uses_preview_path() {
  echo "Test: workflow_dispatch retry for a PR uses the preview path"
  local r
  reset_env
  EVENT_NAME="workflow_dispatch"
  PR_RETRY="42"
  MOCK_RESPONSE='{"workflow":{"id":"transient-retry"}}'
  r=$(new_sandbox workflow)
  run_sync "$r"

  assert_eq "retry posts to the create-agent endpoint" \
    "${BE_URL}/rest/api/v1/agents" "$(captured_url "$r")"
  assert_eq "retry captures a previewId" \
    "transient-retry" "$(result_field "$r" '.[0].previewId')"
  rm -rf "$r"
}

test_force_draft_uses_preview_path() {
  echo "Test: FORCE_DRAFT uses the preview path even on push"
  local r
  reset_env
  EVENT_NAME="push"
  FORCE_DRAFT="true"
  MOCK_RESPONSE='{"workflow":{"id":"transient-forced"}}'
  r=$(new_sandbox workflow)
  run_sync "$r"

  assert_eq "forced draft posts to the create-agent endpoint" \
    "${BE_URL}/rest/api/v1/agents" "$(captured_url "$r")"
  assert_eq "forced draft captures a previewId" \
    "transient-forced" "$(result_field "$r" '.[0].previewId')"
  rm -rf "$r"
}

test_preview_without_id_stays_empty() {
  echo "Test: preview response with no workflow id leaves previewId empty"
  local r
  reset_env
  MOCK_RESPONSE='{"workflow":{}}'
  r=$(new_sandbox workflow)
  run_sync "$r"

  assert_eq "previewId is empty" "" "$(result_field "$r" '.[0].previewId')"
  assert_eq "still a success" "success" "$(result_field "$r" '.[0].status')"
  rm -rf "$r"
}

test_preview_failure_records_error() {
  echo "Test: failed preview records an error and no previewId"
  local r
  reset_env
  MOCK_HTTP_CODE="403"
  MOCK_RESPONSE='{"error":"forbidden"}'
  r=$(new_sandbox workflow)
  run_sync "$r"

  assert_eq "status is error" "error" "$(result_field "$r" '.[0].status')"
  assert_eq "error mentions the http code" "HTTP 403" "$(result_field "$r" '.[0].error')"
  assert_eq "no previewId is recorded" "null" "$(result_field "$r" '.[0].previewId')"
  rm -rf "$r"
}

# ── Runner ──────────────────────────────────────────────────────────────────

test_pr_preview_creates_transient_workflow
echo ""
test_automode_preview_reparents_agent
echo ""
test_staged_merge_updates_real_agent
echo ""
test_published_merge_updates_real_agent
echo ""
test_retry_dispatch_uses_preview_path
echo ""
test_force_draft_uses_preview_path
echo ""
test_preview_without_id_stays_empty
echo ""
test_preview_failure_records_error

echo ""
echo "========================================="
echo "  Results: $PASS passed, $FAIL failed"
echo "========================================="

if [ $FAIL -gt 0 ]; then
  echo ""
  echo "Failed tests:"
  echo -e "$ERRORS"
  exit 1
fi
