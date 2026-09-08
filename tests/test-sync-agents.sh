#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC_SCRIPT="${SCRIPT_DIR}/../scripts/sync-agents.sh"
BE_URL="https://acme-be.glean.com"
PASS=0
FAIL=0

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $name (expected '$expected', got '$actual')"
    FAIL=$((FAIL + 1))
  fi
}

new_sandbox() {
  local root
  root=$(mktemp -d)
  mkdir -p "$root/bin" "$root/capture" "$root/tmp" "$root/repo/agents/test-bench/skills/.hidden" "$root/repo/agents/test-bench/subagents"
  printf 'id: agent-123\nname: Auto Bench Agent\n' > "$root/repo/agents/test-bench/spec.yaml"
  printf 'instructions\n' > "$root/repo/agents/test-bench/instructions.md"
  printf 'nested skill\n' > "$root/repo/agents/test-bench/skills/.hidden/file.md"
  printf 'subagent\n' > "$root/repo/agents/test-bench/subagents/child.md"
  printf 'agent-id: agent-123\nmessage: sync from git\nsync-mode: %s\n' "${1:-staged}" > "$root/repo/agents/test-bench/glean-sync.yaml"
  git -C "$root/repo" init -q

  cat > "$root/bin/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
out=""; url=""; fields=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -F) fields+="$2\n"; case "$2" in bundle=@*) bundle_path="${2#bundle=@}"; cp "${bundle_path%;*}" "$CAPTURE_DIR/bundle.zip" ;; esac; shift 2 ;;
    -X|-H|-w) shift 2 ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
printf '%s' "$url" > "$CAPTURE_DIR/url"
printf '%b' "$fields" > "$CAPTURE_DIR/fields"
printf '%s' "${MOCK_RESPONSE:-{\"status\":\"UPDATED\"}}" > "$out"
printf '%s' "${MOCK_HTTP_CODE:-200}"
CURL

  cat > "$root/bin/yq" <<'YQ'
#!/usr/bin/env bash
key=$(printf '%s' "$1" | sed -E 's/^\.//; s/[[:space:]]*\/\/.*$//; s/^"//; s/"$//')
sed -nE "s/^${key}:[[:space:]]*(.*)$/\1/p" "${2:-}" | head -1 | sed -E 's/^"//; s/"$//' || true
YQ
  chmod +x "$root/bin/curl" "$root/bin/yq"
  echo "$root"
}

run_sync() {
  local root="$1"
  (cd "$root/repo" && PATH="$root/bin:$PATH" CAPTURE_DIR="$root/capture" RUNNER_TEMP="$root/tmp" GITHUB_OUTPUT="$root/tmp/output" API_TOKEN=test-token AGENT_DIR=agents COMMIT_SHA=deadbeef INSTANCE_URL_BE="$BE_URL" FOLDERS_JSON='["test-bench"]' DEFAULT_MESSAGE='pr title' DEFAULT_SYNC_MODE="${DEFAULT_SYNC_MODE:-staged}" EVENT_NAME="${EVENT_NAME:-pull_request}" FORCE_DRAFT="${FORCE_DRAFT:-false}" PR_RETRY="${PR_RETRY:-}" PR_AUTHOR="${PR_AUTHOR:-octocat}" MOCK_RESPONSE="${MOCK_RESPONSE:-}" MOCK_HTTP_CODE="${MOCK_HTTP_CODE:-200}" bash "$SYNC_SCRIPT" >/dev/null 2>&1) || true
}

field() { grep -F "$1" "$2/capture/fields" 2>/dev/null || true; }
result() { jq -r "$2" "$1/tmp/agent-sync-results.json" 2>/dev/null || echo MISSING; }

test_preview() {
  local r
  EVENT_NAME=pull_request
  MOCK_RESPONSE='{"status":"DRAFT_PREVIEW","workflowResult":{"workflow":{"id":"transient-999"}}}'
  r=$(new_sandbox)
  run_sync "$r"
  assert_eq preview-url "$BE_URL/rest/api/v1/agents/agent-123/import" "$(cat "$r/capture/url")"
  assert_eq preview-transient 'transient=true' "$(field transient=true "$r")"
  assert_eq preview-parent 'parentWorkflowId=agent-123' "$(field parentWorkflowId=agent-123 "$r")"
  assert_eq preview-id transient-999 "$(result "$r" '.[0].previewId')"
  unzip -Z1 "$r/capture/bundle.zip" > "$r/entries"
  assert_eq zip-root-directory true "$(grep -qx 'test-bench/spec.yaml' "$r/entries" && echo true || echo false)"
  assert_eq zip-dotfile true "$(grep -qx 'test-bench/skills/.hidden/file.md' "$r/entries" && echo true || echo false)"
  rm -rf "$r"
}

test_durable() {
  local mode="$1" r
  EVENT_NAME=push
  DEFAULT_SYNC_MODE="$mode"
  MOCK_RESPONSE='{"status":"UPDATED"}'
  r=$(new_sandbox "$mode")
  run_sync "$r"
  mode_upper=$(printf '%s' "$mode" | tr '[:lower:]' '[:upper:]')
  assert_eq "${mode}-mode" "syncMode=${mode_upper}" "$(field "syncMode=${mode_upper}" "$r")"
  assert_eq "${mode}-metadata" 'gitCommitSha=deadbeef' "$(field gitCommitSha=deadbeef "$r")"
  assert_eq "${mode}-status" success "$(result "$r" '.[0].status')"
  rm -rf "$r"
}

test_status_mismatch() {
  local r
  EVENT_NAME=push
  MOCK_RESPONSE='{"status":"DRAFT_PREVIEW"}'
  r=$(new_sandbox)
  run_sync "$r"
  assert_eq status-mismatch error "$(result "$r" '.[0].status')"
  rm -rf "$r"
}

test_outside_symlink() {
  local r outside
  r=$(new_sandbox)
  outside=$(mktemp)
  ln -s "$outside" "$r/repo/agents/test-bench/outside.txt"
  run_sync "$r"
  assert_eq outside-symlink-no-request MISSING "$(cat "$r/capture/url" 2>/dev/null || echo MISSING)"
  rm -rf "$r" "$outside"
}

test_preview
test_durable staged
test_durable published
test_status_mismatch
test_outside_symlink
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
