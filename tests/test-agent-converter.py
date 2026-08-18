#!/usr/bin/env python3
# /// script
# requires-python = ">=3.12"
# dependencies = ["pyyaml", "aiofiles", "croniter"]
# ///

import ast
import asyncio
from pathlib import Path
import sys
import tempfile
import unittest
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))

from agent_converter import FolderToJsonConverter, JsonToFolderConverter


class InputFieldConversionTest(unittest.TestCase):
    def test_document_input_field(self) -> None:
        converter_path = Path(__file__).parent.parent / 'scripts' / 'agent_converter.py'
        converter_tree = ast.parse(converter_path.read_text(encoding='utf-8'))
        input_field_nodes = [
            node
            for node in converter_tree.body
            if (
                isinstance(node, ast.Assign)
                and any(
                    isinstance(target, ast.Name) and target.id == 'INPUT_FIELD_TYPES'
                    for target in node.targets
                )
            )
            or (
                isinstance(node, ast.FunctionDef)
                and node.name == 'convert_input_field_to_json'
            )
        ]

        namespace: dict[str, Any] = {'Any': Any}
        exec(
            compile(
                ast.Module(body=input_field_nodes, type_ignores=[]),
                filename=str(converter_path),
                mode='exec',
            ),
            namespace,
        )

        converted = namespace['convert_input_field_to_json'](
            {
                'displayName': 'source_file',
                'type': 'DOCUMENT',
                'optional': True,
            },
        )

        self.assertEqual(
            converted,
            {
                'name': 'source_file',
                'displayName': 'source_file',
                'type': {'type': 'DOCUMENT'},
                'optional': True,
            },
        )


class StandaloneActionsTest(unittest.TestCase):
    def test_folder_to_json_emits_standalone_and_glean_search_actions(self) -> None:
        converter = FolderToJsonConverter(Path('.'))
        config = asyncio.run(
            converter._build_autonomous_agent_config(
                Path('.'),
                {
                    'actions': [{'actionId': 'bravewebsearch'}],
                    'gleanSearchConfig': {},
                },
                '',
            )
        )

        self.assertEqual(
            config['actions'],
            [
                {'actionId': 'bravewebsearch'},
                {'actionId': 'Glean Search', 'gleanSearchConfig': {'inclusions': {}}},
            ],
        )

    def test_json_to_folder_round_trips_standalone_actions(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            converter = JsonToFolderConverter(Path(temp_dir))
            spec = converter._build_spec(
                {'id': 'agent-id', 'name': 'Agent'},
                {},
                {
                    'actions': [
                        {
                            'actionId': 'bravewebsearch',
                            'actionCustomisationData': {'required': False},
                        },
                        {'actionId': 'Glean Search', 'gleanSearchConfig': {'inclusions': {}}},
                    ]
                },
                [],
                [],
            )

        self.assertEqual(
            spec['actions'],
            [
                {
                    'actionId': 'bravewebsearch',
                    'actionCustomisationData': {'required': False},
                }
            ],
        )
        self.assertEqual(spec['gleanSearchConfig'], {})

    def test_rejects_glean_search_in_standalone_actions(self) -> None:
        converter = FolderToJsonConverter(Path('.'))
        with self.assertRaisesRegex(ValueError, 'gleanSearchConfig'):
            asyncio.run(
                converter._build_autonomous_agent_config(
                    Path('.'),
                    {'actions': [{'actionId': 'Glean Search'}]},
                    '',
                )
            )


if __name__ == '__main__':
    unittest.main()
