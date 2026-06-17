#!/usr/bin/env python3
# /// script
# requires-python = ">=3.12"
# dependencies = ["pyyaml", "aiofiles"]
# ///
"""
Bidirectional converter between agents folder representation and workflow spec JSON

Usage:
    uv run agent_converter.py to-json <agent_name> --dir /path/to/agents [-o out.json]
    uv run agent_converter.py to-folder input.json --dir /path/to/output
"""

import argparse
import asyncio
import json
import os
from pathlib import Path
import sys
from typing import Any

import aiofiles
import aiofiles.os
import yaml

DEFAULT_AGENTS_ROOT = Path.cwd()

SPEC_FILENAME = 'spec.yaml'
INSTRUCTIONS_FILENAME = 'instructions.md'
SKILL_FILENAME = 'SKILL.md'

GLEAN_SEARCH_ACTION_ID = 'Glean Search'

CHAT_MESSAGE_TRIGGER = 'CHAT_MESSAGE'
INPUT_FORM_TRIGGER = 'INPUT_FORM'
INPUT_FIELD_TYPES = {'TEXT', 'SELECT', 'DATE'}


def convert_input_field_to_json(field: dict) -> dict:
    """Convert a `trigger.inputFields[i]` spec.yaml entry to the workflow JSON shape.

    The platform persists `displayName` verbatim as the field's internal `name`,
    so both keys carry the same string in the JSON.
    """
    display_name = (field.get('displayName') or field.get('name') or '').strip()
    field_type = field.get('type', 'TEXT')
    if field_type not in INPUT_FIELD_TYPES:
        raise ValueError(
            f'inputFields[{display_name!r}].type must be one of {sorted(INPUT_FIELD_TYPES)}, got {field_type!r}'
        )

    wf_field: dict[str, Any] = {
        'name': display_name,
        'displayName': display_name,
        'type': {'type': field_type},
    }
    if description := field.get('description'):
        wf_field['description'] = description
    if (default_value := field.get('defaultValue')) is not None:
        wf_field['defaultValue'] = default_value
    if field.get('optional'):
        wf_field['optional'] = True
    if options := field.get('options'):
        wf_field['options'] = [
            {'value': opt['value'], 'label': opt['label']} if opt.get('label') else {'value': opt['value']}
            for opt in options
        ]
    return wf_field


def convert_input_field_to_spec(field: dict) -> dict:
    """Convert a workflow JSON `schema.fields[i]` entry to the spec.yaml inputField entry."""
    display_name = field.get('displayName') or field.get('name') or ''
    type_obj = field.get('type')
    field_type = (
        type_obj.get('type', 'TEXT')
        if isinstance(type_obj, dict)
        else (type_obj if isinstance(type_obj, str) else 'TEXT')
    )

    out: dict[str, Any] = {'displayName': display_name, 'type': field_type}
    if description := field.get('description'):
        out['description'] = description
    if (default_value := field.get('defaultValue')) is not None:
        out['defaultValue'] = default_value
    if field.get('optional'):
        out['optional'] = True
    if options := field.get('options'):
        out['options'] = [
            {'value': opt['value'], 'label': opt['label']} if opt.get('label') else {'value': opt['value']}
            for opt in options
        ]
    return out


def _glean_search_config_to_action(glean_search_config: dict | None) -> dict | None:
    """Convert a flat spec.yaml gleanSearchConfig block into the JSON action shape.

    Three states are distinguished:
      • None (key absent from spec.yaml) → return None; no Glean Search action.
      • {} (key present, empty)          → emit action with empty inclusions →
                                            agent has unrestricted company-knowledge access.
      • populated dict                   → emit action with the listed restrictions.
    """
    if glean_search_config is None:
        return None
    inclusions: dict[str, Any] = {}
    datasource_instances = glean_search_config.get('datasourceInstances')
    if datasource_instances:
        inclusions['datasourceInstances'] = list(datasource_instances)
    urls = glean_search_config.get('urls')
    if urls:
        inclusions['urls'] = list(urls)
    return {
        'actionId': GLEAN_SEARCH_ACTION_ID,
        'gleanSearchConfig': {'inclusions': inclusions},
    }


def _extract_model_from_file(model: dict | None) -> dict:
    if not model:
        return {}
    fields: dict[str, Any] = {}
    if 'name' in model and model['name'] is not None:
        fields['modelSetId'] = model['name']
    if 'mode' in model and model['mode'] is not None:
        fields['llmMode'] = model['mode']
    if 'autoUpgrade' in model and model['autoUpgrade'] is not None:
        fields['autoUpgradeModel'] = bool(model['autoUpgrade'])
    return fields


def _extract_model_from_json(config: dict) -> dict | None:
    block: dict[str, Any] = {}
    if 'modelSetId' in config and config['modelSetId'] is not None:
        block['name'] = config['modelSetId']
    if 'llmMode' in config and config['llmMode'] is not None:
        block['mode'] = config['llmMode']
    if 'autoUpgradeModel' in config and config['autoUpgradeModel'] is not None:
        block['autoUpgrade'] = bool(config['autoUpgradeModel'])
    return block or None


def _validate_model_selection(agent_config: dict) -> None:
    """Require the agent and every subagent to either pin a model set (`model.name`) or enable
    auto-upgrade (`model.autoUpgrade`), so the executor always has a model to run with."""

    def _require(config: dict, label: str) -> None:
        if config.get('modelSetId'):
            return
        if 'autoUpgradeModel' in config and not config['autoUpgradeModel']:
            raise ValueError(f'{label} must specify a model (model.name) or enable auto-upgrade (model.autoUpgrade)')

    _require(agent_config, 'agent')
    for subagent in agent_config.get('subagents', []):
        _require(subagent, f'subagent {subagent.get("id", "")!r}')


def _extract_glean_search_config(actions: list[dict]) -> dict | None:
    """Find the Glean Search action and return its inclusions flattened for spec.yaml.

    Returns:
      • None       — no Glean Search action present (caller omits the key).
      • {}         — action present with no restrictions (caller emits `gleanSearchConfig: {}`).
      • populated  — action present with restrictions.
    """
    for action in actions:
        if action.get('actionId') != GLEAN_SEARCH_ACTION_ID:
            continue
        inclusions = action.get('gleanSearchConfig', {}).get('inclusions') or {}
        flat: dict[str, Any] = {}
        if inclusions.get('datasourceInstances'):
            flat['datasourceInstances'] = list(inclusions['datasourceInstances'])
        if inclusions.get('urls'):
            flat['urls'] = list(inclusions['urls'])
        return flat
    return None


# ---------------------------------------------------------------------------
# Shared utilities
# ---------------------------------------------------------------------------


async def read_text(path: Path) -> str:
    async with aiofiles.open(path, encoding='utf-8') as f:
        return (await f.read()).strip()


async def read_yaml(path: Path) -> dict:
    async with aiofiles.open(path, encoding='utf-8') as f:
        content = await f.read()
    return yaml.safe_load(content) or {}


async def write_text(path: Path, content: str) -> None:
    await aiofiles.os.makedirs(path.parent, exist_ok=True)
    async with aiofiles.open(path, mode='w', encoding='utf-8') as f:
        await f.write(content.rstrip() + '\n')


# PyYAML defaults to flat list indentation and unquoted multiline strings.
# This custom dumper produces nested-indent lists and folded-block ('>') scalars
# for multiline values, matching the human-authored spec.yaml style.
class _IndentedDumper(yaml.Dumper):
    pass


def _indented_increase_indent(self: yaml.Dumper, flow: bool = False, indentless: bool = False) -> None:
    return yaml.Dumper.increase_indent(self, flow, False)


def _str_representer(dumper: yaml.Dumper, data: str) -> yaml.ScalarNode:
    if '\n' in data:
        return dumper.represent_scalar('tag:yaml.org,2002:str', data, style='>')
    return dumper.represent_scalar('tag:yaml.org,2002:str', data)


_IndentedDumper.increase_indent = _indented_increase_indent  # type: ignore[assignment]
_IndentedDumper.add_representer(str, _str_representer)


async def write_yaml(path: Path, data: dict) -> None:
    raw = yaml.dump(
        data,
        Dumper=_IndentedDumper,
        default_flow_style=False,
        sort_keys=False,
        allow_unicode=True,
        indent=2,
        width=80,
    )
    lines = raw.splitlines(keepends=True)
    out: list[str] = []
    for line in lines:
        if out and line[0:1].isalpha() and not out[-1].startswith('\n'):
            out.append('\n')
        out.append(line)
    await aiofiles.os.makedirs(path.parent, exist_ok=True)
    async with aiofiles.open(path, mode='w', encoding='utf-8') as f:
        await f.write(''.join(out))


def normalize_name(name: str) -> str:
    return name.strip()


def to_kebab_case(name: str) -> str:
    """Folder identifier from a display name (e.g. "Travel Agent" → "travel-agent")."""
    cleaned = ''.join(c if c.isalnum() else ' ' for c in name.strip())
    parts = [p for p in cleaned.split() if p]
    return '-'.join(p.lower() for p in parts) if parts else 'unnamed'


def from_kebab_case(folder_name: str) -> str:
    """Display name from a kebab-case folder identifier (e.g. "lead-qualification" → "Lead Qualification")."""
    parts = [p for p in folder_name.split('-') if p]
    return ' '.join(p.capitalize() for p in parts) if parts else folder_name


# ---------------------------------------------------------------------------
# Folder → JSON
# ---------------------------------------------------------------------------


class FolderToJsonConverter:
    """Converts an agent folder into workflow spec JSON."""

    def __init__(self, agents_root: Path):
        self.agents_root = agents_root

    async def convert(self, agent_name: str) -> dict:
        agent_dir = self.agents_root / agent_name
        if not await aiofiles.os.path.isdir(agent_dir):
            print(f'Error: Agent directory not found: {agent_dir}', file=sys.stderr)
            sys.exit(1)

        spec_path = agent_dir / SPEC_FILENAME
        if not await aiofiles.os.path.exists(spec_path):
            print(f'Error: {SPEC_FILENAME} not found in {agent_dir}', file=sys.stderr)
            sys.exit(1)
        spec = await read_yaml(spec_path)

        instruction_file = spec.get('instruction_file', INSTRUCTIONS_FILENAME)
        instruction_path = agent_dir / instruction_file
        instructions = await read_text(instruction_path) if await aiofiles.os.path.exists(instruction_path) else ''

        schema: dict[str, Any] = {}
        if instructions:
            schema['goal'] = instructions

        agent_config = await self._build_autonomous_agent_config(agent_dir, spec, instructions)
        if agent_config:
            schema['autonomousAgentConfig'] = agent_config

        trigger_spec = spec.get('trigger') or {}
        trigger_type = trigger_spec.get('type', CHAT_MESSAGE_TRIGGER)
        schema['trigger'] = {'type': trigger_type}

        if trigger_type == INPUT_FORM_TRIGGER:
            input_fields = trigger_spec.get('inputFields') or []
            if input_fields:
                schema['fields'] = [convert_input_field_to_json(f) for f in input_fields]
        elif trigger_spec.get('inputFields'):
            raise ValueError(
                f'trigger.inputFields is only valid when trigger.type is {INPUT_FORM_TRIGGER!r}; '
                f'got trigger.type={trigger_type!r}'
            )

        if agent_config:
            _validate_model_selection(agent_config)

        request: dict[str, Any] = {
            'name': spec.get('name', from_kebab_case(agent_name)),
            'description': spec.get('description', ''),
            'schema': schema,
            'workflowNamespace': 'AGENT',
            'icon': spec.get('icon', {'name': 'GLEAN_APP', 'iconType': 'GLYPH'}),
        }

        agent_id = spec.get('id')
        if agent_id:
            request['id'] = agent_id

        return request

    # -- Skills --

    async def _parse_skill(self, skill_dir: Path) -> dict | None:
        skill_md = skill_dir / SKILL_FILENAME
        if not await aiofiles.os.path.exists(skill_md):
            return None

        return {
            'name': from_kebab_case(skill_dir.name),
            'content': {'mainContent': await read_text(skill_md)},
        }

    async def _parse_skills(self, agent_dir: Path, skill_paths: list[str]) -> list[dict]:
        skills = []
        for rel_path in skill_paths:
            skill_dir = agent_dir / rel_path.rstrip('/')
            if not await aiofiles.os.path.isdir(skill_dir):
                continue
            skill = await self._parse_skill(skill_dir)
            if skill:
                skills.append(skill)
        return skills

    # -- Tools --

    @staticmethod
    def _tools_config_to_action_servers(tools_config: list[dict]) -> list[dict]:
        action_servers: list[dict[str, Any]] = []
        for tool_entry in tools_config:
            entry: dict[str, Any] = {'serverId': tool_entry.get('toolProviderId')}
            tool_names = [t['name'] for t in tool_entry.get('selectedTools', []) if t.get('name')]
            if tool_names:
                entry['selectedTools'] = tool_names
            customisation = tool_entry.get('customisationData')
            if customisation is not None:
                translated = dict(customisation)
                if 'skipConfirmation' in translated:
                    translated['skipUserInteraction'] = translated.pop('skipConfirmation')
                entry['customisationData'] = translated
            action_servers.append(entry)
        return action_servers

    # -- Subagents --

    async def _parse_subagent(self, subagent_dir: Path) -> dict | None:
        spec_path = subagent_dir / SPEC_FILENAME
        if not await aiofiles.os.path.exists(spec_path):
            return None

        spec = await read_yaml(spec_path)

        subagent: dict[str, Any] = {
            'id': spec.get('id', subagent_dir.name),
            'name': spec.get('name', from_kebab_case(subagent_dir.name)),
            'description': spec.get('description', ''),
        }

        instruction_file = spec.get('instruction_file', INSTRUCTIONS_FILENAME)
        instruction_path = subagent_dir / instruction_file
        if await aiofiles.os.path.exists(instruction_path):
            subagent['instruction'] = await read_text(instruction_path)

        tools_config = spec.get('tools', [])
        if tools_config:
            action_servers = self._tools_config_to_action_servers(tools_config)
            if action_servers:
                subagent['actionServers'] = action_servers

        skill_paths = spec.get('skills', [])
        if skill_paths:
            skills = await self._parse_skills(subagent_dir, skill_paths)
            if skills:
                subagent['skills'] = skills

        glean_action = _glean_search_config_to_action(spec.get('gleanSearchConfig'))
        if glean_action is not None:
            subagent['actions'] = [glean_action]

        subagent.update(_extract_model_from_file(spec.get('model')))

        return subagent

    async def _parse_subagents(self, agent_dir: Path, subagent_paths: list[str]) -> list[dict]:
        subagents = []
        for rel_path in subagent_paths:
            sub_dir = agent_dir / rel_path.rstrip('/')
            if not await aiofiles.os.path.isdir(sub_dir):
                continue
            subagent = await self._parse_subagent(sub_dir)
            if subagent:
                subagents.append(subagent)
        return subagents

    # -- Autonomous agent config --

    async def _build_autonomous_agent_config(self, agent_dir: Path, spec: dict, instructions: str) -> dict:
        config: dict[str, Any] = {}

        glean_action = _glean_search_config_to_action(spec.get('gleanSearchConfig'))
        if glean_action is not None:
            config['actions'] = [glean_action]

        tools_config = spec.get('tools', [])
        if tools_config:
            tool_servers = self._tools_config_to_action_servers(tools_config)
            if tool_servers:
                config['actionServers'] = tool_servers

        skill_paths = spec.get('skills', [])
        if skill_paths:
            skills = await self._parse_skills(agent_dir, skill_paths)
            if skills:
                config['skills'] = skills

        subagent_paths = spec.get('subagents', [])
        if subagent_paths:
            subagents = await self._parse_subagents(agent_dir, subagent_paths)
            if subagents:
                config['subagents'] = subagents

        if instructions:
            config['instructions'] = instructions

        config.update(_extract_model_from_file(spec.get('model')))

        return config


# ---------------------------------------------------------------------------
# JSON → Folder
# ---------------------------------------------------------------------------


class JsonToFolderConverter:
    """Converts workflow spec JSON into an agent folder."""

    def __init__(self, output_root: Path):
        self.output_root = output_root

    async def convert(self, request: dict) -> Path:
        agent_name = normalize_name(request.get('name', 'unnamed agent'))

        agent_dir = self.output_root / to_kebab_case(agent_name)
        await aiofiles.os.makedirs(agent_dir, exist_ok=True)

        schema = request.get('schema', {})
        agent_config = schema.get('autonomousAgentConfig', {})

        instructions = agent_config.get('instructions') or schema.get('goal', '')
        if instructions:
            await write_text(agent_dir / INSTRUCTIONS_FILENAME, instructions)

        skill_paths = await self._write_skills(agent_config.get('skills', []), agent_dir / 'skills')
        subagent_paths = await self._write_subagents(agent_config.get('subagents', []), agent_dir / 'subagents')

        spec = self._build_spec(request, schema, agent_config, skill_paths, subagent_paths)
        await write_yaml(agent_dir / SPEC_FILENAME, spec)

        return agent_dir

    def _build_spec(
        self,
        request: dict,
        schema: dict,
        agent_config: dict,
        skill_paths: list[str],
        subagent_paths: list[str],
    ) -> dict:
        spec: dict[str, Any] = {}

        agent_id = request.get('id')
        if agent_id:
            spec['id'] = agent_id

        agent_name = request.get('name')
        if agent_name:
            spec['name'] = agent_name

        description = request.get('description')
        if description:
            spec['description'] = description

        spec['instruction_file'] = INSTRUCTIONS_FILENAME

        if skill_paths:
            spec['skills'] = skill_paths

        if subagent_paths:
            spec['subagents'] = subagent_paths

        action_servers = agent_config.get('actionServers', [])
        if action_servers:
            spec['tools'] = self._action_servers_to_tools_config(action_servers)

        glean_search_config = _extract_glean_search_config(agent_config.get('actions', []))
        if glean_search_config is not None:
            spec['gleanSearchConfig'] = glean_search_config

        model_block = _extract_model_from_json(agent_config)
        if model_block is not None:
            spec['model'] = model_block

        trigger = schema.get('trigger') or {}
        trigger_type = trigger.get('type', CHAT_MESSAGE_TRIGGER)
        trigger_yaml: dict[str, Any] = {'type': trigger_type}
        if trigger_type == INPUT_FORM_TRIGGER:
            fields = schema.get('fields') or []
            if fields:
                trigger_yaml['inputFields'] = [convert_input_field_to_spec(f) for f in fields]
        spec['trigger'] = trigger_yaml

        icon = request.get('icon')
        if icon:
            spec['icon'] = icon

        return spec

    # -- Skills --

    async def _write_skills(self, skills: list[dict], skills_base_dir: Path) -> list[str]:
        paths: list[str] = []
        for skill in skills:
            folder_name = to_kebab_case(normalize_name(skill.get('name', 'unnamed skill')))
            skill_dir = skills_base_dir / folder_name
            await aiofiles.os.makedirs(skill_dir, exist_ok=True)

            main_content = skill.get('content', {}).get('mainContent', '')
            if main_content:
                await write_text(skill_dir / SKILL_FILENAME, main_content)

            paths.append(f'skills/{folder_name}/')
        return paths

    # -- Subagents --

    async def _write_subagents(self, subagents: list[dict], subagents_base_dir: Path) -> list[str]:
        paths: list[str] = []
        for subagent in subagents:
            display_name = normalize_name(subagent.get('name', subagent.get('id', 'unnamed')))
            folder_name = to_kebab_case(display_name)
            sub_dir = subagents_base_dir / folder_name
            await aiofiles.os.makedirs(sub_dir, exist_ok=True)

            instruction = subagent.get('instruction', '')
            if instruction:
                await write_text(sub_dir / INSTRUCTIONS_FILENAME, instruction)

            sub_skill_paths = await self._write_skills(subagent.get('skills', []), sub_dir / 'skills')

            sub_spec: dict[str, Any] = {
                'id': subagent.get('id', ''),
                'name': display_name,
                'description': subagent.get('description', ''),
                'instruction_file': INSTRUCTIONS_FILENAME,
            }
            action_servers = subagent.get('actionServers', [])
            if action_servers:
                sub_spec['tools'] = self._action_servers_to_tools_config(action_servers)
            if sub_skill_paths:
                sub_spec['skills'] = sub_skill_paths

            glean_search_config = _extract_glean_search_config(subagent.get('actions', []))
            if glean_search_config is not None:
                sub_spec['gleanSearchConfig'] = glean_search_config

            model_block = _extract_model_from_json(subagent)
            if model_block is not None:
                sub_spec['model'] = model_block

            await write_yaml(sub_dir / SPEC_FILENAME, sub_spec)
            paths.append(f'subagents/{folder_name}/')
        return paths

    # -- Mapping server to tools --

    @staticmethod
    def _action_servers_to_tools_config(action_servers: list[dict]) -> list[dict]:
        tools: list[dict[str, Any]] = []
        for server in action_servers:
            entry: dict[str, Any] = {'toolProviderId': server.get('serverId')}
            selected = server.get('selectedTools', [])
            if selected:
                entry['selectedTools'] = [{'name': name} for name in selected]
            customisation = server.get('customisationData')
            if customisation is not None:
                translated = dict(customisation)
                if 'skipUserInteraction' in translated:
                    translated['skipConfirmation'] = translated.pop('skipUserInteraction')
                entry['customisationData'] = translated
            tools.append(entry)
        return tools


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


async def main() -> None:
    parser = argparse.ArgumentParser(
        description='Bidirectional converter between agent folders and workflow spec JSON.',
    )
    subparsers = parser.add_subparsers(dest='command')

    # to-json
    p_json = subparsers.add_parser(
        'to-json',
        help='Convert an agent folder into workflow spec JSON.',
    )
    p_json.add_argument('agent_name', help="Name of the agent folder (e.g. 'sales-agent')")
    p_json.add_argument(
        '--dir',
        default=os.environ.get('GLEAN_AGENTS_ROOT', str(DEFAULT_AGENTS_ROOT)),
        help=(
            'Root directory containing agent folders. '
            'Can also be set via GLEAN_AGENTS_ROOT env var. '
            f'Default: {DEFAULT_AGENTS_ROOT}'
        ),
    )
    p_json.add_argument('-o', '--output', help='Output file path. Prints to stdout if omitted.')

    # to-folder
    p_folder = subparsers.add_parser(
        'to-folder',
        help='Convert workflow spec JSON into an agent folder.',
    )
    p_folder.add_argument('json_file', help='Path to the input JSON file.')
    p_folder.add_argument(
        '--dir',
        required=True,
        help='Parent directory where the agent folder will be created.',
    )
    args = parser.parse_args()

    if args.command == 'to-json':
        converter = FolderToJsonConverter(Path(args.dir).resolve())
        config = await converter.convert(args.agent_name)
        output = json.dumps(config, indent=2, ensure_ascii=False)
        if args.output:
            async with aiofiles.open(args.output, mode='w', encoding='utf-8') as f:
                await f.write(output + '\n')
            print(f'Written to {args.output}')
        else:
            print(output)

    elif args.command == 'to-folder':
        json_path = Path(args.json_file)
        if not await aiofiles.os.path.exists(json_path):
            print(f'Error: JSON file not found: {json_path}', file=sys.stderr)
            sys.exit(1)
        async with aiofiles.open(json_path, encoding='utf-8') as f:
            request = json.loads(await f.read())
        converter = JsonToFolderConverter(Path(args.dir).resolve())
        agent_dir = await converter.convert(request)
        print(f'Agent folder created at {agent_dir}')

    else:
        parser.print_help()
        sys.exit(1)


if __name__ == '__main__':
    asyncio.run(main())
