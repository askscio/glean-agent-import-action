#!/usr/bin/env python3

import ast
from pathlib import Path
from typing import Any


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

assert converted == {
    'name': 'source_file',
    'displayName': 'source_file',
    'type': {'type': 'DOCUMENT'},
    'optional': True,
}

print('PASS: DOCUMENT input fields convert to workflow JSON')
