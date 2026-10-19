# Compositor iPad 原生客户端

原生 iPadOS 17+ 绘画与图层编辑客户端，使用 SwiftUI、UIKit、Core Graphics 和 Core Image。普通编辑、分层保存和 PNG/JPEG 导出可离线使用；Windows 桥接负责可选的 AI 生成与工程版本备份。

这是首个可运行的编辑器基础版本，**尚未完成产品需求中的全部常用 Photoshop 工作流**。实现范围、验证证据和后续工作见 [iPad 状态](../docs/IPAD_STATUS.md)，完整目标见 [产品需求](../docs/PRODUCT_REQUIREMENTS.md)。

## 构建与测试

用安装了 iOS SDK 的 Xcode 打开 `CompositorPad.xcodeproj`，选择 `CompositorPad` scheme 和 iPad 模拟器。最低部署版本为 iPadOS 17；真机运行需要选择自己的 Development Team、有效签名以及已信任的 iPad。

从仓库根目录构建模拟器应用：

```sh
xcodebuild -project ipad_app/CompositorPad.xcodeproj \
  -target CompositorPad -configuration Debug -sdk iphonesimulator \
  SYMROOT=/tmp/compositor-ipad-build/Build/Products \
  OBJROOT=/tmp/compositor-ipad-build/Build/Intermediates.noindex \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- build
```

运行可在 Mac 执行的文档、渲染和桥接测试：

```sh
cd ipad_app
swift test
```

iPad 笔刷与应用界面测试位于 `iOSTests/`，需要可启动的模拟器。脚本会选取已安装的 iPad，也可通过参数指定设备 UUID：

```sh
bash ipad_app/tools/verify_ipad.sh
# 或：bash ipad_app/tools/verify_ipad.sh <iPad-simulator-UUID>
```

工程文件已纳入版本控制。添加或删除源文件后，用 `python3 ipad_app/tools/generate_project.py` 更新工程，再编译。核心 Swift Package 名称为 `CompositorKit`；不依赖外部 Swift 包。模拟器使用本地 ad-hoc 签名以保留 Keychain entitlement；完全关闭签名的应用可能无法访问钥匙串。验证脚本使用 Xcode 支持的 `test-without-building`，也适用于 SDK 与已安装模拟器运行时版本不同、scheme 自动目标解析失败的环境。

## 使用

- 文件菜单可新建画稿、打开 `.comp`、导入图片为图层、保存与分享分层工程，或导出 PNG/JPEG。JPEG 导出使用白底。
- 默认 Pencil 绘画、手指平移；开启“手指绘画”后，单指绘画、双指平移缩放。双指轻点撤销，三指轻点重做。笔压与倾斜已接入；已由用户在真机确认基本 Pencil 绘画、撤销和重做，精确延迟、倾斜与防误触仍需专项验证。
- 图层面板支持显示隐藏、不透明度、锁定、复制、删除、同级排序、图层组和已实现的混合模式。可移动、缩放、翻转和旋转普通图层。
- 选区笔、减选、矩形、椭圆和反选形成覆盖蒙版；填充、笔刷和调整遵循选区。选区可转为可启停、可移除的图层蒙版。
- 亮度、对比度、饱和度及高斯模糊应用到当前图层像素，保留蒙版并可撤销；当前没有非破坏性调整图层。
- 编辑后自动保存到应用的文稿目录；后台切换前尝试保存。保存失败会明确显示，切换文稿时会保留当前工作。

当前画布及每张可解码栅格资源限制为单边最多 4096 像素、总计最多 1600 万像素。此限制用于初版内存保护，不代表这些尺寸已通过长期真机性能验收。

## 连接 Windows 或 Mac 模拟服务

先按照 [桥接 README](../ipad_bridge/README.md) 启动现有服务。无需复制或重写后端。

1. 从服务提供方私下取得 `pairing.json`，传到 iPad 的“文件”中。
2. 在应用的“AI 工作台”选择“导入配对文件”，再选择“检查连接”。令牌保存到 Keychain；不要把配对文件提交到 Git。
3. 可选地绘制选区，填写生成描述，然后生成候选。无选区时发送全画布和全白蒙版；有选区时保留周围上下文，始终按原文档像素提交。
4. 预览候选后选择“加入新图层”。若文稿已经变化，候选会保留但不会自动贴入旧坐标。一次插入对应一次撤销。
5. 重新启动或恢复前台时会查询原任务。“重试未确认请求”复用已保存的请求 ID、metadata 和原 PNG；不会重新编码或换 ID 重发。
6. “备份当前分层工程到 Windows”上传不可变 `.comp` ZIP。首次上传前保留确切归档，后续同版本重试使用相同字节。当前界面尚未提供服务器备份下载与恢复浏览器。

模拟后端会明确显示“模拟服务 · 不执行 AI”；真实服务不会失败后自动切换到模拟模式。当前真实预设执行**参考图编辑，再把输出蒙版乘入 alpha**，不是模型去噪阶段的原生蒙版修补。客户端直接按返回坐标合成透明候选，不会重复应用同一输出蒙版。

## 分层工程格式

保存采用 Compositor v14 的 `manifest.json` 与 `images/` 目录包，保留每层原 PNG、变换、UUID、显示状态、不透明度、混合模式、穿透图层组及链接式灰度蒙版。普通空白层没有 PNG，开始绘画后才分配像素。保存完整包后原子替换旧文件。导入外部工程时若本机已有同一文档标识，会以新标识和版本 0 打开副本，保留本机已有版本；PNG/JPEG 导出只是独立的平面副本。

已用上游原始读取器和保存器完成一个分层、蒙版、变换及空白层样例的双向往返校验；它证明这个栅格子集可互通，不代表上游全部功能都已移植。

`ipad-state.json` 保存 iPad 的文稿名称、单调递增 Int64 版本、锁定状态、AI 插入收据及全画布选区引用。它绑定清单的 SHA-256；不一致时拒绝载入。`selection.png` 是该选区的无 alpha 灰度 PNG。这些额外文件不修改上游标准清单；上游重新保存时可能移除 iPad 专属状态。对未带此状态的上游工程，iPad 为导入会话建立新的版本基线。

导入只接受目前确实能编辑并保真的子集。含未知字段、文本、形状元数据、效果、调整图层、辅助线、剪贴链接、未链接蒙版、图层组蒙版、未实现的混合模式、16 位图像或 EXR 的工程会明确拒绝，不会悄悄栅格化或丢掉内容。资源路径、循环组结构、符号链接、大小和 PNG 类型也会检查。

工程 ZIP 使用无需额外依赖的 Stored 格式、CRC32、固定时间戳和确定的文件顺序；最大 64 MiB、最多 2000 项，同时服从服务能力。备份成功只表示归档及引用已通过桥接校验，不代表所有编辑器或功能都兼容。

## 源码边界

| 目录 | 责任 |
| --- | --- |
| `Sources/Core/` | 文档、图层、变换、事务历史、工程读写、ZIP 备份 |
| `Sources/Rendering/` | sRGB 栅格解码、合成、选区坐标映射、调整、视口 |
| `Sources/Bridge/` | API v1、认证、Keychain、请求持久化、恢复、校验、快照缓存 |
| `Sources/App/` | iPad 界面、Pencil 输入、画布手势、编辑与生成工作流 |
| `Tests/` | Mac 可运行的核心、渲染和网络协议测试 |
| `iOSTests/` | iOS 笔刷测试与模拟器界面测试 |

上游复用范围见 [移植清单](../docs/COMPOSITOR_PORT_MATRIX.md)；已保留 [MIT 许可证](../licenses/Compositor-MIT.txt) 和 [中文分支说明](../licenses/Compositor-ZH-NOTICE.md)。
