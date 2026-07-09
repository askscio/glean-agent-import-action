#!/usr/bin/env bash
set -euo pipefail

# Integration tests for detect-changes.sh
# Creates temporary git fixture repos and validates which agent folders are
# reported as "changed" for pull_request / push / workflow_dispatch events.
# In particular: a base-branch advance or a messy rebase must not misreport
# agents the branch never actually changed (which would draft-sync and
# misattribute unrelated agents to the PR author).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DETECT_SCRIPT="${SCRIPT_DIR}/../scripts/detect-changes.sh"

PASS=0
FAIL=0
ERRORS=""

# ── Helpers ─────────────────────────────────────────────────────────────────

assert_folders() {
  local test_name="$1" expected="$2" actual="$3"
  local exp act
  exp=$(echo "$expected" | jq -S -c '.')
  act=$(echo "${actual:-[]}" | jq -S -c '.')
  if [ "$exp" = "$act" ]; then
    echo "  PASS: $test_name"
    PASS=$((PASS+1))
  else
    echo "  FAIL: $test_name"
    echo "    Expected: $exp"
    echo "    Actual:   $act"
    FAIL=$((FAIL+1))
    ERRORS+="  - $test_name\n"
  fi
}

new_repo() {
  local d
  d=$(mktemp -d)
  git -C "$d" init -q -b main
  git -C "$d" config user.email test@example.com
  git -C "$d" config user.name test
  echo "$d"
}

# Write an agent's spec and commit it. <repo> <agent> <content> <msg>
commit_agent() {
  local repo="$1" agent="$2" content="$3" msg="$4"
  mkdir -p "$repo/agents/$agent"
  printf '%s\n' "$content" > "$repo/agents/$agent/spec.yaml"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m "$msg"
}

# Run detect-changes.sh in a fixture repo and echo the resolved `folders` JSON.
# Reads EVENT_NAME / PR_BASE_SHA / PUSH_BEFORE_SHA from the environment.
run_detect() {
  local repo="$1" out
  out=$(mktemp)
  (
    cd "$repo" &&
    GITHUB_OUTPUT="$out" AGENT_DIR="agents" \
      EVENT_NAME="$EVENT_NAME" PR_BASE_SHA="${PR_BASE_SHA:-}" PUSH_BEFORE_SHA="${PUSH_BEFORE_SHA:-}" \
      bash "$DETECT_SCRIPT" >/dev/null 2>&1
  ) || true
  awk '/^folders<</{getline; print; exit}' "$out"
}

# ── Tests ───────────────────────────────────────────────────────────────────

test_base_advanced_after_branch() {
  echo "Test: base branch advanced after branch point"
  local r tip got
  r=$(new_repo)
  commit_agent "$r" existing base "base"
  git -C "$r" checkout -q -b feature
  commit_agent "$r" feature_agent f "feat: feature_agent"
  git -C "$r" checkout -q main
  commit_agent "$r" late_agent l "master adds late_agent (unrelated)"
  tip=$(git -C "$r" rev-parse HEAD)
  git -C "$r" checkout -q feature
  got=$(EVENT_NAME=pull_request PR_BASE_SHA="$tip" run_detect "$r")
  assert_folders "base advance excludes the unrelated agent" '["feature_agent"]' "$got"
  rm -rf "$r"
}

test_rebase_duplicate_excluded() {
  echo "Test: rebase duplicates a base agent commit (identical content)"
  local r base0 tip got
  r=$(new_repo)
  commit_agent "$r" existing base "base"
  base0=$(git -C "$r" rev-parse HEAD)
  commit_agent "$r" M content-M "master adds M"
  tip=$(git -C "$r" rev-parse HEAD)
  # Branch predates M; a messy rebase re-applies M with identical content (new SHA)
  # plus a genuine change P.
  git -C "$r" checkout -q -b feature "$base0"
  commit_agent "$r" M content-M "rebase dup of M (new sha, same content)"
  commit_agent "$r" P p "real change P"
  got=$(EVENT_NAME=pull_request PR_BASE_SHA="$tip" run_detect "$r")
  assert_folders "rebase-duplicated agent excluded" '["P"]' "$got"
  rm -rf "$r"
}

test_rebase_duplicate_plus_genuine_edit() {
  echo "Test: rebase-duplicated agent that is ALSO genuinely edited"
  local r base0 tip got
  r=$(new_repo)
  commit_agent "$r" existing base "base"
  base0=$(git -C "$r" rev-parse HEAD)
  commit_agent "$r" M content-M "master adds M"
  tip=$(git -C "$r" rev-parse HEAD)
  git -C "$r" checkout -q -b feature "$base0"
  commit_agent "$r" M content-M "rebase dup of M"
  commit_agent "$r" P p "real change P"
  commit_agent "$r" M content-M-EDITED "genuine edit to M"
  got=$(EVENT_NAME=pull_request PR_BASE_SHA="$tip" run_detect "$r")
  assert_folders "genuine edit to a duplicated agent is still detected" '["M","P"]' "$got"
  rm -rf "$r"
}

test_pr_edits_existing_agent() {
  echo "Test: PR edits an existing agent"
  local r base got
  r=$(new_repo)
  commit_agent "$r" a v1 "base"
  base=$(git -C "$r" rev-parse HEAD)
  git -C "$r" checkout -q -b feat
  commit_agent "$r" a v2 "edit a"
  got=$(EVENT_NAME=pull_request PR_BASE_SHA="$base" run_detect "$r")
  assert_folders "edited agent detected" '["a"]' "$got"
  rm -rf "$r"
}

test_push_adds_agent() {
  echo "Test: push adds an agent"
  local r before got
  r=$(new_repo)
  commit_agent "$r" a v1 "base"
  before=$(git -C "$r" rev-parse HEAD)
  commit_agent "$r" b z "add b"
  got=$(EVENT_NAME=push PUSH_BEFORE_SHA="$before" run_detect "$r")
  assert_folders "added agent detected on push" '["b"]' "$got"
  rm -rf "$r"
}

test_docs_only_push() {
  echo "Test: docs-only push changes no agents"
  local r before got
  r=$(new_repo)
  commit_agent "$r" a v1 "base"
  before=$(git -C "$r" rev-parse HEAD)
  echo "hi" > "$r/README.md"
  git -C "$r" add -A
  git -C "$r" commit -q -m "docs"
  got=$(EVENT_NAME=push PUSH_BEFORE_SHA="$before" run_detect "$r")
  assert_folders "no agents reported for docs-only change" '[]' "$got"
  rm -rf "$r"
}

test_workflow_dispatch_syncs_all() {
  echo "Test: workflow_dispatch syncs all present agents"
  local r got
  r=$(new_repo)
  commit_agent "$r" a v1 "add a"
  commit_agent "$r" b v1 "add b"
  got=$(EVENT_NAME=workflow_dispatch run_detect "$r")
  assert_folders "all agents reported on dispatch" '["a","b"]' "$got"
  rm -rf "$r"
}

# ── Runner ──────────────────────────────────────────────────────────────────

test_base_advanced_after_branch
echo ""
test_rebase_duplicate_excluded
echo ""
test_rebase_duplicate_plus_genuine_edit
echo ""
test_pr_edits_existing_agent
echo ""
test_push_adds_agent
echo ""
test_docs_only_push
echo ""
test_workflow_dispatch_syncs_all

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
