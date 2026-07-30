#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONVERTER="${SCRIPT_DIR}/../scripts/agent_converter.py"
FIXTURE_ROOT="$(mktemp -d)"
trap 'rm -rf "$FIXTURE_ROOT"' EXIT

mkdir -p "${FIXTURE_ROOT}/document-agent"
cat > "${FIXTURE_ROOT}/document-agent/spec.yaml" <<'YAML'
id: document-agent-id
name: Document agent
description: Exercises document input conversion.
instruction_file: instructions.md
trigger:
  type: INPUT_FORM
  inputFields:
    - displayName: payload
      type: TEXT
    - displayName: source_file
      type: DOCUMENT
      optional: true
YAML
printf '%s\n' 'Use the uploaded source file.' > "${FIXTURE_ROOT}/document-agent/instructions.md"

converted="$(uv run "$CONVERTER" to-json document-agent --dir "$FIXTURE_ROOT")"

jq -e '
  .schema.fields
  | map(select(.name == "source_file"))
  | length == 1
    and .[0].displayName == "source_file"
    and .[0].type.type == "DOCUMENT"
    and .[0].optional == true
' <<< "$converted" >/dev/null

echo "PASS: DOCUMENT input fields convert to workflow JSON"
