#!/usr/bin/env python3
"""Validate pinned, data-only model download definitions without network access."""
import json
import re
from pathlib import Path
from urllib.parse import urlparse

catalog = json.loads((Path(__file__).resolve().parents[1] / 'Resources/LocalModelCatalog.json').read_text())
assert len({model['id'] for model in catalog}) == len(catalog)
for model in catalog:
    assert model['engine'] in {'senseVoice', 'whisper', 'qwen3ASR', 'gguf'}
    assert model['purpose'] in {'语音识别', '翻译'}
    assert len({file['name'] for file in model['files']}) == len(model['files']) > 0
    for file in model['files']:
        url = urlparse(file['url'])
        assert url.scheme == 'https' and url.hostname == 'huggingface.co'
        assert re.search(r'/resolve/[0-9a-f]{40}/', url.path)
        assert Path(file['name']).name == file['name'] and '..' not in file['name']
        assert file['name'].endswith(('.onnx', '.txt', '.gguf', '.json'))
        assert isinstance(file['byteCount'], int) and file['byteCount'] > 0
        assert re.fullmatch(r'[0-9a-f]{64}', file['sha256'])
        assert 'index-translate' not in file['name'].lower()
print('PASS: pinned model definitions; SHA-256, size and data-only paths validated')
