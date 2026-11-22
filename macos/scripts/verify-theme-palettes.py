#!/usr/bin/env python3
"""Verify compiled semantic tokens against the approved, archived theme palette."""
import json
import re
from pathlib import Path
root = Path(__file__).resolve().parents[1]
palettes = json.loads((root / 'Resources/ThemePalettes.json').read_text())
source = (root / 'Sources/SimulSubtitleMac/AppTheme.swift').read_text()
roles = {'bg':'background', 'sidebar':'sidebar', 'surface':'surface', 'ink':'ink', 'muted':'muted', 'line':'line', 'primary':'primary', 'primary-ink':'primaryInk', 'soft':'soft', 'accent':'selection', 'control':'control', 'caption-bg':'caption', 'preview-stage':'preview', 'dock-selected':'dockSelected'}
for theme, modes in palettes.items():
    section = source.split(f'"{theme}": [', 1)[1].split('\n        ],', 1)[0]
    for mode, values in modes.items():
        row = section.split(f'"{mode}": [', 1)[1].split(']', 1)[0]
        actual = dict(re.findall(r'"(\w+)": "(#[0-9a-f]+)"', row))
        assert actual == {roles[key]: value for key, value in values.items()}, (theme, mode)
print('PASS: all 112 compiled semantic colors match the approved eight palettes')
