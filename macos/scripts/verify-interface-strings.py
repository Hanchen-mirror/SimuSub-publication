#!/usr/bin/env python3
"""Check interface translations and placeholder parity without network access."""
import json
import re
from pathlib import Path

mac = Path(__file__).resolve().parents[1]
values = json.loads((mac / 'Resources/InterfaceStrings.json').read_text())
errors = []
for key, translations in values.items():
    for language in ['en', 'ja']:
        text = translations.get(language)
        if not text or key.count('%@') != text.count('%@'):
            errors.append(f'{language}: empty translation or wrong placeholder count: {key}')
for source in (mac / 'Sources/SimulSubtitleMac').glob('*.swift'):
    if 'Checks' in source.name:
        continue
    for match in re.finditer(r'L10n.text\("((?:[^"\\]|\\.)*)"\)', source.read_text()):
        key = match[1]
        if '\\(' in key or not re.search(r'[\u4e00-\u9fff]', key):
            continue
        key = json.loads('"' + key + '"')
        if key not in values:
            errors.append(f'{source.name}: missing translation: {key}')
if errors:
    raise SystemExit('\n'.join(errors))
print(f'PASS: {len(values)} interface strings, English/Japanese parity and static UI keys')
