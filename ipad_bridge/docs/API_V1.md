# Compositor 本地桥接接口 v1

本文对应 `ipad_bridge/bridge/` 的当前实现。Windows 桥接已经实现；Mac agent 应直接接入此协议，开发原生 iPad 画布、任务客户端与图层导入，无须重新开发一套 Windows 服务。背景、移植边界和真机验收见 [Mac 开发交接](../../docs/MAC_AGENT_HANDOFF.md)。本文规定接口行为，不代表 iPad 安装、Apple Pencil 手感、锁屏恢复或真实 GPU 效果已经完成验收。

## 连接与配对

服务默认端口为 `8190`。Windows 启动时需选择可供局域网访问的监听地址；Mac 和 iPad 使用 Windows 的局域网 IP。客户端的 `127.0.0.1` 只指向客户端自己。ComfyUI 地址属于 Windows 服务内部配置，不是 iPad 的请求地址。

私下交付的 `pairing.json` 包含：

```json
{
  "protocolVersion": 1,
  "baseUrl": "http://192.168.1.20:8190",
  "accessToken": "从Windows生成的私有配对文件读取",
  "backend": "comfyui"
}
```

上面是字段示意，地址与令牌不是实际连接信息。`backend` 为 `comfyui` 或 `mock`。`baseUrl` 是 HTTP(S) origin，不带路径、查询参数或用户名密码。服务支持配置 TLS 证书；使用 HTTPS 时应正确配置客户端信任，不关闭证书验证。局域网 HTTP 传输不加密，令牌只适用于已信任的本地网络。不要将服务直接开放到互联网。

除 `GET /health` 外，所有 `/v1/…` 接口，包括能力、状态、列表、图片下载、快照下载和 OpenAPI，都必须携带：

```http
Authorization: Bearer <accessToken>
```

令牌放在请求头，不放在 URL 或日志；iPad 保存在 Keychain。当前是单个拥有者的一套安装共享令牌，不提供多用户隔离、在线登录、设备撤销或扫码配对接口。配对文件由 Windows 端生成后交给客户端，不从无认证接口下载。

所有 `POST`/`PUT` 必须提供一个正确的 `Content-Length`，禁止 `Transfer-Encoding`，包括 `chunked`。iPad 可把完整 multipart 写入临时文件，设置文件长度，再用 `URLSession.uploadTask` 上传。不要使用未知长度的数据流。请求总大小上限为 66 MiB；单张图像或蒙版最多 20 MiB。

## 先确认服务能力

iPad 端还需要本地网络访问用途说明和实际权限测试；按当前 SDK 的本地网络与 ATS 规则配置连接，优先可信 HTTPS。开发期 HTTP 例外限定于本地目标，不能加入全局禁用验证或忽略证书的回调。手动输入地址时不需要为了发现服务额外引入 Bonjour。请参考交接文档列出的 Apple 官方说明，并分别验证模拟器和真机。

| 请求 | 返回与用途 |
| --- | --- |
| `GET /health` | `status`、`service`、`version`、`protocolVersion`；正常 200，worker 异常时 503。此接口存活不等于 ComfyUI 可用 |
| `GET /v1/capabilities` | 当前后端、预设、输入限制、结果透明度约定 |
| `GET /v1/backend/status?presetId=…` | 检查指定预设；省略参数检查默认预设。真实后端检查节点和模型，不能把它当成生成效果验证 |
| `GET /v1/openapi.json` | 需认证的 OpenAPI；复杂 metadata 字符串的约束仍以本文为准 |

真实后端能力响应示例：

```json
{
  "protocolVersion": 1,
  "backend": "comfyui",
  "isSimulation": false,
  "defaultPreset": "paint-edit-v1",
  "presets": [{
    "id": "paint-edit-v1",
    "presetVersion": "1.0.0",
    "default": true,
    "experimental": false,
    "enabled": true,
    "configured": true,
    "technique": "reference_edit_with_output_mask",
    "nativeInpainting": false,
    "maskAppliedToOutput": true
  }],
  "maxPendingJobs": 8,
  "maxPendingBytes": 268435456,
  "maxInputPixels": 4194304,
  "maxImageBytes": 20971520,
  "minInputSide": 16,
  "maxInputAspectRatio": 16,
  "maxSnapshotBytes": 67108864,
  "snapshotFormat": "comp-zip",
  "progressTransport": "polling",
  "cancelSupported": false,
  "jobDeletionSupported": true,
  "pairingScope": "single-owner-installation",
  "resultAlphaMode": "straight"
}
```

示例省略了预设的详细描述字段与实验预设。真实后端使用服务端白名单 registry；`paint-edit-v1` 始终排在 `presets[0]`，兼容已有客户端默认选择逻辑。新增的 `defaultPreset` 是默认 ID。列表可以包含禁用或配置损坏的预设，不能把“出现在列表”视为可生成。

每个真实预设可带 `name`、`description`、`presetVersion`、`graphHash`、`experimental`、`enabled`、`configured`、`error`、`license`、`precision`、`scenarios`、`inputRoles`、`controls`、`limits`、`dependencies` 和 `qualification`。`enabled` 表示开关允许，`configured` 表示预设配置及固定图摘要通过检查；两者均不证明本机已经装好模型。`controls` 中 `editable=false` 的设置是固定组合，不能由客户端另传同名 metadata 字段。

`qualification` 分别记录 `installed`、`structuralPreflight`、`gpuSmoke`、`qualityAdmission`。能力目录的前两项为 `not_checked`，GPU 为 `not_checked`，美术质量为 `pending`；这是明确的未验证状态。客户端应请求所选预设的 backend/status 获取当前依赖检查，不把能力目录、一次结构检查或曾经生成成功提升为质量准入。未识别的响应扩展字段应忽略；请求 metadata 仍严格拒绝未知字段。

`mock` 后端只提供 `mock-paint-v1`，`isSimulation=true`，`technique=simulation`，最短边为 1、长宽比限制为 `null`。它返回确定性的染色测试图，不执行 AI；界面必须明确显示模拟模式。不要把真实预设交给模拟后端，或在生成失败时静默切换模拟。

`paint-edit-v1` 使用本地 FLUX.2 Klein 4B 做参考图语义编辑，约 1 MP、4 步，再恢复输入裁切尺寸。模型不接收蒙版；服务最后将蒙版应用到结果透明度。这不是原生蒙版 inpainting，位置与边缘效果需要用户审阅。

真实 `/v1/backend/status` 返回 `ok`、`presetId`、`technique`、`missingNodes`、`missingModels`、`invalidInputs`、`backend`、`isSimulation`，新增 `installed`、`structuralPreflight`、`gpuSmoke`、`qualityAdmission`、`dependencyIdentityConfigured` 与 `executorHeld`。前两项是本次预检布尔值，`gpuSmoke=unverified`、`qualityAdmission=pending` 不会因预检通过变成通过。`dependencyIdentityConfigured` 只表示已配置本机模型和安装路径，入队仍需核对实际运行实例、权重及源码摘要。`executorHeld=true` 表示有尚未释放的推理占用记录，可能已在 GPU 完成但尚未由后续调度确认释放。

当占用记录绑定的 ComfyUI endpoint 与当前连接不一致，或旧记录没有绑定地址时，状态接口直接返回 HTTP 200、`ok=false`、`executorHeld=true` 及 `error.code=executor_connection_mismatch`；此时不访问当前实例进行预检，不返回原始连接地址，也可能省略结构预检字段。恢复原连接或在 Windows 完成明确的人工恢复后再检查。仅新实例空闲不能证明原实例已停止执行。

缺节点或模型时可能是 HTTP 200 且 `ok=false`；不可连接、未知或禁用预设返回 503 与 `error`。客户端必须检查 `ok`，不能只检查 HTTP 状态。缺少某个实验预设的依赖不会使其他预设自动不可用。实验 `qwen21-edit-v1` 与 `qwen21-turbo-edit-v1` 默认关闭，需要 Windows 明确开启；两者仅供研究或评估，商业使用需另获模型许可。当前固定组合、部署及 Mac 选择器交接见 [Windows v0.2](../../docs/WINDOWS_PRESETS_V02.md)。

## 创建绘画任务

`POST /v1/jobs` 使用 `multipart/form-data`，三个 part 都必须存在：

| part 名称 | 内容 |
| --- | --- |
| `metadata` | UTF-8 JSON 字符串的表单字段；不是一个 JSON 文件上传字段 |
| `image` | 当前裁切区域的合成图，推荐 8 位 sRGB RGBA PNG，MIME `image/png` |
| `mask` | 与图像完全同尺寸的 8 位灰度 PNG，Pillow 模式 `L`，无 alpha、透明色或 ICC，MIME `image/png` |

输入图允许可转换的常见 8 位 PNG 模式，服务会规范成 sRGB RGBA；客户端统一导出 RGBA8 最容易保持一致。输入已完成方向处理，不携带需要旋转的 EXIF orientation。不接受动画、16 位或 HDR PNG。图像应附正确 sRGB ICC；未标记的输入按显式声明的 sRGB 处理，矛盾的 gamma 或色度信息会被拒绝。数值蒙版不能经过图像颜色管理。

白色 `255` 表示允许修改，黑色 `0` 表示保留，灰色表示覆盖权重。无选区时显式上传全白蒙版；缺失蒙版不会自动变成全画布编辑。建议在选区周围包含上下文。真实后端要求输入最短边至少 16 像素、长宽比不超过 16:1；不要把细长笔迹本身当成整个裁切框。

完整示例见 [metadata.json](../examples/metadata.json)。所有列出的字段都必须存在；未知字段和嵌套未知字段都会被拒绝：

```json
{
  "protocolVersion": 1,
  "clientRequestId": "aed22bac-33ae-49a5-a5d5-a709a0754e62",
  "documentId": "cc960248-ea31-43b9-ac82-a0716045f048",
  "baseRevision": 17,
  "sourceLayerIds": ["layer-uuid"],
  "canvasSize": {"width": 2048, "height": 1536},
  "cropRect": {"x": 512, "y": 384, "width": 512, "height": 384},
  "inputSize": {"width": 512, "height": 384},
  "colorSpace": "sRGB",
  "maskConvention": "white_edit_black_preserve",
  "workflowPreset": "paint-edit-v1",
  "prompt": "保持轮廓，尝试丝绸材质和侧面光",
  "seed": 123456
}
```

具体约束：

- `protocolVersion` 固定为整数 `1`；整数位置不能用布尔值或小数。
- `clientRequestId`、`documentId`、各层 ID 为 1–128 个 ASCII 字母、数字、下划线或连字符；建议使用小写标准 UUID。`sourceLayerIds` 最多 256 项，允许空数组。
- `baseRevision` 和 `seed` 是 `0…9223372036854775807` 范围的整数；Swift 用 `Int64`，避免经浮点数转换丢失精度。
- `canvasSize` 和 `inputSize` 只能有 `width`、`height`；每个维度是 `1…30000` 的整数。
- `cropRect` 只能有 `x`、`y`、`width`、`height`；必须完全位于画布内。单位是文档像素，左上角原点，与屏幕 points、缩放和设备像素无关。
- 首版要求 `inputSize == cropRect` 的宽高，两张 PNG 的实际尺寸也必须相等；不接受客户端另行缩小上传。裁切像素总量最多 `4194304`。
- `colorSpace` 固定 `sRGB`，`maskConvention` 固定 `white_edit_black_preserve`。
- 新任务的 `workflowPreset` 必须是当前服务允许的预设；真实后端同时检查 `enabled`、图摘要、依赖与该预设的 `limits`。客户端应采用全局限制与所选预设限制中较严格的一项。旧请求重放仍使用当时接受的记录，不因当前预设被关闭或移除而重新解释。
- `prompt` 最多 4000 个字符，必须是有效 Unicode；真实后端不可为空或全空白。metadata 表单字段的 UTF-8 编码长度最多 16384 字节。

新任务返回 **202**，相同任务重试返回 **200**。两者都是同一结构，见下一节。`clientRequestId` 在整套服务中唯一，创建前应在 iPad 持久保存。相同 ID、相同 metadata 内容和相同原始图片/蒙版字节返回原 `jobId`；相同 ID 对应不同内容返回 **409** `request_conflict`。重试时不要重新编码 PNG，即使肉眼看起来相同也可能得到不同字节。用户主动要求新的生成时才分配新请求 ID。

多预设不增加请求字段：仍只上传一张 image、一张 mask，返回单个 `results/0`。没有多参考、候选数、用户工作流 JSON、模型文件路径或下载 URL 参数。蒙版是 `compositeMask`，所有当前预设均在输出 alpha 应用一次，不把它伪装为原生模型条件。

真实任务入队前冻结预设版本、图及摘要、固定参数、seed、输入角色和几何、规范化输入摘要、权重 SHA-256，以及受控 ComfyUI 源码和运行依赖证据。排队后不再读取新版图来替代旧任务；依赖或输入改变会明确失败，不静默换模型、降低参数或换种子。响应可增加 `execution={"presetVersion":"…","graphHash":"…","dependencyFingerprint":"…"}`，仅用于溯源，不公开工作流、输入内容或本机路径。

私人执行快照另冻结 `comfyOrigin`，它不属于请求 metadata 或公开 `execution` 字段。连接地址变更后，旧未提交任务以 `backend_changed` 失败，旧已提交任务保留状态等待原连接恢复；不会把旧 prompt ID 交给另一个实例查询或执行。

默认最多 8 个排队/运行任务，规范化的 image 与 mask 合计最多 256 MiB。超过任一限制返回 **429** `queue_full` 和 `Retry-After: 5`；保持同一请求 ID 与原始字节稍后重试。容量限制先核对已存在请求，因此队列已满、ComfyUI 离线或预设被移除时，相同请求仍返回原任务。容量限制不是整个缓存目录的磁盘配额，终态缓存仍需通过删除接口清理。

## 查询、断线恢复与结果

| 请求 | 用途 |
| --- | --- |
| `GET /v1/jobs/{jobId}` | 查询单个持久任务 |
| `GET /v1/jobs?documentId=…&limit=100` | 返回 `{"jobs": […]}`；新任务在前，`limit` 为 1–100；省略 documentId 查询全部。当前没有分页游标 |
| `GET /v1/jobs/{jobId}/results/0` | 下载完成结果；未完成或结果不存在返回 404 |
| `DELETE /v1/jobs/{jobId}` | 可选能力：删除已结束任务的桥接缓存；成功或重复删除均返回 200 |

建议每 1–2 秒轮询；无 WebSocket、百分比进度或取消接口。状态为 `queued`、`running`、`succeeded`、`failed`。`running` 包括等待 ComfyUI 可用、提交与执行阶段，不意味着 GPU 此刻一定正在采样。

完成任务响应示意：

```json
{
  "jobId": "server-generated-uuid",
  "clientRequestId": "original-client-request-id",
  "state": "succeeded",
  "backend": "comfyui",
  "isSimulation": false,
  "createdAt": "2026-10-19T14:30:00Z",
  "updatedAt": "2026-10-19T14:30:20Z",
  "source": {
    "documentId": "cc960248-ea31-43b9-ac82-a0716045f048",
    "baseRevision": 17,
    "sourceLayerIds": ["layer-uuid"],
    "canvasSize": {"width": 2048, "height": 1536},
    "cropRect": {"x": 512, "y": 384, "width": 512, "height": 384},
    "inputSize": {"width": 512, "height": 384},
    "colorSpace": "sRGB"
  },
  "workflowPreset": "paint-edit-v1",
  "error": null,
  "results": [{
    "resultId": "0",
    "url": "/v1/jobs/server-generated-uuid/results/0",
    "mimeType": "image/png",
    "width": 512,
    "height": 384,
    "cropRect": {"x": 512, "y": 384, "width": 512, "height": 384},
    "colorSpace": "sRGB",
    "alphaMode": "straight",
    "maskApplied": true,
    "sha256": "64-character-hex-digest",
    "bytes": 12345
  }]
}
```

未完成或失败时 `results=[]`；失败时 `error={"code":"…","message":"…"}`。结果 URL 相对于配对 origin，下载仍需 Bearer。验证响应头 `X-Content-SHA256`、结果描述的 SHA-256 和下载字节一致。服务返回 `Cache-Control: private, no-store`；客户端可自行将已验证图片保存到其私有文档目录。

结果是**新图层用的裁切 RGBA PNG**，不是整张原稿或已经压平的画面。服务已恢复裁切宽高，图层在原文档 `(cropRect.x, cropRect.y)` 放置，使用普通 source-over 混合。PNG 使用 straight / unassociated alpha；由图像解码器按渲染管线要求进行一次预乘，不手动再次预乘已解码的 premultiplied buffer。

`maskApplied=true` 意味着灰度覆盖已经乘入结果 alpha。**不要再次乘同一蒙版，也不要把灰色覆盖重复套在图层上**，否则软边会变淡。黑蒙版位置输出 alpha 精确为零；灰蒙版按 `floor(generatedAlpha × mask / 255)` 处理。使用透明图层覆盖保留原稿，不用结果 RGB 直接替换整个裁切。

客户端用 `(jobId,resultId)` 记录已插入图层，重复下载不能新增重复图层。候选应用前检查 `source.documentId`、版本、原画布尺寸与裁切位置。文稿已经继续编辑时，默认保留候选并提示版本变化，不自动回填；用户预览后可明确确认按生成时的原位置加入独立新图层。该确认只放行旧版本，不放宽其他检查：候选必须属于当前文稿，源版本不得晚于当前版本，原画布尺寸必须与当前一致，裁切必须位于画布内；确认后又发生编辑时应重新确认。插入保留现有图层，走编辑器单个可撤销事务，不通过替换整个 `.comp` 工程触发重载。

iPad 将 `clientRequestId`、`jobId` 和提交快照保存到本地。锁屏、断线或进程重开后查询原任务；Windows 继续执行并保存结果。桥接会从 ComfyUI 队列/历史恢复提交 ID，结果未知时不会自动再次提交。`submission_unknown`、`task_not_found` 或 `job_timeout` 失败不代表 GPU 一定从未执行；先核对 Windows 状态，再由用户决定是否新建请求。ComfyUI 自身重启或清空历史会限制恢复能力，不承诺严格“一次执行”。

桥接在提交前持久记录推理占用。超时、任务失败或删除终态缓存不自动释放该占用；后续任务须确认 ComfyUI 队列已空闲。提交结果未知且没有 prompt ID 时，仅看到空队列仍不足以证明请求没有在途，需先从队列或历史找回对应提交；无法找回时保持阻塞，交给 Windows 端检查。迟到的结果或失败回调不能覆盖已确定的任务终态，也不能复活墓碑。没有新增取消或强制清空占用的 HTTP 接口。

占用绑定原 ComfyUI endpoint，跨重启和终态删除仍保留。当前连接与绑定地址不一致，或旧记录地址未知时，自动对账保持阻塞；不能把新连接的空队列当作释放证据。人工恢复工具要求先停止桥接并明确确认原 ComfyUI 实例已完成重启；绑定过地址的记录还必须使用匹配的地址，旧未知地址记录也不能省略人工确认。

## 删除不需要的候选

删除是 API v1 的可选扩展：仅在 `capabilities.jobDeletionSupported == true` 时调用；旧服务缺少此字段时视为不支持远端删除。此能力不改变 `cancelSupported=false`。删除按一次生成任务执行，包含其全部结果；当前预设通常每次返回一个结果。客户端可另行移除本机候选，但应说明旧服务仍保留远端文件。仅本机移除的候选可以重新显示并按需下载，前提是服务仍保留结果；这不能恢复已经远端删除的文件。

认证后调用 `DELETE /v1/jobs/{jobId}`，无请求体。只允许删除 `succeeded` 或 `failed` 的任务，成功返回：

```json
{"jobId":"server-generated-uuid","deleted":true}
```

`queued`、`running` 返回 **409** `job_not_finished`，任务继续运行，不会被取消。未知任务返回 **404**。重复删除已删除的任务仍返回相同的 **200** 回执。

删除清理桥接数据目录中该任务的输入图、蒙版、工作流与结果；已保存的 `.comp` 工程备份不受影响，已经回填进工程的图层也不受影响。ComfyUI 自己的 input/output 目录不在本接口的清理范围内，不能把此操作描述成清空所有生成占用。

冻结执行快照中的提示词、图及依赖详情也会清除。如果这个终态任务仍可能在 ComfyUI 执行，另行保留最小的任务 ID、prompt ID、原 ComfyUI endpoint、时间与原因作为私人调度占用记录；它不包含画稿或完整 metadata，地址不通过 API 返回。删除成功不等于 GPU 已空闲，更不等于取消。

服务先持久记录最小删除标记，再清理文件。删除标记保留任务 ID、原 `clientRequestId`、请求摘要及必要的状态信息，不保留完整 metadata、提示词或图片。已删任务不会出现在任务列表或待执行队列中；查询任务、下载结果或以原 `clientRequestId` 再次提交均返回 **410** `job_deleted`，不能自动重新生成。用户主动生成新候选时使用新的 `clientRequestId`。

文件被占用或清理失败时返回 **503** `job_deletion_incomplete`，此时删除标记可能已经生效，任务仍不会重新运行。客户端在发送用户确认的删除请求前持久保存待删除记录；再次 DELETE 或桥接服务重启会继续清理，只有收到与所选任务匹配的 200 回执才确认桥接文件已删除并完成本地清理。超时或 503 后保留重试入口，重开应用也不能丢掉该状态。后续 GET 的 410 只证明任务已不可用，不能代替清理完成回执。已删除文件无法从候选区恢复。

Windows 升级保留原数据目录和配对配置，重启后通过 capability 确认此扩展可用。执行过删除的数据库含 `deleted` 墓碑；旧桥接版本不能正确读取这些记录，因此不宜直接回退旧服务代码并继续使用该数据库。不要手动删除墓碑来绕过兼容问题，否则原请求 ID 可能再次触发生成。升级操作见 [桥接 README](../README.md#升级候选删除能力)。

## 工程版本备份

快照 API 保存不可变的 `.comp` ZIP 归档，原字节往返。它不编辑图层、不渲染工程，也不实现双端逐笔同步。

| 请求 | 请求体／返回 |
| --- | --- |
| `POST /v1/documents/{documentId}/snapshots/{revision}` | multipart 的 `archive` 文件，MIME `application/zip`；带 Content-Length；成功 200 返回快照元数据 |
| `GET /v1/documents/{documentId}/snapshots` | `{"snapshots": […]}`，revision 从小到大 |
| `GET /v1/documents/{documentId}/snapshots/{revision}` | 原始 ZIP，`application/zip`；带 `X-Content-SHA256` |

元数据格式为 `documentId`、`revision`、`sha256`、`bytes`、`createdAt`、`projectVersion`。`revision` 范围为 `0…9223372036854775807`，它是备份版本号，不是项目文件格式版本。相同文档版本重复上传相同 ZIP 字节返回原元数据；不同字节返回 **409** `snapshot_conflict`。ZIP 时间戳或压缩结果变化也会改变字节，因此重试必须保存原归档。

接受两种 ZIP 结构：根目录的 `manifest.json` 和资源目录，或单个顶层 `Name.comp/` 包中包含这些内容。不要附带 `__MACOSX/` 等第二个顶层目录。只支持 Stored 或 Deflate ZIP；禁止加密、符号链接、绝对路径、`..`、Windows 不安全名称和大小写/Unicode 路径冲突。

当前限制：归档最多 64 MiB、解压后最多 256 MiB、最多 2000 个条目、manifest 最多 4 MiB；超高压缩比归档会被拒绝。manifest 必须包含 `format="com.compositor.project"`、整数 `version` 为 1–14、与 URL 匹配的 `documentID`，以及数组 `layers`。UUID 形式的文档 ID 会规范化为小写。`imageFile`/`maskFile` 引用必须对应存在的 `images/` 资源。

服务核验归档与引用并保存原字节，不验证某个 Compositor 编辑器一定能打开所有内部图层功能；客户端仍负责正确导出工程。未知 manifest 字段与资源原样保留。不要把“快照上传成功”写成完整 Compositor 文档兼容性已验证。

## 错误与客户端处理

HTTP 错误统一形如 `{"error":{"code":"…","message":"…"}}`；字段验证还可能附带 `details`。常见响应：

| HTTP | 典型原因 |
| --- | --- |
| 400 | `invalid_framing`：重复 Content-Length 或 Transfer-Encoding |
| 401 | `unauthorized`：配对凭据缺失或错误 |
| 404 | 任务、结果或快照不存在 |
| 409 | 相同请求 ID／工程版本对应不同内容；`job_not_finished`：任务尚未结束，不能删除 |
| 410 | `job_deleted`：任务已删除，不能以原请求 ID 重新生成 |
| 411 | `length_required`：没有合法 Content-Length |
| 413 | 请求或单个文件过大 |
| 422 | metadata、图像、蒙版或归档无效 |
| 429 | `queue_full`：排队数量或待处理输入字节预算已满，保留原请求稍后重试 |
| 503 | worker 不可用、ComfyUI 暂不可达、选中预设禁用或缺依赖，或 `job_deletion_incomplete`：文件清理需重试 |

创建成功后发生的生成失败记录在 job 的 `error` 中，`GET /v1/jobs/{id}` 仍返回 200。客户端分别处理 HTTP 失败和任务状态失败，避免永久转圈。

新增错误包括 `dependency_identity_unavailable`、`runtime_identity_unavailable`、`dependency_changed`、`input_changed`、`legacy_snapshot_missing` 和 `execution_contract_unsupported`。旧数据库中尚未提交、没有执行快照的 GPU 任务不会套用新配置重新生成；已记录提交过程或 prompt ID 的旧任务继续按原 ID 对账。OOM 明确失败，不自动切模型或缩图。升级前应完成旧队列，详见 [升级与回退](../../docs/WINDOWS_PRESETS_V02.md#升级与回退)。

## 可直接运行的联调客户端

[smoke_client.py](../examples/smoke_client.py) 只依赖 `httpx`、`Pillow`，可在 Mac 的 Python 环境或本项目虚拟环境运行：

```sh
python examples/smoke_client.py --pairing /private/path/pairing.json --output smoke-output --timeout 900
```

它会生成 512×384 色块画稿和含黑、灰、白区域的 L8 蒙版，读取服务能力选择正确预设，检查后端就绪、提交两次验证同一任务、查询文档任务列表、轮询并下载结果。真实后端会执行一次实际 GPU 生成；模拟后端只验证链路。

输出包括 `input.png`、`mask.png`、`metadata.json`、`result.png`、`composite.png` 和不含令牌的 `report.json`。报告核验请求幂等、来源和裁切位置、图片尺寸、SHA-256、蒙版外 alpha 为零，以及合成后蒙版外像素保持原样。退出码 0 表示这些检查通过，1 表示失败。它不评价 AI 美术质量，不测试 Pencil，也不替代快照与真机验收。

网络超时后用同一 `--output` 重跑，会复用持久保存的请求 ID 与 PNG 字节；要开始新的测试生成，换一个输出目录。不要手动修改旧输出目录中的 metadata 或输入图片后继续重试。
