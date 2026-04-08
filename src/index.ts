import * as core from '@actions/core'
import * as github from '@actions/github'
import * as fs from 'fs'
import * as path from 'path'

interface ExportPackage {
  serverVersion?: string
  rootWorkflow?: {
    name?: string
    schema?: {
      steps?: unknown[]
    }
  }
  subagents?: unknown[]
}

interface ImportResponse {
  agentId?: string
  stagedUrl?: string
  status?: 'created' | 'updated' | 'error'
}

async function run(): Promise<void> {
  try {
    const apiKey = core.getInput('api_key', { required: true })
    const gleanUrl = core.getInput('glean_url', { required: true }).replace(/\/$/, '')
    const agentFile = core.getInput('agent_file', { required: true })
    const deployMode = core.getInput('deploy_mode') || 'staged'
    const dryRun = core.getInput('dry_run') === 'true'
    const commitMessage = core.getInput('commit_message') || github.context.sha || ''

    const agentFilePath = path.resolve(agentFile)
    if (!fs.existsSync(agentFilePath)) {
      core.setFailed(`Agent file not found: ${agentFilePath}`)
      return
    }

    let exportPackage: ExportPackage
    try {
      const raw = fs.readFileSync(agentFilePath, 'utf-8')
      exportPackage = JSON.parse(raw) as ExportPackage
    } catch (e) {
      core.setFailed(`Failed to parse agent file as JSON: ${e}`)
      return
    }

    if (!exportPackage.rootWorkflow) {
      core.setFailed('Invalid agent file: missing rootWorkflow')
      return
    }
    if (!exportPackage.rootWorkflow.name) {
      core.setFailed('Invalid agent file: rootWorkflow.name is required')
      return
    }
    if (!exportPackage.rootWorkflow.schema?.steps || exportPackage.rootWorkflow.schema.steps.length === 0) {
      core.setFailed('Invalid agent file: rootWorkflow.schema must contain at least one step')
      return
    }

    core.info(`Agent: ${exportPackage.rootWorkflow.name}`)
    core.info(`Deploy mode: ${deployMode}`)

    // TODO: finalize the agent import endpoint handler
    if (dryRun) {
      core.info('Dry run — skipping HTTP call')
      core.info(`Would POST to: ${gleanUrl}/rest/v1/agents/import`)
      core.setOutput('status', 'dry_run')
      return
    }

    const response = await fetch(`${gleanUrl}/rest/v1/agents/import`, {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${apiKey}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ definition: exportPackage, deployMode, commitMessage }),
    })

    if (!response.ok) {
      const errorBody = await response.text()
      core.setFailed(`Import failed [${response.status}]: ${errorBody}`)
      core.setOutput('status', 'error')
      return
    }

    const result = (await response.json()) as ImportResponse
    core.setOutput('agent_id', result.agentId ?? '')
    core.setOutput('staged_url', result.stagedUrl ?? '')
    core.setOutput('status', result.status ?? 'created')
    core.info(`Import successful — status: ${result.status}`)
    if (result.stagedUrl) core.info(`Staged URL: ${result.stagedUrl}`)
  } catch (error) {
    core.setFailed(`Unexpected error: ${error}`)
  }
}

run()
