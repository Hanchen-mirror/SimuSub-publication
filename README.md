<p align="center"><img src="macos/Resources/AppIcon.png" alt="SimuSub 应用图标" width="112" height="112"></p>

# SimuSub

SimuSub 是我做的第一个开源项目。它可以在 Mac 上为正在播放的直播或视频实时翻译字幕，也可以录下直播、剪出喜欢的片段。

名字里的 **Sim** 取自 *Simulate*，**Sub** 取自 *Subtitle*。我想让字幕和声音同步，也希望字幕能带来一点连接（connection）。看另一种语言的直播时，我也想跟上主播说的话，和大家一起笑出来。

**[一键下载 SimuSub 1.6.8 完整离线 DMG](https://huggingface.co/datasets/JohnSmith433/SimuSub-downloads/resolve/main/SimuSub-1.6.8.dmg?download=true)** · [GitHub 发布页和备用分卷](https://github.com/Hanchen-mirror/SimuSub/releases/tag/v1.6.8) · [使用说明](使用说明.txt)

适用于 Apple Silicon Mac，最低支持 macOS 13.3。完整安装包包含离线语音识别和翻译模型。

## 能做什么

1. **实时字幕翻译**。在「字幕同传」选中正在播放声音的浏览器或播放器，设置源语言和字幕语言，点「开始同传」。浮窗可以同时显示原文和译文，支持中文、英语和日语。
2. **视频剪辑与高光候选**。把视频导入「剪辑工作台」，就可以生成或导入全片字幕、修改原文和译文、挑选高光，再烧录字幕导出。例如从五分钟视频里选取 1:00 到 2:00，导出的是这一分钟，工作台仍可查看和编辑完整五分钟的字幕。自动推荐高光依赖识别文本，漏识别一句，也可能错过对应的高光。
3. **直播录制**。可以关注 Bilibili、Twitch 和 YouTube 的主播，查看开播状态、打开直播间观看、手动或自动录制。我希望以后能接入更多直播平台。
4. **本地模型与云端服务**。默认使用随包安装的离线模型。你也可以在「模型与服务」导入兼容的本地模型，或用自己的接口地址、模型 ID 和 API Key 分别配置云端语音识别和翻译。

## 我怎么选模型

ASR 负责把声音写成原文，翻译模型再把原文译成目标语言。我看日语直播时，通常用 **本地 ASR ＋ 云端翻译**，让 Mac 识别音频，把字幕文本发给翻译服务。

剪辑时，如果原文漏得多，我会换用 **OpenAI 云端 ASR**，重新识别后再选高光。在我试过的日语视频里，它往往能多听出一些词。换用云端 ASR 会把音频发给服务商，实际效果也会随录音、说话速度和背景音乐变化。

**1.6.8 还有一些 bug。** 日语口语里，短语气词可能在识别或翻译时漏掉。我试过快歌 *Demon’s Shot*，快速演唱段落的翻译效果很差，歌词仍需对着音频逐句核对。我希望在后续版本继续改善这些问题。欢迎在 [Issues](https://github.com/Hanchen-mirror/SimuSub/issues) 留下复现步骤，字幕问题尤其欢迎附上时间点、实际输出和你听到的原句。

## 安装与首次授权

1. 打开完整 DMG，把 SimuSub 拖到右侧「应用程序」。等复制完成，推出安装盘，从「应用程序」启动。
2. **这是使用本地开发签名的公开测试版，尚未通过 Apple 公证。** 如果首次启动时 macOS 提示无法验证开发者，先核对下方 SHA-256。确认文件来源后，在「系统设置 → 隐私与安全性」中找到 SimuSub，点「仍要打开」并按提示确认。
3. 首次同传按引导申请「屏幕与系统音频录制」权限。若列表里没有 SimuSub，点该区域的「＋」，选择 `/Applications/SimuSub.app`，开启开关并按提示重新打开。只剪辑本地视频可以稍后授权。

<details>
<summary>从 GitHub 下载两个备用分卷，以及校验安装包</summary>

在发布页下载 `SimuSub-1.6.8.dmg.part-01` 和 `SimuSub-1.6.8.dmg.part-02`，放在同一文件夹。在该文件夹打开终端，运行下面两行命令。

```sh
cat SimuSub-1.6.8.dmg.part-01 SimuSub-1.6.8.dmg.part-02 > "SimuSub-1.6.8.dmg"
shasum -a 256 "SimuSub-1.6.8.dmg"
```

直接下载的完整 DMG 只需运行第二行。1.6.8（构建 265）的完整 DMG 与分卷合并结果应有相同的 SHA-256。

```text
0c8cfcc3cc10224666c2263a01e94268377a4f79d82b9ec683fa253cc3b820a4
```

</details>

## 开源项目与致谢

感谢这些项目的开发者，让我能把字幕识别、翻译和录制放在同一个应用里。

| SimuSub 中的用途 | 相关项目 |
| --- | --- |
| 在本机运行语音识别。默认日语用 ReazonSpeech，英语用 Whisper，中文用 SenseVoice | [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) · [ReazonSpeech](https://github.com/reazon-research/ReazonSpeech) · [Whisper](https://github.com/openai/whisper) · [SenseVoice](https://huggingface.co/FunAudioLLM/SenseVoiceSmall) |
| 在 Swift 中通过 llama.cpp 运行本地翻译模型 Index-Translate-2B | [llama.swift](https://github.com/mattt/llama.swift) · [Index-Translate-2B](https://huggingface.co/IndexTeam/Index-Translate-2B-GGUF) |
| 解析直播来源、录制音视频和处理导出文件 | [yt-dlp](https://github.com/yt-dlp/yt-dlp) · [FFmpeg](https://ffmpeg.org/) |
| 检测人声、降低噪声和给中日文字幕断行 | [Silero VAD](https://github.com/snakers4/silero-vad) · [GTCRN](https://github.com/Xiaobin-Rong/gtcrn) · [BudouX](https://github.com/google/budoux) |

SimuSub 源码采用 [MIT 许可证](LICENSE)。第三方模型和工具沿用各自的许可。[模型来源与许可](macos/distribution/model-licenses/模型来源.txt) · [本地构建](macos/BUILDING.md) · [制作安装盘](macos/distribution/README.md)

最后感谢导师 Frank 的指导。[Frank 的 Bilibili 主页](https://space.bilibili.com/19658621)
