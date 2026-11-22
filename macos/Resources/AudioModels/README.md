# Bundled speech frontend models

These models run locally. No audio is uploaded by this frontend.

| File | Purpose | Bytes | SHA-256 |
| --- | --- | ---: | --- |
| silero_vad.onnx | Silero voice activity detection | 643854 | 9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6 |
| gtcrn_simple.onnx | GTCRN streaming speech enhancement | 535638 | e77603ac0c23dac3227dd2d7135b3a585cbee2679048aecfa886657d3ae1b534 |

Downloaded 2026-10-22 from the official sherpa-onnx release assets:

- https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx
- https://github.com/k2-fsa/sherpa-onnx/releases/download/speech-enhancement-models/gtcrn_simple.onnx

Upstream projects and licenses:

- Silero VAD: https://github.com/snakers4/silero-vad (MIT; LICENSE-Silero-VAD.txt)
- GTCRN: https://github.com/Xiaobin-Rong/gtcrn (MIT; LICENSE-GTCRN.txt)
- sherpa-onnx runtime: https://github.com/k2-fsa/sherpa-onnx (Apache-2.0; existing package dependency)

GTCRN enhances speech and suppresses background interference. It does not perfectly separate singing from spoken speech, or recover speech buried under very loud music. The UI provides a switch to bypass enhancement if it weakens a particular voice. Silero remains enabled in either case.
