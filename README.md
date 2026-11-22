<p align="center"><img src="macos/Resources/AppIcon.png" alt="SimuSub 应用图标" width="112" height="112"></p>

# SimuSub

SimuSub 是一款 Apple Silicon Mac 上的实时字幕、直播录制和视频剪辑工具。1.6.8 的安装包内置离线语音识别和翻译模型，可以直接生成日中双语字幕。[完整使用说明](使用说明.txt)

## 下载与首次使用

在 [SimuSub 1.6.8 发布页](https://github.com/Hanchen-mirror/SimuSub/releases/tag/v1.6.8) 选择「完整离线版」，或[直接下载完整 DMG](https://huggingface.co/datasets/JohnSmith433/SimuSub-downloads/resolve/main/SimuSub-1.6.8.dmg?download=true)。打开 DMG，将 SimuSub 拖入「应用程序」，推出安装盘后从「应用程序」启动。

也可以下载同一发布页上的两个 GitHub 分卷，将它们放在同一文件夹，在该文件夹打开终端并运行以下命令。将输出的 SHA-256 与发布页提供的校验值对照后，再打开合并得到的 DMG。

```sh
cat SimuSub-1.6.8.dmg.part-01 SimuSub-1.6.8.dmg.part-02 > "SimuSub 1.6.8.dmg"
shasum -a 256 "SimuSub 1.6.8.dmg"
```

**1.6.8 是公开测试版，安装包使用本地开发签名，尚未通过 Apple 公证。** 如果 macOS 在首次打开时提示无法验证开发者，请先核对发布页的 SHA-256。确认文件来自本项目后，到「系统设置 → 隐私与安全性」，在 SimuSub 的提示旁点「仍要打开」，按系统提示确认。

首次使用字幕同传时，按引导申请录制权限。如果系统列表未显示 SimuSub，点击上方「屏幕与系统音频录制」区域的「＋」，选择 `/Applications/SimuSub.app`，开启权限并按提示重新打开。进入「字幕同传」，选择日语、简体中文和声音来源，然后开始。

## 推荐配置与已知局限

日语同传建议使用 **本地 ASR ＋ 云端翻译**。在「模型与服务」保留本地日语识别，添加云端翻译服务并点「使用翻译」。音频由本机识别，识别文本会发送给你选择的翻译服务。安装包也支持全程离线。

- 日语口语中，短语气词有时会在识别或翻译时漏掉。对照日语原文和音频，可以判断应补原文还是修译文。
- 实测快歌 *Demon’s Shot* 时，快速演唱段落的翻译效果很差。歌词用途建议逐句校对。

## 开发与许可

开发环境为 Apple Silicon Mac，应用最低支持 macOS 13.3。构建步骤、离线安装盘制作和发布前测试分别见[本地构建](macos/BUILDING.md)、[安装盘构建](macos/distribution/README.md)和[版本验收](docs/RELEASE-WORKFLOW.md)。

SimuSub 源码采用 [MIT 许可证](LICENSE)。第三方模型、字体和媒体工具沿用各自的许可。离线安装包附有模型来源与许可说明。[模型许可](macos/distribution/model-licenses/模型来源.txt)

最后感谢导师 Frank 的指导。[Frank 的 Bilibili 主页](https://space.bilibili.com/19658621)
