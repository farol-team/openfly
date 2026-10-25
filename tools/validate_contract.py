"""Validate schema references and documentation examples. This validates documentation, not runtime behavior.
Run: uv run --with jsonschema python tools/validate_contract.py
"""
import json
import re
from pathlib import Path
from jsonschema import Draft202012Validator

root = Path(__file__).resolve().parents[1]
spec = json.loads((root / 'api/openapi.json').read_text())
schemas = spec['components']['schemas']
for schema in schemas.values():
    Draft202012Validator.check_schema(schema)

def visit(value):
    if isinstance(value, dict):
        if '$ref' in value:
            assert value['$ref'].startswith('#/components/schemas/')
            assert value['$ref'].split('/')[-1] in schemas
        for nested in value.values():
            visit(nested)
    elif isinstance(value, list):
        for nested in value:
            visit(nested)
visit(spec)
ids = [op['operationId'] for path in spec['paths'].values() for op in path.values()]
assert len(ids) == len(set(ids))
assert spec['security'] == [{'ServiceToken': []}]

text = (root / 'docs/api.md').read_text()
examples = []
for language, block in re.findall(r'```(http|json)\n(.*?)\n```', text, re.S):
    if language == 'http':
        path = block.splitlines()[0].split()[1]
        schema_name = {
            '/v1/artifacts': 'CreateArtifact',
            '/v1/sessions': 'CreateSession',
            '/v1/sessions/ses_123/operations': 'CreateOperation',
            '/v1/operations/op_456/acknowledgement': 'AcknowledgementRequest',
        }[path]
        payload = json.loads(block[block.index('{'):])
    else:
        payload = json.loads(block)
        schema_name = 'Operation' if payload['id'].startswith('op_') else 'Session'
    Draft202012Validator({'$ref': '#/components/schemas/' + schema_name, 'components': {'schemas': schemas}}).validate(payload)
    examples.append(schema_name)
assert len(examples) == 6, examples
print(f'{len(ids)} API operations; {len(schemas)} schemas; {len(examples)} examples valid. This does not test implementation.')
