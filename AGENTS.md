# SimuSub 原生仓库约定

本文件将工作区的模型复用规则保存在原生仓库中，单独打开或检出本仓库时同样适用。

## 标准拖放离线版

从 1.6.8 构建 262 起，项目负责人已明确授权将发布清单中的模型放入签名应用的 `Contents/SharedSupport/Models`。打包可从已验证的只读发行盘取材，回归可直接读取该目录。安装过标准离线版的开发机可直接读取其已验证的模型。下面的开发复用约定继续用于普通构建。

## 本地翻译模型：固定复用，禁止重复下载

开发、构建、调试和回归测试应复用已验证的 **Index-Translate-2B Q4_K_M**。普通用户数据目录中的模型路径及校验值如下。

- 模型根目录：`$HOME/Library/Application Support/SimulSubtitle/models`
- 翻译模型文件：`$HOME/Library/Application Support/SimulSubtitle/models/mt/index-translate-2b.gguf`
- 校验标记：`$HOME/Library/Application Support/SimulSubtitle/models/mt/index-translate-2b.gguf.sha256`
- 文件大小：`1312164352` 字节。
- SHA-256：`044b313d29342bd3b2c77cbb64023ca0d209bd9b3247763f9d162767ef2d746a`

执行约束：

1. 直接指定上述根目录或文件路径；含空格的路径在命令中必须正确引用。模型视为只读共享资源，不移动、覆盖或删除。
2. 不再下载此模型，也不将它复制到项目、历史归档、应用包、构建产物、测试目录或系统临时目录。不要调用会下载或复制模型的安装、导入、准备命令。
3. 真实模型回归必须传入现有模型根目录。例如剪辑回归使用 `--clip-real-models "$HOME/Library/Application Support/SimulSubtitle/models"`。测试数据和偏好可隔离，模型文件必须共享复用。
4. 测试“模型未安装”或纯界面状态时，允许使用空的隔离目录，但必须禁止网络下载；不得点击“准备模型”或“开始同传”来触发下载。测试结束清理自身临时文件。
5. 路径不存在、校验不符或无法读取时，停止依赖模型的操作并报告具体问题，不自动重新下载，不换路径另存一份。只有用户之后明确修改这项约定，才可改变该行为。
6. 模型不加入 Git。普通开发构建读取本机已有模型；标准离线发行按上节约定从已验证的发行盘打包。
