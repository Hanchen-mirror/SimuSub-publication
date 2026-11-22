# macOS 离线安装盘

在已安装 Xcode 命令行工具的 Apple 芯片 Mac 上，准备签名的 SimuSub.app 和对应模型目录。最终用户在 Finder 将左侧应用拖进右侧的「应用程序」文件夹即可离线安装。右侧是指向 /Applications 的标准符号链接。

从原生仓库根目录运行。将签名身份、应用位置及输出位置替换为当前发布的值。

```sh
python3 -m venv /tmp/simusub-dmg-tools
/tmp/simusub-dmg-tools/bin/pip install -r macos/distribution/requirements-layout.txt
/tmp/simusub-dmg-tools/bin/python macos/distribution/build-dmg.py \
  --app "$APP" --identity "$IDENTITY" --output "$DMG" \
  --models "$HOME/Library/Application Support/SimulSubtitle/models"
```

可改用 `--models-volume "/Volumes/SimuSub 1.6.8"` 复用早期只读安装盘的模型。若镜像挂载后改过名，可用 `--source-image "$SIGNED_DMG"` 指定现有文件。打包工具验证其签名、分区标识、封存清单和模型内容。

模型、SHA-256 标记、清单及许可随暂存应用放在 Contents/SharedSupport 中，然后用同一证书重新签名，保留应用标识、授权项、代码签名要求和选项。`DrawDiskBackdrop.swift` 绘制 Finder 背景。`finder_layout.py` 在可写 HFS+ 镜像内设置背景与图标位置，然后转换为压缩只读映像。打包脚本重新挂载成品，验证 Finder 布局、嵌套代码签名与所有模型。对外发布使用 Developer ID 签名并另行完成 Apple 公证。
