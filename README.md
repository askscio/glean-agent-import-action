# Glean Agent Sync Action

A GitHub Action that keeps your git-managed Glean agents in sync with your Glean workspace.

- **On pull requests** — creates a draft preview in Glean and posts a comment with preview links
- **On merge** — syncs updated agent definitions into Glean (staged or published) and posts run links back to the PR

## Usage

```yaml
name: Glean Agent Sync

on:
  pull_request:
    paths:
      - '.glean/agents/**'
  push:
    branches:
      - main
    paths:
      - '.glean/agents/**'
  workflow_dispatch:
    inputs:
      agent_folder:
        description: 'Specific agent folder to sync (leave blank to sync all changed)'
        required: false
      is_draft:
        description: 'Force draft preview mode even on push'
        required: false
        default: 'false'

jobs:
  sync:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0  # required for git diff to detect changed folders

      - uses: askscio/glean-agent-import-action@v1
        with:
          instance-url-fe: 'https://your-company.glean.com'
          instance-url-be: 'https://your-company-be.glean.com'
          api-token: ${{ secrets.GLEAN_API_TOKEN }}
```

> **Note:** `fetch-depth: 0` is required. The action uses `git diff` to detect which agent folders changed since the base commit.

## Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `instance-url-fe` | ✅ | — | Frontend instance URL used for preview/run links in PR comments (e.g. `https://acme.glean.com`) |
| `instance-url-be` | ✅ | — | Backend instance URL for API calls (e.g. `https://acme-be.glean.com`) |
| `api-token` | ✅ | — | Glean client API token with `AGENTS` scope |
| `agent-directory` | ❌ | `.glean/agents` | Path within the repo where agent folders live |
| `shared-root` | ❌ | `.glean/common` | Root directory for shared reusable agent resources. Changes here trigger downstream agent re-sync via symlink dependency resolution. |
| `default-sync-mode` | ❌ | `staged` | Default sync mode on push/merge: `staged` or `published`. Can be overridden per-agent via `sync-mode` in `glean-sync.yaml` |

## Outputs

| Output | Description |
|--------|-------------|
| `synced-agents` | JSON array of per-agent results: `[{agentId, agentName, agentMode, mode, message, status}]` |

## Workflow dispatch inputs

When triggered via `workflow_dispatch`, the action reads these inputs from `github.event.inputs`:

| Input | Description |
|-------|-------------|
| `agent_folder` | Sync a specific agent folder by name, skipping diff detection |
| `is_draft` | Set to `true` to force draft preview mode even on a push event |

## Agent folder structure

Each agent lives in its own subfolder under `agent-directory`. The action supports two agent types, detected automatically from the folder contents.

### Autonomous agents (`spec.yaml`)

```
.glean/agents/
└── my-agent/
    ├── spec.yaml          # Agent config: id, name, description, tools, skills, etc.
    ├── instructions.md    # Agent instructions (referenced by spec.yaml)
    └── glean-sync.yaml    # Optional — override sync-mode or message
```

`spec.yaml` example:

```yaml
id: agent-abc123
name: My Agent
description: Does something useful
tools:
  - toolProviderId: glean-search
```

### Workflow agents (`.json` spec)

```
.glean/agents/
└── my-workflow/
    ├── my-workflow.json   # Workflow spec JSON (exactly one .json file per folder)
    └── glean-sync.yaml    # Required — must contain agent-id
```

### `glean-sync.yaml` reference

```yaml
agent-id: agent-abc123    # Required for workflow agents; optional override for autonomous agents
sync-mode: staged         # Optional: "staged" (default) or "published"
message: "My release note" # Optional: version message shown in Glean (defaults to PR title or commit subject)
```

## Sync modes

| Mode | Trigger | Behaviour |
|------|---------|-----------|
| `draft_preview` | Pull request (always) | Creates a non-visible draft in Glean. Preview link posted to the PR. |
| `staged` | Push/merge (default) | Saves a new staged version pending moderator approval in Glean. |
| `published` | Push/merge (opt-in) | Immediately publishes the agent to all users. |

To publish on merge, set `default-sync-mode: published` on the action input, or set `sync-mode: published` in a specific agent's `glean-sync.yaml`.

## How it works

1. **Detect** — diffs changed files against the base SHA to find which agent folders changed. On `workflow_dispatch`, syncs all folders (or the specific folder provided via `agent_folder` input).
2. **Convert** — for autonomous agents (`spec.yaml`), converts the folder into the Glean workflow spec JSON format using `agent_converter.py`.
3. **Sync** — calls the Glean API (`POST /rest/api/v1/agents/{id}`) for each changed agent.
4. **Comment** — posts a PR comment with draft preview links (on pull requests) or sync status + run links (on push/merge).

## Shared resources (`shared-root`)

Agents can depend on shared resources (skills, sub-agents, prompts, artifacts) via symlinks. When a shared resource changes, the action automatically detects all downstream agents that depend on it and re-syncs them.

### How it works

1. Files under `shared-root` (default `.glean/common/`) are monitored for changes.
2. When a shared file changes, the action scans all agent directories for symlinks.
3. Each symlink is resolved canonically. If the resolved target is inside `shared-root`, that agent is marked as a dependent.
4. All affected agents are unioned with directly changed agents and synced in one batch.

### Repo layout example

```
.glean/
  agents/
    agent-a/
      spec.yaml
      skill.md -> ../../common/skills/foo/skill.md     # symlink dependency
    agent-b/
      spec.yaml
      bundle -> ../../common/bundles/bar/               # directory symlink
    agent-c/
      spec.yaml
      local-only.md                                     # no shared deps
  common/
    skills/foo/skill.md
    bundles/bar/config.json
```

In this layout:
- Changing `.glean/common/skills/foo/skill.md` triggers a re-sync of `agent-a`
- Changing `.glean/common/bundles/bar/config.json` triggers a re-sync of `agent-b`
- Changing both triggers a single combined sync of `agent-a` and `agent-b`
- `agent-c` is only synced when its own files change directly

### Workflow config with shared-root

```yaml
on:
  pull_request:
    paths:
      - '.glean/agents/**'
      - '.glean/common/**'      # trigger on shared resource changes too
  push:
    branches: [main]
    paths:
      - '.glean/agents/**'
      - '.glean/common/**'

jobs:
  sync:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - uses: askscio/glean-agent-import-action@v1
        with:
          instance-url-fe: 'https://your-company.glean.com'
          instance-url-be: 'https://your-company-be.glean.com'
          api-token: ${{ secrets.GLEAN_API_TOKEN }}
          shared-root: '.glean/common'
```

### Dependency contract

- Only symlink-resolved dependencies are detected (v1).
- All paths are canonicalized before comparison.
- Symlinks that resolve outside the repo workspace are rejected.
- Broken symlinks emit a warning but are not counted as dependencies.

## API token

Create a Glean client API token with the **`AGENTS`** scope and store it as a GitHub Actions secret (e.g. `GLEAN_API_TOKEN`).
