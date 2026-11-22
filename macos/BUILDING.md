# 构建 macOS 应用

在 Apple Silicon Mac 上安装 Xcode 命令行工具、Swift 和 Python 3。从仓库根目录运行以下命令，SwiftPM 会读取锁定的依赖版本。

```sh
cd macos
swift build -c release
```

制作可运行的应用包需要与当前发布渠道匹配的代码签名身份，以及包内录制和媒体工具。用以下命令检查工具。若工具缺失，运行 `python3 scripts/prepare-live-tools.py` 准备固定版本的 yt-dlp、Deno 和 FFmpeg，再次校验。

```sh
python3 scripts/verify-live-tools.py
python3 scripts/verify-interface-strings.py
python3 scripts/verify-theme-palettes.py
python3 scripts/verify-local-model-catalog.py
```

调试时可以用独立的本地候选包。选用钥匙串中已有的签名身份，并为每次候选构建指定新的输出路径。构建脚本从 `local-candidate-version.json` 读取候选版本，成功后更新该文件。正式渠道的版本保存在 `Resources/Info.plist`。

```sh
SIMUSUB_BUILD_MODE=local-candidate CODE_SIGN_IDENTITY="$IDENTITY" \
  ./build-app.sh "$PWD/.build/SimuSub Candidate.app"
codesign --verify --deep --strict "$PWD/.build/SimuSub Candidate.app"
```

本地渠道使用独立的应用标识。升级测试应复用同一签名身份，以便检查 macOS 录制授权是否延续。制作 Developer ID 发布包时指定 Developer ID Application 身份，发布前完成公证和票据装订。

正式安装盘把全部离线模型放在签名应用的 `Contents/SharedSupport/Models` 中。模型体积较大，打包时可复用已验证的发行介质。准备安装盘的参数和校验步骤见[离线安装盘](distribution/README.md)。可用于剪辑和录制回归的合成测试素材见[本地夹具](Fixtures/README.md)。
