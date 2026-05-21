#!/usr/bin/env python3
# /// script
# requires-python = ">=3.12"
# dependencies = ["pyyaml"]
# ///
"""
Bidirectional converter between agents folder representation and workflow spec JSON

Usage:
    uv run agent_converter.py to-json <agent_name> --dir /path/to/agents [-o out.json]
    uv run agent_converter.py to-folder input.json --dir /path/to/output
"""

import argparse
import json
import os
from pathlib import Path
import sys
from typing import Any

import yaml

DEFAULT_AGENTS_ROOT = Path.cwd()

SPEC_FILENAME = 'spec.yaml'
INSTRUCTIONS_FILENAME = 'instructions.md'
SKILL_FILENAME = 'SKILL.md'

# ---------------------------------------------------------------------------
# Shared utilities
# ---------------------------------------------------------------------------


def read_text(path: Path) -> str:
    return path.read_text(encoding='utf-8').strip()


def read_yaml(path: Path) -> dict:
    with open(path, encoding='utf-8') as f:
        return yaml.safe_load(f) or {}


def write_text(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content.rstrip() + '\n', encoding='utf-8')


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


def write_yaml(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
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
    path.write_text(''.join(out), encoding='utf-8')


def normalize_name(name: str) -> str:
    return name.strip()


# ---------------------------------------------------------------------------
# Folder → JSON
# ---------------------------------------------------------------------------


class FolderToJsonConverter:
    """Converts an agent folder into workflow spec JSON."""

    def __init__(self, agents_root: Path):
        self.agents_root = agents_root

    def convert(self, agent_name: str) -> dict:
        agent_dir = self.agents_root / agent_name
        if not agent_dir.is_dir():
            print(f'Error: Agent directory not found: {agent_dir}', file=sys.stderr)
            sys.exit(1)

        spec_path = agent_dir / SPEC_FILENAME
        if not spec_path.exists():
            print(f'Error: {SPEC_FILENAME} not found in {agent_dir}', file=sys.stderr)
            sys.exit(1)
        spec = read_yaml(spec_path)

        instruction_file = spec.get('instruction_file', INSTRUCTIONS_FILENAME)
        instruction_path = agent_dir / instruction_file
        instructions = read_text(instruction_path) if instruction_path.exists() else ''

        schema: dict[str, Any] = {}
        if instructions:
            schema['goal'] = instructions

        agent_config = self._build_autonomous_agent_config(agent_dir, spec, instructions)
        if agent_config:
            schema['autonomousAgentConfig'] = agent_config

        # supporting chat triggers only for now
        trigger_config = spec.get('trigger')
        schema['trigger'] = (
            {'type': trigger_config.get('type', 'CHAT_MESSAGE')} if trigger_config else {'type': 'CHAT_MESSAGE'}
        )

        request: dict[str, Any] = {
            'name': spec.get('name', agent_name),
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

    def _parse_skill(self, skill_dir: Path) -> dict | None:
        skill_md = skill_dir / SKILL_FILENAME
        if not skill_md.exists():
            return None

        return {
            'name': skill_dir.name,
            'content': {'mainContent': read_text(skill_md)},
        }

    def _parse_skills(self, agent_dir: Path, skill_paths: list[str]) -> list[dict]:
        skills = []
        for rel_path in skill_paths:
            skill_dir = agent_dir / rel_path.rstrip('/')
            if not skill_dir.is_dir():
                continue
            skill = self._parse_skill(skill_dir)
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
                entry['customisationData'] = customisation
            action_servers.append(entry)
        return action_servers

    # -- Subagents --

    def _parse_subagent(self, subagent_dir: Path) -> dict | None:
        spec_path = subagent_dir / SPEC_FILENAME
        if not spec_path.exists():
            return None

        spec = read_yaml(spec_path)

        subagent: dict[str, Any] = {
            'id': spec.get('id', subagent_dir.name),
            'name': subagent_dir.name,
            'description': spec.get('description', ''),
        }

        instruction_file = spec.get('instruction_file', INSTRUCTIONS_FILENAME)
        instruction_path = subagent_dir / instruction_file
        if instruction_path.exists():
            subagent['instruction'] = read_text(instruction_path)

        tools_config = spec.get('tools', [])
        if tools_config:
            action_servers = self._tools_config_to_action_servers(tools_config)
            if action_servers:
                subagent['actionServers'] = action_servers

        skill_paths = spec.get('skills', [])
        if skill_paths:
            skills = self._parse_skills(subagent_dir, skill_paths)
            if skills:
                subagent['skills'] = skills

        return subagent

    def _parse_subagents(self, agent_dir: Path, subagent_paths: list[str]) -> list[dict]:
        subagents = []
        for rel_path in subagent_paths:
            sub_dir = agent_dir / rel_path.rstrip('/')
            if not sub_dir.is_dir():
                continue
            subagent = self._parse_subagent(sub_dir)
            if subagent:
                subagents.append(subagent)
        return subagents

    # -- Autonomous agent config --

    def _build_autonomous_agent_config(self, agent_dir: Path, spec: dict, instructions: str) -> dict:
        config: dict[str, Any] = {}

        actions = spec.get('actions', [])
        if actions:
            config['actions'] = actions

        tools_config = spec.get('tools', [])
        if tools_config:
            tool_servers = self._tools_config_to_action_servers(tools_config)
            if tool_servers:
                config['actionServers'] = tool_servers

        skill_paths = spec.get('skills', [])
        if skill_paths:
            skills = self._parse_skills(agent_dir, skill_paths)
            if skills:
                config['skills'] = skills

        subagent_paths = spec.get('subagents', [])
        if subagent_paths:
            subagents = self._parse_subagents(agent_dir, subagent_paths)
            if subagents:
                config['subagents'] = subagents

        if instructions:
            config['instructions'] = instructions

        return config


# ---------------------------------------------------------------------------
# JSON → Folder
# ---------------------------------------------------------------------------


class JsonToFolderConverter:
    """Converts workflow spec JSON into an agent folder."""

    def __init__(self, output_root: Path):
        self.output_root = output_root

    def convert(self, request: dict) -> Path:
        agent_name = normalize_name(request.get('name', 'unnamed-agent'))

        agent_dir = self.output_root / agent_name
        agent_dir.mkdir(parents=True, exist_ok=True)

        schema = request.get('schema', {})
        agent_config = schema.get('autonomousAgentConfig', {})

        instructions = agent_config.get('instructions') or schema.get('goal', '')
        if instructions:
            write_text(agent_dir / INSTRUCTIONS_FILENAME, instructions)

        skill_paths = self._write_skills(agent_config.get('skills', []), agent_dir / 'skills')
        subagent_paths = self._write_subagents(agent_config.get('subagents', []), agent_dir / 'subagents')

        spec = self._build_spec(request, schema, agent_config, skill_paths, subagent_paths)
        write_yaml(agent_dir / SPEC_FILENAME, spec)

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

        actions = agent_config.get('actions', [])
        if actions:
            spec['actions'] = actions

        action_servers = agent_config.get('actionServers', [])
        if action_servers:
            spec['tools'] = self._action_servers_to_tools_config(action_servers)

        trigger = schema.get('trigger', {})
        # supporting chat triggers only for now
        spec['trigger'] = {'type': trigger.get('type', 'CHAT_MESSAGE')}

        icon = request.get('icon')
        if icon:
            spec['icon'] = icon

        return spec

    # -- Skills --

    def _write_skills(self, skills: list[dict], skills_base_dir: Path) -> list[str]:
        paths: list[str] = []
        for skill in skills:
            name = normalize_name(skill.get('name', 'unnamed-skill'))
            skill_dir = skills_base_dir / name
            skill_dir.mkdir(parents=True, exist_ok=True)

            main_content = skill.get('content', {}).get('mainContent', '')
            if main_content:
                write_text(skill_dir / SKILL_FILENAME, main_content)

            paths.append(f'skills/{name}/')
        return paths

    # -- Subagents --

    def _write_subagents(self, subagents: list[dict], subagents_base_dir: Path) -> list[str]:
        paths: list[str] = []
        for subagent in subagents:
            name = normalize_name(subagent.get('name', subagent.get('id', 'unnamed')))
            sub_dir = subagents_base_dir / name
            sub_dir.mkdir(parents=True, exist_ok=True)

            instruction = subagent.get('instruction', '')
            if instruction:
                write_text(sub_dir / INSTRUCTIONS_FILENAME, instruction)

            sub_skill_paths = self._write_skills(subagent.get('skills', []), sub_dir / 'skills')

            sub_spec: dict[str, Any] = {
                'id': subagent.get('id', ''),
                'description': subagent.get('description', ''),
                'instruction_file': INSTRUCTIONS_FILENAME,
            }
            action_servers = subagent.get('actionServers', [])
            if action_servers:
                sub_spec['tools'] = self._action_servers_to_tools_config(action_servers)
            if sub_skill_paths:
                sub_spec['skills'] = sub_skill_paths

            write_yaml(sub_dir / SPEC_FILENAME, sub_spec)
            paths.append(f'subagents/{name}/')
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
                entry['customisationData'] = customisation
            tools.append(entry)
        return tools


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def main() -> None:
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
        config = converter.convert(args.agent_name)
        output = json.dumps(config, indent=2, ensure_ascii=False)
        if args.output:
            Path(args.output).write_text(output + '\n', encoding='utf-8')
            print(f'Written to {args.output}')
        else:
            print(output)

    elif args.command == 'to-folder':
        json_path = Path(args.json_file)
        if not json_path.exists():
            print(f'Error: JSON file not found: {json_path}', file=sys.stderr)
            sys.exit(1)
        request = json.loads(json_path.read_text(encoding='utf-8'))
        converter = JsonToFolderConverter(Path(args.dir).resolve())
        agent_dir = converter.convert(request)
        print(f'Agent folder created at {agent_dir}')

    else:
        parser.print_help()
        sys.exit(1)


if __name__ == '__main__':
    main()
