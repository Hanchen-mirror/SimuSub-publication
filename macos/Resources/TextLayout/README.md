# BudouX text layout assets

Source: https://github.com/google/budoux
Pinned commit: 9ddf284a13ffcb5fb38775dd38301c60eb3e3f41
Copyright 2021 Google LLC. Apache License 2.0 (LICENSE-BudouX.txt).

ja.json and zh-hans.json are unmodified upstream models from budoux/models/.
File sizes and SHA-256 digests are recorded in provenance.json.
The files were retrieved through the GitHub contents API at the pinned commit,
and their Git blob SHA-1 digests were verified before storing them locally.

SubtitleLineLayout.swift adapts the plain-text algorithm from budoux/parser.py.
The Swift version preserves Unicode grapheme clusters, adds punctuation and
particle safeguards when combining phrases, and wraps using measured font widths.
Parser outputs are checked against the pinned upstream Python implementation.

This is a display helper, not a sentence-end detector. It does not cut the audio,
change translation context, or alter the text stored in exported subtitles.
The models run offline and no JavaScript/Python runtime is required by the app.
