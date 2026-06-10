---
name: test-symlinked-skills
description: Shared skill for validating shared-root symlink dependency detection in the Glean agent sync action.
---

# Test Symlinked Skills

This skill lives under `.glean/common/` and is symlinked into `glean-sync-action-test-bench`.

When this file changes on a PR, the sync workflow should detect the shared-root change and re-sync the downstream agent even if nothing under `.glean/agents/` changed directly.

## Expected behavior

1. PR touches only `.glean/common/skills/example-protocol/SKILL.md`
2. `resolve-shared-deps.sh` finds the agent symlink
3. `glean-sync-action-test-bench` is included in the sync batch
4. Draft preview comment appears on the PR
