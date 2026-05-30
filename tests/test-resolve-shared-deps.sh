#!/usr/bin/env bash
set -euo pipefail

# Integration tests for resolve-shared-deps.sh
# Creates temporary fixture repos and validates dependency resolution.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESOLVE_SCRIPT="${SCRIPT_DIR}/../scripts/resolve-shared-deps.sh"

PASS=0
FAIL=0
ERRORS=""

# ── Helpers ─────────────────────────────────────────────────────────────────

setup_fixture() {
  local tmpdir
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/.glean/agents" "$tmpdir/.glean/common"
  echo "$tmpdir"
}

cleanup_fixture() {
  rm -rf "$1"
}

assert_json_eq() {
  local test_name="$1"
  local expected="$2"
  local actual="$3"

  # Normalize both by sorting arrays
  local exp_sorted act_sorted
  exp_sorted=$(echo "$expected" | jq -S -c '.')
  act_sorted=$(echo "$actual" | jq -S -c '.')

  if [ "$exp_sorted" = "$act_sorted" ]; then
    echo "  PASS: $test_name"
    PASS=$((PASS+1))
  else
    echo "  FAIL: $test_name"
    echo "    Expected: $exp_sorted"
    echo "    Actual:   $act_sorted"
    FAIL=$((FAIL+1))
    ERRORS+="  - $test_name\n"
  fi
}

assert_exit_code() {
  local test_name="$1"
  local expected="$2"
  local actual="$3"

  if [ "$expected" = "$actual" ]; then
    echo "  PASS: $test_name"
    PASS=$((PASS+1))
  else
    echo "  FAIL: $test_name (expected exit $expected, got $actual)"
    FAIL=$((FAIL+1))
    ERRORS+="  - $test_name\n"
  fi
}

# ── Test 1: File symlink exact match ────────────────────────────────────────

test_file_symlink_exact_match() {
  echo "Test 1: File symlink exact match"
  local fix
  fix=$(setup_fixture)

  # Create shared content
  mkdir -p "$fix/.glean/common/skills/foo"
  echo "skill content" > "$fix/.glean/common/skills/foo/skill.md"

  # Create agent-a with symlink to shared file
  mkdir -p "$fix/.glean/agents/agent-a"
  ln -s "../../common/skills/foo/skill.md" "$fix/.glean/agents/agent-a/skill.md"

  # Create agent-b with no shared deps
  mkdir -p "$fix/.glean/agents/agent-b"
  echo "local content" > "$fix/.glean/agents/agent-b/local.md"

  local result
  result=$(echo ".glean/common/skills/foo/skill.md" | \
    WORKSPACE_ROOT="$fix" AGENT_DIR=".glean/agents" SHARED_ROOT=".glean/common" \
    bash "$RESOLVE_SCRIPT" 2>/dev/null)

  assert_json_eq "agent-a affected by exact file match" '["agent-a"]' "$result"

  cleanup_fixture "$fix"
}

# ── Test 2: Directory symlink ───────────────────────────────────────────────

test_directory_symlink() {
  echo "Test 2: Directory symlink — file change under linked directory"
  local fix
  fix=$(setup_fixture)

  mkdir -p "$fix/.glean/common/bundles/bar"
  echo "config" > "$fix/.glean/common/bundles/bar/config.json"

  mkdir -p "$fix/.glean/agents/agent-b"
  ln -s "../../common/bundles/bar" "$fix/.glean/agents/agent-b/bundle"

  local result
  result=$(echo ".glean/common/bundles/bar/config.json" | \
    WORKSPACE_ROOT="$fix" AGENT_DIR=".glean/agents" SHARED_ROOT=".glean/common" \
    bash "$RESOLVE_SCRIPT" 2>/dev/null)

  assert_json_eq "agent-b affected by file change under directory symlink" '["agent-b"]' "$result"

  cleanup_fixture "$fix"
}

# ── Test 3: Multiple agents affected ───────────────────────────────────────

test_multiple_agents_affected() {
  echo "Test 3: Multiple agents affected by one shared change"
  local fix
  fix=$(setup_fixture)

  mkdir -p "$fix/.glean/common/skills/shared"
  echo "shared skill" > "$fix/.glean/common/skills/shared/skill.md"

  mkdir -p "$fix/.glean/agents/agent-a"
  ln -s "../../common/skills/shared/skill.md" "$fix/.glean/agents/agent-a/skill.md"

  mkdir -p "$fix/.glean/agents/agent-b"
  ln -s "../../common/skills/shared/skill.md" "$fix/.glean/agents/agent-b/skill.md"

  mkdir -p "$fix/.glean/agents/agent-c"
  echo "no deps" > "$fix/.glean/agents/agent-c/local.md"

  local result
  result=$(echo ".glean/common/skills/shared/skill.md" | \
    WORKSPACE_ROOT="$fix" AGENT_DIR=".glean/agents" SHARED_ROOT=".glean/common" \
    bash "$RESOLVE_SCRIPT" 2>/dev/null)

  assert_json_eq "agent-a and agent-b affected" '["agent-a","agent-b"]' "$result"

  cleanup_fixture "$fix"
}

# ── Test 4: No dependents ──────────────────────────────────────────────────

test_no_dependents() {
  echo "Test 4: Shared file changes but no agents depend on it"
  local fix
  fix=$(setup_fixture)

  mkdir -p "$fix/.glean/common/orphan"
  echo "orphan" > "$fix/.glean/common/orphan/data.txt"

  mkdir -p "$fix/.glean/agents/agent-a"
  echo "local only" > "$fix/.glean/agents/agent-a/local.md"

  local result
  result=$(echo ".glean/common/orphan/data.txt" | \
    WORKSPACE_ROOT="$fix" AGENT_DIR=".glean/agents" SHARED_ROOT=".glean/common" \
    bash "$RESOLVE_SCRIPT" 2>/dev/null)

  assert_json_eq "empty array when no dependents" '[]' "$result"

  cleanup_fixture "$fix"
}

# ── Test 5: No changed files ──────────────────────────────────────────────

test_no_changed_files() {
  echo "Test 5: Empty input produces empty output"
  local fix
  fix=$(setup_fixture)

  local result
  result=$(echo "" | \
    WORKSPACE_ROOT="$fix" AGENT_DIR=".glean/agents" SHARED_ROOT=".glean/common" \
    bash "$RESOLVE_SCRIPT" 2>/dev/null)

  assert_json_eq "empty array when no changes" '[]' "$result"

  cleanup_fixture "$fix"
}

# ── Test 6: Broken symlink warns but doesn't count ─────────────────────────

test_broken_symlink() {
  echo "Test 6: Broken symlink produces warning, not a dependency"
  local fix
  fix=$(setup_fixture)

  mkdir -p "$fix/.glean/common/skills/valid"
  echo "valid" > "$fix/.glean/common/skills/valid/skill.md"

  mkdir -p "$fix/.glean/agents/agent-broken"
  ln -s "../../common/nonexistent/file.md" "$fix/.glean/agents/agent-broken/broken-link.md"

  mkdir -p "$fix/.glean/agents/agent-valid"
  ln -s "../../common/skills/valid/skill.md" "$fix/.glean/agents/agent-valid/skill.md"

  local result stderr_output
  stderr_output=$(mktemp)
  result=$(echo ".glean/common/skills/valid/skill.md" | \
    WORKSPACE_ROOT="$fix" AGENT_DIR=".glean/agents" SHARED_ROOT=".glean/common" \
    bash "$RESOLVE_SCRIPT" 2>"$stderr_output")

  assert_json_eq "only agent-valid affected (broken link ignored)" '["agent-valid"]' "$result"

  if grep -q "Broken symlink" "$stderr_output"; then
    echo "  PASS: Broken symlink warning emitted"
    PASS=$((PASS+1))
  else
    echo "  FAIL: Expected broken symlink warning in stderr"
    FAIL=$((FAIL+1))
    ERRORS+="  - broken symlink warning\n"
  fi

  rm -f "$stderr_output"
  cleanup_fixture "$fix"
}

# ── Test 7: Symlink outside repo rejected ──────────────────────────────────

test_symlink_escapes_repo() {
  echo "Test 7: Symlink escaping repo is rejected"
  local fix
  fix=$(setup_fixture)

  local outside
  outside=$(mktemp -d)
  echo "external" > "$outside/external.md"

  mkdir -p "$fix/.glean/agents/agent-escape"
  ln -s "$outside/external.md" "$fix/.glean/agents/agent-escape/escape.md"

  mkdir -p "$fix/.glean/common/skills"
  echo "content" > "$fix/.glean/common/skills/skill.md"

  local exit_code=0
  echo ".glean/common/skills/skill.md" | \
    WORKSPACE_ROOT="$fix" AGENT_DIR=".glean/agents" SHARED_ROOT=".glean/common" \
    bash "$RESOLVE_SCRIPT" 2>/dev/null || exit_code=$?

  assert_exit_code "rejects symlink escaping repo" "1" "$exit_code"

  rm -rf "$outside"
  cleanup_fixture "$fix"
}

# ── Test 8: Roots overlap rejected ─────────────────────────────────────────

test_roots_overlap() {
  echo "Test 8: Overlapping roots are rejected"
  local fix
  fix=$(setup_fixture)
  mkdir -p "$fix/.glean/agents/common"

  local exit_code=0
  echo ".glean/agents/common/file.md" | \
    WORKSPACE_ROOT="$fix" AGENT_DIR=".glean/agents" SHARED_ROOT=".glean/agents/common" \
    bash "$RESOLVE_SCRIPT" 2>/dev/null || exit_code=$?

  assert_exit_code "rejects nested shared_root" "1" "$exit_code"

  cleanup_fixture "$fix"
}

# ── Test 9: Nested symlinks (chain resolution) ─────────────────────────────

test_nested_symlinks() {
  echo "Test 9: Nested symlinks resolved through chain"
  local fix
  fix=$(setup_fixture)

  mkdir -p "$fix/.glean/common/skills/deep"
  echo "deep skill" > "$fix/.glean/common/skills/deep/skill.md"

  # Create an intermediate symlink in common itself
  ln -s "skills/deep" "$fix/.glean/common/deep-alias"

  mkdir -p "$fix/.glean/agents/agent-chain"
  ln -s "../../common/deep-alias/skill.md" "$fix/.glean/agents/agent-chain/skill.md"

  local result
  result=$(echo ".glean/common/skills/deep/skill.md" | \
    WORKSPACE_ROOT="$fix" AGENT_DIR=".glean/agents" SHARED_ROOT=".glean/common" \
    bash "$RESOLVE_SCRIPT" 2>/dev/null)

  assert_json_eq "agent-chain affected through symlink chain" '["agent-chain"]' "$result"

  cleanup_fixture "$fix"
}

# ── Test 10: Multiple shared changes, multiple agents ──────────────────────

test_multiple_changes_multiple_agents() {
  echo "Test 10: Multiple shared changes affecting different agents"
  local fix
  fix=$(setup_fixture)

  mkdir -p "$fix/.glean/common/skills/foo"
  echo "foo skill" > "$fix/.glean/common/skills/foo/skill.md"
  mkdir -p "$fix/.glean/common/bundles/bar"
  echo "bar config" > "$fix/.glean/common/bundles/bar/config.json"

  mkdir -p "$fix/.glean/agents/agent-a"
  ln -s "../../common/skills/foo/skill.md" "$fix/.glean/agents/agent-a/skill.md"

  mkdir -p "$fix/.glean/agents/agent-b"
  ln -s "../../common/bundles/bar" "$fix/.glean/agents/agent-b/bundle"

  local result
  result=$(printf '.glean/common/skills/foo/skill.md\n.glean/common/bundles/bar/config.json\n' | \
    WORKSPACE_ROOT="$fix" AGENT_DIR=".glean/agents" SHARED_ROOT=".glean/common" \
    bash "$RESOLVE_SCRIPT" 2>/dev/null)

  assert_json_eq "both agents affected by respective changes" '["agent-a","agent-b"]' "$result"

  cleanup_fixture "$fix"
}

# ── Test 11: Agent with symlink to non-shared-root location ────────────────

test_non_shared_symlink_ignored() {
  echo "Test 11: Symlinks outside shared_root are not treated as dependencies"
  local fix
  fix=$(setup_fixture)

  mkdir -p "$fix/.glean/common/skills"
  echo "skill" > "$fix/.glean/common/skills/skill.md"
  mkdir -p "$fix/other-dir"
  echo "other" > "$fix/other-dir/file.md"

  mkdir -p "$fix/.glean/agents/agent-a"
  ln -s "../../other-dir/file.md" "$fix/.glean/agents/agent-a/other.md"

  local result
  result=$(echo ".glean/common/skills/skill.md" | \
    WORKSPACE_ROOT="$fix" AGENT_DIR=".glean/agents" SHARED_ROOT=".glean/common" \
    bash "$RESOLVE_SCRIPT" 2>/dev/null)

  assert_json_eq "agent with non-shared symlink not affected" '[]' "$result"

  cleanup_fixture "$fix"
}

# ── Run all tests ──────────────────────────────────────────────────────────

echo "========================================="
echo "  resolve-shared-deps.sh test suite"
echo "========================================="
echo ""

test_file_symlink_exact_match
echo ""
test_directory_symlink
echo ""
test_multiple_agents_affected
echo ""
test_no_dependents
echo ""
test_no_changed_files
echo ""
test_broken_symlink
echo ""
test_symlink_escapes_repo
echo ""
test_roots_overlap
echo ""
test_nested_symlinks
echo ""
test_multiple_changes_multiple_agents
echo ""
test_non_shared_symlink_ignored

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
