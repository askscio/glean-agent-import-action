# Git-managed Glean agents (dogfood)

## Layout

```
.glean/
  agents/          # one folder per agent
  common/          # shared skills, prompts, bundles (symlinked from agents)
```

## Shared dependencies

Link shared resources into your agent folder with symlinks:

```bash
mkdir -p .glean/agents/my-agent/skills
ln -s ../../../common/skills/example-protocol .glean/agents/my-agent/skills/example-protocol
```

When `.glean/common/**` changes on a PR, the sync workflow re-syncs all agents that symlink to the changed files.

## Add your agent

Create `.glean/agents/<your-agent>/` with at least:

- `spec.yaml` — agent config (`id`, `name`, `trigger`, etc.)
- `instructions.md` — referenced by `instruction_file` in spec.yaml
- optional `glean-sync.yaml` — override `sync-mode` or `message`

Open a PR touching `.glean/agents/**` or `.glean/common/**` to get a draft preview comment.
