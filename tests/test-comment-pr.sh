#!/usr/bin/env bash
set -euo pipefail

# A PR preview must link its transient workflow, never the real agent's durable draft editor.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMENT_SCRIPT="${SCRIPT_DIR}/../scripts/comment-pr.sh"
FE_URL="https://acme.glean.com"
BE_URL="https://acme-be.glean.com"

PASS=0
FAIL=0
ERRORS=""

# ── Helpers ─────────────────────────────────────────────────────────────────

assert_contains() {
  local test_name="$1" needle="$2" haystack="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    echo "  PASS: $test_name"
    PASS=$((PASS+1))
  else
    echo "  FAIL: $test_name"
    echo "    Expected to find: $needle"
    FAIL=$((FAIL+1))
    ERRORS+="  - $test_name\n"
  fi
}

assert_not_contains() {
  local test_name="$1" needle="$2" haystack="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    echo "  FAIL: $test_name"
    echo "    Expected NOT to find: $needle"
    FAIL=$((FAIL+1))
    ERRORS+="  - $test_name\n"
  else
    echo "  PASS: $test_name"
    PASS=$((PASS+1))
  fi
}

render_comment() {
  local results="$1" root
  root=$(mktemp -d)
  mkdir -p "$root/bin" "$root/tmp"
  printf '%s' "$results" > "$root/tmp/agent-sync-results.json"

  # No existing comment to find, and the POST is a no-op.
  cat > "$root/bin/gh" <<'GH'
#!/usr/bin/env bash
exit 0
GH
  chmod +x "$root/bin/gh"

  (
    PATH="$root/bin:$PATH" \
    RUNNER_TEMP="$root/tmp" \
    GH_TOKEN="test-token" \
    INSTANCE_URL_FE="$FE_URL" \
    INSTANCE_URL_BE="$BE_URL" \
    PR_NUMBER="7" \
    REPO="askscio/example" \
      bash "$COMMENT_SCRIPT" >/dev/null 2>&1
  ) || true

  cat "$root/tmp/agent-sync-comment.md" 2>/dev/null || echo ""
  rm -rf "$root"
}

# ── Tests ───────────────────────────────────────────────────────────────────

test_preview_links_to_transient_workflow() {
  echo "Test: preview links to the transient workflow"
  local out
  out=$(render_comment '[{"agentId":"agent-123","agentName":"Test Bench","folder":"test-bench","mode":"draft_preview","previewId":"transient-999","status":"success"}]')

  assert_contains "links to the transient preview url" \
    "${FE_URL}/chat/agents/transient-999/preview" "$out"
  assert_not_contains "does not link the real agent's edit page" \
    "/chat/agents/agent-123/edit" "$out"
  assert_not_contains "does not link the real agent's preview either" \
    "/chat/agents/agent-123/preview" "$out"
  assert_contains "keeps the backend qe param" "qe=" "$out"
}

test_missing_preview_id_falls_back_to_agent() {
  echo "Test: missing previewId falls back to the real agent, never to /edit"
  local out
  out=$(render_comment '[{"agentId":"agent-123","agentName":"Test Bench","folder":"test-bench","mode":"draft_preview","previewId":"","status":"success"}]')

  assert_contains "falls back to the real agent preview url" \
    "${FE_URL}/chat/agents/agent-123/preview" "$out"
  assert_not_contains "still never links the durable draft editor" \
    "/chat/agents/agent-123/edit" "$out"
}

test_legacy_results_without_preview_id() {
  echo "Test: results predating previewId still render a link"
  local out
  out=$(render_comment '[{"agentId":"agent-123","agentName":"Test Bench","folder":"test-bench","mode":"draft_preview","status":"success"}]')

  assert_contains "falls back when the field is absent entirely" \
    "${FE_URL}/chat/agents/agent-123/preview" "$out"
  assert_not_contains "no edit link for legacy results" \
    "/chat/agents/agent-123/edit" "$out"
}

test_failed_preview_shows_error_not_link() {
  echo "Test: a failed preview surfaces the error, not a misleading link"
  local out
  out=$(render_comment '[{"agentId":"agent-123","agentName":"Test Bench","folder":"test-bench","mode":"draft_preview","status":"error","error":"HTTP 403"}]')

  assert_contains "shows the failure marker" ":x: Draft Preview" "$out"
  assert_contains "shows the error text" "HTTP 403" "$out"
  assert_not_contains "no preview link on failure" "/preview?qe=" "$out"
  assert_not_contains "no edit link on failure" "/edit?qe=" "$out"
  assert_contains "offers a retry command" "/glean-retry test-bench" "$out"
}

test_mixed_results_only_link_successes() {
  echo "Test: mixed results link only the successful preview"
  local out
  out=$(render_comment '[{"agentId":"agent-ok","agentName":"Good","folder":"good","mode":"draft_preview","previewId":"transient-ok","status":"success"},{"agentId":"agent-bad","agentName":"Bad","folder":"bad","mode":"draft_preview","status":"error","error":"HTTP 500"}]')

  assert_contains "links the successful transient preview" \
    "${FE_URL}/chat/agents/transient-ok/preview" "$out"
  assert_contains "reports the failing agent's error" "HTTP 500" "$out"
  assert_not_contains "no link for the failed agent" \
    "/chat/agents/agent-bad" "$out"
}

# ── Runner ──────────────────────────────────────────────────────────────────

test_preview_links_to_transient_workflow
echo ""
test_missing_preview_id_falls_back_to_agent
echo ""
test_legacy_results_without_preview_id
echo ""
test_failed_preview_shows_error_not_link
echo ""
test_mixed_results_only_link_successes

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
