# Glean Agent Import Action

A GitHub Action to import a Glean workflow agent from your CI pipeline into a Glean workspace.

[![GitHub Marketplace](https://img.shields.io/badge/Marketplace-Glean%20Agent%20Import-blue?logo=github)](https://github.com/marketplace/actions/glean-agent-import)

---

## Overview

This action takes an exported Glean agent JSON file from your repository and pushes it to your Glean workspace via the Import API. It supports both `staged` (pending moderator approval) and `live` (immediate publish) deploy modes.

---

## Prerequisites

- A Glean workspace with the Agent Import feature enabled
- A Glean Import API key generated from your workspace admin settings
- An exported agent JSON file committed to your repository (generated via Glean's agent export)

---

## Usage

```yaml
- name: Import Glean Agent
  uses: askscio/glean-agent-import-action@v1
  with:
    api_key: ${{ secrets.GLEAN_IMPORT_KEY }}
    glean_url: 'https://acme.glean.com'
    agent_file: 'agents/my-agent.json'
```

---

## Inputs

| Input | Required | Default | Description |
|:------|:--------:|:-------:|:------------|
| `api_key` | ✅ | — | Glean Import API key. Always store as a GitHub secret. |
| `glean_url` | ✅ | — | Your Glean instance URL, e.g. `https://acme.glean.com` |
| `agent_file` | ✅ | — | Path to the exported agent JSON file in your repository |
| `deploy_mode` | ❌ | `staged` | `staged` (pending approval) or `live` (immediate publish) |
| `commit_message` | ❌ | Git commit SHA | Message attached to this import version in Glean |

---

## Outputs

| Output | Description |
|:-------|:------------|
| `agent_id` | The Glean workflow agent ID that was created or updated |
| `staged_url` | Direct link to the staged version in Glean (only when `deploy_mode: staged`) |
| `status` | `created`, `updated`, or `error` |

---

## Examples

### Basic — Push on merge to main

```yaml
name: Deploy Glean Agent

on:
  push:
    branches:
      - main
    paths:
      - 'agents/**'

jobs:
  import-agent:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Import Glean Agent
        uses: askscio/glean-agent-import-action@v1
        with:
          api_key: ${{ secrets.GLEAN_IMPORT_KEY }}
          glean_url: 'https://acme.glean.com'
          agent_file: 'agents/my-agent.json'
          deploy_mode: 'staged'
          commit_message: 'Deployed from ${{ github.sha }}'
```

---

### Multi-agent — Import all agents in a directory

```yaml
name: Deploy All Glean Agents

on:
  push:
    branches:
      - main

jobs:
  import-agents:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        agent:
          - agents/support-agent.json
          - agents/onboarding-agent.json
          - agents/hr-agent.json
    steps:
      - uses: actions/checkout@v4

      - name: Import ${{ matrix.agent }}
        uses: askscio/glean-agent-import-action@v1
        with:
          api_key: ${{ secrets.GLEAN_IMPORT_KEY }}
          glean_url: 'https://acme.glean.com'
          agent_file: ${{ matrix.agent }}
          deploy_mode: 'staged'
```

---

### PR preview — Stage on PR, publish on merge

```yaml
name: Glean Agent CI

on:
  pull_request:
    paths: ['agents/**']
  push:
    branches: [main]
    paths: ['agents/**']

jobs:
  import-agent:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Import Agent
        uses: askscio/glean-agent-import-action@v1
        with:
          api_key: ${{ secrets.GLEAN_IMPORT_KEY }}
          glean_url: 'https://acme.glean.com'
          agent_file: 'agents/my-agent.json'
          deploy_mode: ${{ github.event_name == 'push' && 'live' || 'staged' }}
```

---

## Setting Up Your API Key

1. Navigate to **Workspace Admin → Integrations → Agent Import** in your Glean instance
2. Click **Generate Import Key**
3. Copy the key and add it to your GitHub repository:
   - Go to **Settings → Secrets and variables → Actions**
   - Click **New repository secret**
   - Name: `GLEAN_IMPORT_KEY`, Value: paste the key
4. Never commit the key directly to your repository

---

## Agent File Format

The `agent_file` should be an exported Glean agent JSON, generated from the Glean agent builder's export functionality. The file structure looks like:

```json
{
  "serverVersion": "1.0",
  "rootWorkflow": {
    "name": "My Agent",
    "schema": {
      "trigger": { "type": "INPUT_FORM" },
      "steps": [ ... ]
    },
    "icon": { "name": "box", "backgroundColor": "#000000" }
  }
}
```

> **Note:** Sub-agents are not supported in the current version. Only the `rootWorkflow` is imported.

---

## Deploy Modes

| Mode | Behaviour |
|:-----|:----------|
| `staged` | Agent is pushed as a staged version pending moderator review. A `staged_url` is returned for the reviewer to inspect and publish. |
| `live` | Agent is published immediately without a moderation step. Requires the API key to have publish permissions. |

---

## Error Handling

The action exits with a non-zero code on:

| Condition | Exit Code |
|:----------|:---------:|
| Invalid or missing API key | `1` |
| Malformed agent JSON | `1` |
| Glean instance unreachable | `1` |
| Validation failure (e.g. missing steps) | `1` |
| Successful import | `0` |

---

## Versioning

This action follows semantic versioning. Pin to a major version tag for stability:

```yaml
uses: askscio/glean-agent-import-action@v1   # recommended
uses: askscio/glean-agent-import-action@v1.2.0  # pin to exact version
```

---

## Contributing

This action is maintained by the Glean engineering team. For bugs or feature requests, open an issue in this repository.

---

## License

Apache 2.0 — see [LICENSE](./LICENSE)
