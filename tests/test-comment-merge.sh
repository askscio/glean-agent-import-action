#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMENT_SCRIPT="${SCRIPT_DIR}/../scripts/comment-merge.sh"
FE_URL="https://acme.glean.com"

PASS=0
FAIL=0

assert_contains() {
  local test_name="$1" needle="$2" haystack="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    echo "  PASS: $test_name"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $test_name (expected '$needle')"
    FAIL=$((FAIL + 1))
  fi
}

root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
mkdir -p "$root/bin" "$root/tmp"
cat > "$root/tmp/agent-sync-results.json" <<'JSON'
[
  {"agentId":"agent-published","agentName":"Published","folder":"published","mode":"published","status":"success","resultHash":"newhash0123456789"},
  {"agentId":"agent-conflict","agentName":"Conflict","folder":"conflict","mode":"published","status":"conflict","baselineHash":"oldhash0123456789","error":"stale published baseline (HTTP 409)"}
]
JSON

cat > "$root/bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  *commits/merge-sha/pulls*)
  printf '7\n'
  ;;
esac
GH
chmod +x "$root/bin/gh"

PATH="$root/bin:$PATH" \
RUNNER_TEMP="$root/tmp" \
GH_TOKEN="test-token" \
INSTANCE_URL_FE="$FE_URL" \
COMMIT_SHA="merge-sha" \
REPO="askscio/example" \
  bash "$COMMENT_SCRIPT" >/dev/null 2>&1 || true

output=$(cat "$root/tmp/agent-sync-merge-comment.md")
assert_contains "renders conflict marker" "⛔ Conflict" "$output"
assert_contains "renders conflict error" "stale published baseline (HTTP 409)" "$output"
assert_contains "renders conflict remediation" 'Pull/export the latest published version, commit `glean-sync.yaml`, re-merge.' "$output"
assert_contains "renders truncated published hash" "Published hash: newhash01234…" "$output"

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
