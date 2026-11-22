# 回归夹具

- `clip-ja.mp4`：10 秒、640×360 蓝色背景，日语测试句为「今日は日本語の字幕をテストしています」。用于媒体时间、VAD、日中识别翻译、字幕烧录及原生播放器检查，不含账号、直播 Cookie 或私人信息。
- `silent-stop.mkv`：约 2.2 秒、160×90、无音轨的合成画面，用于录制、关键帧分段和停止保存。
- 慢速 HTTP 流由 `scripts/serve-live-fixtures.py` 生成测试图案并限速发送，仅监听 127.0.0.1。

先准备应用内置辅助程序，然后在 `macos` 目录运行：

```sh
python3 scripts/serve-live-fixtures.py
```

在另一个终端用已打包的应用运行（诊断参数使用隔离存储，不改变真实账号或重置权限）：

```sh
"/path/SimuSub v1.12.app/Contents/MacOS/SimulSubtitleMac" --live-monitor-check /tmp/simusub-live-checks \
  --recording-fixture http://127.0.0.1:18709/silent-stop.mkv \
  --recording-stop-fixture http://127.0.0.1:18709/slow.ts

"/path/SimuSub v1.12.app/Contents/MacOS/SimulSubtitleMac" --clip-check /tmp/simusub-clip-checks \
  "$PWD/Fixtures/clip-ja.mp4" --clip-real-models "$HOME/Library/Application Support/SimulSubtitle/models"
```

`--clip-real-models` 为可选参数，不提供时使用固定识别/翻译夹具测试其余剪辑链路。报告区分真实本地模型检查。每次选择新的输出目录；原生动画检查需要可见桌面会话。
