# Compositor iPad 绘画与本地 ComfyUI 开发交接

交接日期：2026 年 10 月 19 日，Asia/Shanghai。

> 后续进展：本仓库现已新增可构建的原生 iPad 工程及基础编辑器。最新完成范围、构建命令、验证与限制以 [iPad 状态](IPAD_STATUS.md) 和 [客户端 README](../ipad_app/README.md) 为准。下文“尚未创建 iPad target”等内容是接手前的历史基线，不代表当前代码。

接收方：在 Mac 上工作的开发 agent。开发环境由 Mac、iPad，以及运行 ComfyUI 的 Windows／NVIDIA 电脑组成。

最终目标是以 Compositor-ZH 为优先移植与复用基础，做出覆盖 Photoshop 大多数常用绘画、修图、合成和图层编辑功能的原生 iPad 软件。ComfyUI 是其中的 AI 辅助模块：iPad 通过局域网提交画面与选区，Windows 生成候选并返回新图层。普通绘画、编辑、保存和导出必须在不连接 Windows 时也能使用。

**产品范围以 [产品需求](PRODUCT_REQUIREMENTS.md) 为准。AI 回传闭环是第一阶段，不能作为整个软件的最终交付标准。** 常用图层、选区、变换、调整、修图、滤镜、文字形状与文件交换等能力需要按路线继续推进。

用户已经明确选择：**首期 iPad 负责绘画，Windows 只负责同步、存储和 ComfyUI。Windows 桥接 v0.1 已实现，Mac agent 的工作是开发原生 iPad 端并接入现有服务，不重新写一套后端。** 先检查 Mac 开发环境与源码，再推进可运行的最小闭环；不要只交付另一份可行性报告。

先读产品需求，再读 [桥接 README](../ipad_bridge/README.md) 和 [API v1](../ipad_bridge/docs/API_V1.md)。**产品需求定义编辑器范围，API v1 定义当前网络接口行为；本文件保留移植背景、职责和验收要求。** 需要调整协议时先与 Windows 实现同步，不单方面扩展字段或预设。

## 用户意图与首期范围

项目面向习惯在 iPad／Procreate 上绘画的用户，以 Compositor-ZH 作为原生编辑器的优先移植与复用基础，逐步实现接近 Photoshop 常用功能覆盖的创作工具，并集成类似 Photoshop 与 ComfyUI 插件的选区生成体验。先核实并复用上游已有能力，再针对 iPad 改造和补齐缺项。

首期需要：

- 原生 iPad 应用，支持打开图片、基础画笔或蒙版绘制、缩放和平移。
- 基础图层、显示隐藏、不透明度，以及加入 AI 结果的一步撤销和重做。
- 手动提交当前选区或画面，显示任务状态与生成候选。
- Windows 服务保存任务和结果，调用固定的 ComfyUI 工作流。
- 生成结果准确放回原稿位置，作为独立图层，保留用户已有笔迹。
- iPad 锁屏或网络断开后，可恢复查询并取回结果。

首期只交付上述基础子集，后续必须继续推进产品需求中的常用编辑能力。首期不要求完整 Windows 绘图编辑器、双端同时编辑、逐笔跨设备同步、Procreate 实时插件、云端账号系统或 App Store 发布。画笔与普通编辑在 iPad 本机运行，不等待 Windows 或 AI 推理。

## 已完成的调查与实际状态

已经完成两个公开仓库的源码阅读，并实现 `ipad_bridge/` 中的 Windows 桥接 v0.1、模拟后端、真实 ComfyUI 适配器、测试和验证客户端。服务具备带认证的任务提交、持久化、结果下载、请求重试处理，以及 `.comp` ZIP 版本备份。**Windows 真实 GPU HTTP 闭环已通过；尚未创建 iPad target、编译 iPad 应用，Mac／iPad 真机与跨设备局域网连接仍未测试。**

历史 Windows 验证：`pytest` 为 62 项通过、另有 81 项子测试；真实生成使用 RTX 5080 与 FLUX.2 Klein 4B，验证报告记录 `ok=true`、`isSimulation=false`。一次 512×384 合成测试画稿的完整提交、重试、查询、下载耗时 6.39 秒，模型已缓存；尺寸、来源与裁切位置、SHA-256、蒙版外 alpha 和合成像素保护均通过。运行报告和图片未纳入公开仓库；在自己的环境中按 [桥接验证步骤](../ipad_bridge/README.md#验证)运行示例客户端，可生成新的报告。这是单个测试样本，不能当作普遍生成速度、真实绘画满意度或 iPad 完整体验的保证。

| 项目 | 已确认情况 |
| --- | --- |
| Compositor-ZH | 原生 macOS Swift 项目，SwiftUI、AppKit、部分 C 像素算法、Metal、Core Image；不是网页或 Electron 应用 |
| 当前平台 | README 要求 Apple Silicon 与 macOS 26 及以上；Xcode 工程使用 macOS SDK |
| 中文分支 | `zh-Hans`，调查提交 `7c2a5a4a3e7f685a8a0ec282ef0b4284f20b5477`，基于上游 v1.5.3 |
| 许可证 | Compositor-ZH 的代码及中文修改采用 MIT，保留版权、LICENSE 与 NOTICE |
| 输入与画布 | `EditorCanvas` 使用 `NSViewRepresentable`、`NSView`、`NSEvent`；未找到现成的 Pencil 笔压、倾斜输入接入 |
| 工程格式 | `.comp` 是包含 `manifest.json` 和图层资源的目录包，调查时格式为 v14 |
| 验证显卡 | 历史真实生成测试使用 RTX 5080，约 16GB 显存；不是运行本项目的唯一硬件选择 |
| Windows 桥接 | v0.1 已实现，实际局域网地址从私下配对文件取得；使用时重新检查 `/health` 与已认证的后端状态 |
| ComfyUI 内部地址 | 配置为 Windows 本机地址，例如 `http://127.0.0.1:8188`，只供桥接内部调用；不是 iPad 或 Mac 客户端地址 |
| 配对信息 | 私下交付 `pairing.json`；本交接不含 token，不应提交或公开配对文件 |
| Mac 与 iPad | 用户确认有 Mac；型号、系统、Xcode、签名与 iPad 型号尚未检查 |

源码入口：

- Compositor-ZH：https://github.com/qidian2022/Compositor-ZH
- 中文分支：https://github.com/qidian2022/Compositor-ZH/tree/zh-Hans
- 调查基线：https://github.com/qidian2022/Compositor-ZH/tree/7c2a5a4a3e7f685a8a0ec282ef0b4284f20b5477
- 参考插件：https://github.com/NimaNzrii/comfyui-photoshop

本仓库是 Mac 与 Windows 共享代码、接口和交接文档的主仓库。先在 Mac 克隆本仓库，阅读其中的 `AGENTS.md`（如存在）；Compositor-ZH 是另行获取的上游参考源码，不包含在当前桥接目录中。移植前阅读上游 `AGENTS.md`，检查其最新分支与上述基线的差异。保持原 Mac target 与用户已有改动可用；不要重置或覆盖已有工作。公开源码读取遇到证书问题时修复信任配置或换正常验证证书的读取方式，不要关闭 TLS 校验。

## 先做的环境检查

在 Mac 上自主检查系统版本、芯片、可用空间、Xcode 版本、当前 developer directory、已安装的 iOS SDK 与模拟器。检查是否存在用户已配置的签名团队和连接的 iPad，不输出凭据或私钥。

先确认原 Mac target 能否构建，以建立基线，再建立 iPad 编译目标。项目原 Mac target 要求的系统版本与新 iPad target 的最低系统版本是两件事；根据实际使用的 API 和用户设备选择 iPad 部署版本，不要直接复制 macOS 26 的要求。

目标必须是可安装在 iPad 上的原生 iOS/iPadOS target。原 Mac 应用运行、远程桌面、屏幕镜像或网页画板演示，都不能作为 iPad 移植完成的证据。

签名团队或真机访问缺失时，先完成模拟器、核心逻辑和模拟后端测试；只针对确实阻塞真机运行的信息向用户提问。不能把模拟器可运行写成 Pencil 真机体验已验证。

Windows 桥接地址形如 `http://<WINDOWS_LAN_IP>:8190`，其中 `<WINDOWS_LAN_IP>` 是占位符，需替换为实际地址。配对凭据单独私下传递；地址可能随网络变化，以最新配对文件和连通性检查为准。Mac agent 不应把 Windows 路径当作本机路径，也不能假定已经获得远程 Windows 执行通道。先按 [README 的 Mac 模拟后端步骤](../ipad_bridge/README.md#mac-上先联调模拟后端)运行现成服务；真实联调时换用 Windows 配对信息，不改写后端。

## 代码复用与移植边界

先建立 `docs/COMPOSITOR_PORT_MATRIX.md`，按产品需求中的功能类别核查上游。记录源码位置与提交、现有支持情况、可复用/需平台改造/缺失需开发/待验证分类、测试样本和移植状态。不能未经核实声称上游已具备全部 PS 功能，也不能只参考界面后用简单画板替代编辑器核心。

优先阅读以下文件，路径相对于 Compositor-ZH 仓库：

| 路径 | 阅读目的 |
| --- | --- |
| `Compositor/Rendering/EditorCanvas.swift` | 画布与鼠标事件，识别需替换的 AppKit 输入与视图 |
| `Compositor/Rendering/GPUCanvas.swift` | GPU 画布；其中承载视图仍依赖 AppKit |
| `Compositor/Rendering/MetalBrushCoverage.swift` | 画笔 GPU 路径；也有平台依赖，不能直接假定可用于 iPad |
| `Compositor/Document/BrushStroke.swift` | 笔迹数据与绘制算法，评估增加压力、倾斜、采样时间 |
| `Compositor/Document/EditorSession+Brush.swift` | 画笔编辑入口 |
| `Compositor/Document/EditorSession.swift` | 文档、图层插入、编辑事务、撤销历史 |
| `Compositor/IO/ProjectStore.swift` | 工程格式、读写与资源校验 |
| `Compositor/IO/ProjectController+ExternalChanges.swift` | 外部工程变化与重载行为 |
| `docs/project-format.md` | 图层、变换、蒙版与工程版本定义 |
| `docs/writing-comp-files.md` | 外部写入说明及限制，不能替代当前实现 |

按可测试的文档核心、iPad 界面与输入、网络任务客户端、现有 Windows 桥接四个边界开发。Mac agent 负责前三部分，并复用第四部分联调。可以增加共享模块和 iPad target，也可以先用独立 iPad target 验证核心；按源码耦合程度选择，不强行一次性搬完所有文件。

可复用的是部分图层、蒙版、几何、历史和图像算法，以及经过平台依赖处理的渲染代码。AppKit 的 `NSView`、`NSEvent`、菜单、文件面板、光标与窗口行为需要改造。即使文件使用 Metal 或 C，也要检查其中的 AppKit 类型、资源创建与平台 API，不能只按文件扩展名判断可复用。

iPad 输入用 UIKit 的 Pencil 触摸信息接入自有笔刷。PencilKit 可以用于快速验证草图或蒙版输入，但必须标明它与完整 Compositor 笔刷、图层引擎的边界和整合/替换路径。阶段 1 验收前接入可保存重开的文档、图层和撤销核心；不能把单张合成位图、PKDrawing 或网络返回 PNG 作为完整编辑工程的唯一状态。至少实现 Pencil 与手指用途区分、坐标转换、压力输入，以及合理的画布手势；具体笔刷效果与防误触在真机验收。

## 当前系统结构与开发分工

```text
iPad 原生应用
  本地画布与原稿 → 不可变的生成快照 → 生成候选 → 新图层
                    │                         ↑
                    └──── 家庭局域网 ─────────┘
                               │
Windows 桥接服务
  配对认证 → 输入校验 → 持久任务记录 → 结果保存 → 工程备份
                               │
                      本机 ComfyUI API
                               │
                     NVIDIA 显卡执行工作流
```

Windows 任务服务已经使用 Python、FastAPI 与 SQLite 实现，独立于 ComfyUI 的 Python 环境。代码、依赖、启动入口和运行限制都在 `ipad_bridge/`，不要把桥接依赖安装进 ComfyUI 自身环境。Windows 内部 ComfyUI 当前使用端口 `8388`；README 中的 `8188` 是通用示例，不要据此改变当前 Windows 配置。

现有服务可在 Mac 上运行 `mock` 后端，不需要 GPU。按 README 建立 Python 3.12 或以上的独立环境后运行，直接用于 iPad 客户端开发；真实 iPad 访问 Mac 时使用 Mac 的局域网 IP 并配置相应监听地址。模拟后端只验证链路、几何与异常恢复，界面和日志必须明确标记，不能作为 AI 效果或 Windows GPU 联调成功的证据。

## 已实现 API v1 的接入重点

完整字段、约束、请求与响应以 [API v1](../ipad_bridge/docs/API_V1.md) 为准；可直接使用 [示例 metadata](../ipad_bridge/examples/metadata.json) 和 [验证客户端](../ipad_bridge/examples/smoke_client.py)。下面是 Mac 客户端最容易接错的部分，不是第二份独立协议。

| 接口 | 用途 |
| --- | --- |
| `GET /health` | 无认证存活检查；健康不代表 ComfyUI 已就绪 |
| `GET /v1/capabilities` | 当前后端、预设、输入限制与结果 alpha 约定 |
| `GET /v1/backend/status` | 检查后端；即使 HTTP 200 也必须检查 `ok` |
| `POST /v1/jobs` | multipart 上传三个必需 part：`image`、`mask`、字符串表单字段 `metadata` |
| `GET /v1/jobs/{jobId}` | 查询 `queued`、`running`、`succeeded`、`failed` 状态及结果 |
| `GET /v1/jobs?documentId=…&limit=100` | 恢复指定文档的任务列表，当前没有分页游标 |
| `GET /v1/jobs/{jobId}/results/0` | 下载结果，验证 SHA-256，作为新图层使用 |
| `/v1/documents/{documentId}/snapshots…` | 上传、列出、下载不可变 `.comp` ZIP 版本备份，具体方法和路径见 API v1 |

除 `/health` 外的 `/v1/…` 请求全部使用 `Authorization: Bearer …`，包含图片与快照下载。令牌从私下配对文件取得，放入 Keychain，不进 URL 或日志。当前是单个拥有者共享安装令牌，没有在线登录、扫码配对或多用户隔离接口。

任务使用每 1–2 秒轮询，当前没有 WebSocket、百分比进度或取消接口，不实现假的取消按钮。`running` 不保证 GPU 此刻正在采样。界面根据 `backend` 和 `isSimulation` 明确展示模拟模式，失败时不静默切换 mock。

上传与结果处理：

- 所有 `POST`／`PUT` 必须有正确 `Content-Length`，不允许 chunked 上传；可以将 multipart 完整写到临时文件，再用 `URLSession.uploadTask` 上传。
- `metadata` 是 JSON 字符串表单字段；列出的字段都必须有，未知字段会被拒绝。`baseRevision`、`seed` 使用 `Int64`，不要经浮点数转换。
- `image` 统一导出已处理方向的 8 位 sRGB RGBA PNG；`mask` 为同尺寸无 alpha、透明色或 ICC 的 8 位灰度 PNG。蒙版是数值覆盖，不经过颜色管理。
- 所有坐标以文档像素为单位、左上角为原点；`cropRect` 包含上下文并在画布内。`inputSize`、裁切宽高、两个 PNG 实际尺寸必须一致，不先缩小上传。具体尺寸、字节和长宽比限制读取能力并遵循 API v1。
- 输入蒙版白色允许修改，黑色保留，灰色为覆盖权重；没有选区时显式上传全白蒙版，不能省略。
- `workflowPreset` 从能力中选择：mock 为 `mock-paint-v1`，当前真实后端为 `paint-edit-v1`，不是早期草案的 inpaint 预设。
- 返回图已恢复为原裁切尺寸，采用 straight alpha，`maskApplied=true` 表示灰度蒙版已乘入 alpha。**客户端不得再次乘同一个蒙版**；图像解码、预乘转换只按渲染管线正常进行一次。
- 将结果按 `cropRect.x/y` 用普通 source-over 作为新图层合成；黑蒙版位置结果 alpha 为零，保留底图。不要拿结果 RGB 直接替换原裁切。

iPad 在提交前持久保存 `clientRequestId`、metadata、原始 PNG 字节，收到响应后保存 `jobId`。网络重试必须复用这些内容，不能重新编码图片；同一请求内容返回原任务，不同内容复用请求 ID 会得到 409。服务已实现任务对应关系与恢复查询，但 ComfyUI 重启或历史清空仍会影响恢复，不承诺严格一次执行。出现 `submission_unknown` 等错误时不要自动换 ID 重发。

客户端用 `(jobId,resultId)` 防止重复加入图层。候选应用前检查文档 ID 与版本；生成期间继续画或改变画布几何后保留候选，不能自动按旧坐标贴入。图层插入走一次编辑事务，以便撤销和重做，并保留先前历史。

## 已实现的 ComfyUI 接入与能力边界

ComfyUI 接入已封装在 Windows 桥接，iPad 只调用桥接，不直接提交 ComfyUI 图或访问其内部端口。当前真实 `paint-edit-v1` 使用本地 FLUX.2 Klein 4B 做参考图语义编辑，再由服务应用输出蒙版；模型不接收蒙版，`nativeInpainting=false`。不能把它宣传为已实现模型原生蒙版重绘，位置、边缘与画风仍需用户审阅。

Mac 端先接入现成 mock 与验证客户端。切换到 Windows 时先检查能力、后端状态和模型缺项，再进行真实生成；状态检查通过不代表 AI 效果或 iPad 闭环已验收。若需要新预设或原生 inpainting，由 Windows 实现同步扩展 API 能力和测试，客户端不要自行假设支持。

桥接通过 ComfyUI 的上传、任务、队列／历史与结果接口运行固定 API 工作流。节点编辑器界面 JSON 与 API 工作流不同，工作流和模型选择由 Windows 服务维护；iPad 不需要下载整套模型或复制 Photoshop 插件。

官方资料：

- https://docs.comfy.org/development/comfyui-server/comms_routes
- https://github.com/Comfy-Org/ComfyUI/blob/master/script_examples/websockets_api_example.py
- https://docs.comfy.org/tutorials/basic/inpaint

## 为什么不直接搬 Photoshop 插件

参考项目是 Photoshop UXP 插件，依赖 Photoshop 的图像、选区、图层与文件接口。它通过 `/ps/ws` 向 Python 端传数据，再让 ComfyUI 浏览器扩展调用 `app.queuePrompt()`；其共享输入文件、连接路由和客户端状态，不适合作为本项目的多任务恢复协议。

参考其交互思路，开发 iPad 画布适配并接入现有桥接。Windows 桥接已按官方接口独立实现，没有复制 Photoshop UXP 代码；不要复制其插件 bundle、安装更新机制或无认证的局域网通信方式。

该仓库 `License` 在 MIT 描述之外增加了节点修改回馈、插件修改提交及修改版分发等条件，不能按普通 MIT 无条件复用理解。Compositor 复用部分则保留其 MIT、NOTICE 与上游版权。

参考证据：

- https://github.com/NimaNzrii/comfyui-photoshop/blob/main/License
- https://github.com/NimaNzrii/comfyui-photoshop/blob/main/py/Backend.py
- https://github.com/NimaNzrii/comfyui-photoshop/blob/main/js/manager.js

## 工程保存与局域网连接

`.comp` 是工程保存与备份的基础，现有快照 API 已支持不可变 ZIP 归档的上传、列表和原字节下载。首版由 iPad 持有编辑状态，Windows 保存版本和资源，不编辑包内图层，也不设计双端同时修改同一工程。ZIP 结构、64 MiB 归档限制及重试字节一致性等遵循 API v1；快照上传成功不代表所有内部图层内容都已通过编辑器兼容性验收。

API v1 的 8 位 sRGB、4M 输入像素与 64 MiB 快照是当前桥接限制，不是最终编辑器画布、图层、工程大小或颜色精度的产品上限。大工程和更高位深的支持需要分别演进本地核心与网络协议。PSD 导入导出是独立的兼容任务，必须区分保留可编辑图层、仅保留外观与不支持的功能；禁止默认承诺无损往返，也不能静默丢弃不支持的内容。

调查时 `docs/project-format.md` 已记录 v14，而 `docs/writing-comp-files.md` 的简化示例仍使用 v11 与 8 位图片。实际格式以当前 `ProjectManifest.current`、`ProjectStore` 及对应测试为准。若首版只支持基础栅格层，应明确支持范围，对不支持的工程内容拒绝修改或保留原包，不能静默丢失文字、调整层、效果、16 位或 HDR 数据。

现有 Mac 编辑器的外部文件重载会清空撤销历史，有未保存编辑时还会产生冲突。AI 返回结果要通过编辑器内部事务加入新图层并纳入撤销栈，不通过后台覆盖整个 `.comp` 来实现。

连接采用同一路由器下的普通局域网，Windows 可以有线连接路由器。不要把用户说的 Wi-Fi 理解成必须实现 Wi-Fi Direct。当前通过私下传递的配对文件接入，没有扫码配对或自动发现接口。

桥接服务对绘画接口与结果下载执行配对认证，服务数据保存在专用目录。iPad 使用配对文件中的 Windows 局域网地址；iPad 的 `127.0.0.1` 只代表 iPad 自己。ComfyUI 由桥接访问 Windows 本机地址，例如 `http://127.0.0.1:8188`，不要求直接公开到局域网或互联网。公开仓库与源码交接包不含配对凭据，单独私下传递。

原生 iPad App 声明 `NSLocalNetworkUsageDescription`；以后采用 Bonjour 时再声明相应服务类型。处理目标系统的 ATS 与 HTTPS 策略，不全局关闭网络安全校验，不在日志写出配对令牌。HTTP 仅用于受信任局域网，Bearer token 不加密网络流量。iPad 进入后台后可能挂起，恢复时查询持久任务，而不是依赖持续连接。

## 开发里程碑与验收

下面与产品需求的阶段 0–4 对齐。阶段 1 的 AI 链路验收并不结束 iPad 编辑器开发。

### 阶段 0 上游盘点与核心方案

建立 Compositor 功能与平台依赖清单，确认文档、图层、渲染和撤销的复用方式；建立原生 iPad target。早期确定图层组、混合、蒙版、变换、调整参数的扩展方式，不要求首版一次实现全部工具。

### 阶段 1 接入现有 mock 与 Windows，完成 iPad 原生闭环

按现有 README 在 Mac 启动模拟桥接，先运行现成验证客户端确认环境，再实现原生 iPad target 与 API v1 客户端。iPad 能打开图片、画蒙版、提交任务、看到候选、插入新图层和撤销。此阶段复用服务、mock 和适配器，不重复开发后端；清楚记录模拟器与 iPad 真机各自的验证范围。

再使用私下交付的 Windows 配对文件，完成真实任务、结果回填、锁屏恢复与故障恢复验证。Windows 本机真实 GPU 已验证，不能代替 iPad 真机和跨设备局域网验收。网络尚未可用时继续不依赖网络的编辑器工作。

### 阶段 2 常用绘画与合成

推进完整常用笔刷体验、图层组、混合模式、剪贴关系、蒙版、选区及自由变换，本地自动保存和恢复。Windows 关机时仍能完成多图层绘画/合成、保存重开与导出。

### 阶段 3 常用图像编辑

推进色阶、曲线等可编辑调整，修复/仿制、常用滤镜、文字与形状、透视/变形及逐步液化。按具体功能验证编辑性、选区作用域、撤销及工程重开，不用只有界面的占位工具作为完成依据。

### 阶段 4 日常使用版本

完善文件交换与 PSD 支持矩阵、性能、内存与稳定性、常用功能完整度及 AI 工作流体验。用用户真实绘画和修图任务检验发布范围，记录设备条件和未支持内容。高级印前、HDR、智能对象等专项兼容按产品需求单独评估。

| 必须验证的行为 | 验收标准 |
| --- | --- |
| 坐标与缩放 | 非方形画布、边缘选区、有上下文边距时，结果仍准确回到原位置，不翻转、不偏移 |
| 蒙版保护 | 在受控的 sRGB 测试画布上，蒙版覆盖之外的合成像素与原稿一致；边缘过渡符合预期 |
| 保留原稿 | 输入图层不被覆盖，AI 候选以新图层加入，透明度和显示隐藏可调整 |
| 撤销重做 | 一次撤销撤回本次 AI 图层插入，重做恢复；先前绘画历史仍有效 |
| 多文档与旧结果 | A 文档结果不会进入 B 文档；生成期间改画或改尺寸，不自动覆盖新内容 |
| 请求重试 | 网络重试不新增重复任务，重复收取结果不新增重复图层 |
| 锁屏与断网 | Windows 继续运行任务，iPad 恢复后能按任务 ID 找回结果 |
| 服务恢复 | 桥接重启后已有任务与结果仍可查询，异常任务有明确状态 |
| 失败展示 | 模型或节点缺失、服务不可达、生成失败均有可操作的信息，没有永久转圈或静默替代结果 |
| 原生输入 | 真机验证 Pencil 画笔或蒙版、画布手势与可接受的响应；记录实际设备和测试画布 |
| 工程保存 | 支持范围内的工程重开保持图层、位置、蒙版和透明度；不支持内容不被静默损坏 |
| 离线编辑 | Windows 关机或网络断开时，本地绘画、图层操作、撤销、保存和导出继续可用 |
| 长期功能覆盖 | 按产品功能清单和上游移植矩阵逐项验收；AI 闭环完成不等于完整编辑器完成 |

几何、蒙版和任务恢复适合自动测试；Pencil 手感、内存压力及系统后台行为需要真机测试。不要为不可复现的 AI 画面写精确像素期望测试；精确像素保护测试应使用受控输入与确定性后端。

## Windows 现有材料清单

Mac 克隆本仓库即可同时取得本交接文档和 `ipad_bridge/` 源码目录，保留相对目录关系；只传这一份 Markdown 不足以运行现成 mock。Git 用于共享代码、测试和文档，**不要把 `data-*/`、运行时数据、token 或 `pairing.json` 放入公开仓库或交接包**；真实凭据另行私下交付。Mac 端复用现有协议、mock 和真实适配器。

优先接收的材料：

- [桥接安装与启动说明](../ipad_bridge/README.md)
- [API v1](../ipad_bridge/docs/API_V1.md)
- [metadata 示例](../ipad_bridge/examples/metadata.json)
- [HTTP 验证客户端](../ipad_bridge/examples/smoke_client.py)
- `ipad_bridge/bridge/`、依赖文件、测试及 Windows 启动脚本

所有仓库内路径均相对于各自机器上的克隆目录。ComfyUI 安装、共享模型、图像、运行数据库和配对文件由各台机器在本地配置，不随 Git 同步。Compositor 与参考插件通过前述公开链接查阅，不依赖开发者 Windows 上的调查副本。

当前桥接真实预设是 API v1 规定的 FLUX.2 Klein 参考编辑，所需模型为 `flux-2-klein-4b-fp8.safetensors`、`qwen_3_4b.safetensors` 与 `flux2-vae.safetensors`，以桥接 README 和已认证的后端状态为准。历史 Qwen 编辑工作流未纳入本仓库，不属于首期 Mac 接入要求。模型存在、状态检查通过都不代替真实生成报告；历史 Windows 验证记录也不等于 iPad 画稿闭环已完成。Mac 前端开发先使用 mock，无需下载模型。

## 交付给用户的内容

- 可构建的 iPad 工程和实际完成范围。
- 接入现有桥接的网络客户端、私有配对文件导入与本地任务恢复。
- 客户端与 API v1 的对应说明；若需要协议变化，列明与 Windows 实现共同完成的修改。
- Mac 上的构建与测试结果；真机、真实 Windows 联调分别列明结果。
- 一段演示或清晰截图：输入原稿、蒙版、生成候选、准确回填后的图层。
- 尚需用户提供的最少信息，例如私下配对文件、签名团队或真机访问；Windows 实际地址从配对文件取得，不重复询问已决定的平台路线。

用户目标是日常可用、覆盖 Photoshop 大多数常用功能的原生 iPad 绘画与图像编辑软件。完成最小闭环后继续推进已确定的产品路线，再用实际绘画反馈调整实现顺序和体验。

## Apple 开发参考

- Xcode 环境：https://developer.apple.com/xcode/system-requirements
- Pencil 输入：https://developer.apple.com/documentation/uikit/handling-input-from-apple-pencil
- PencilKit：https://developer.apple.com/documentation/pencilkit
- Metal 示例：https://developer.apple.com/metal/sample-code/
- 局域网权限：https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy
- 本地网络 ATS：https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking
- App 后台生命周期：https://developer.apple.com/documentation/uikit/preparing-your-ui-to-run-in-the-background
