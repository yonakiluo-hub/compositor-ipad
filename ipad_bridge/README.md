# Compositor Local Bridge v0.2

iPad 绘画 → 局域网上传画面和蒙版 → Windows ComfyUI 生成 → iPad 新图层。

本目录是 Windows 侧可运行服务，也可以在 Mac 上使用模拟后端供 iPad 客户端开发。iPad 应用另由 Mac agent 实现。这里不包含 Procreate 插件，也不包含 Windows 绘图编辑器。

完整产品目标是以 Compositor 为基础、覆盖 Photoshop 大多数常用功能的原生 iPad 编辑器，见 [产品需求](../docs/PRODUCT_REQUIREMENTS.md)。此目录只负责其中的 AI 与备份服务，普通绘画和编辑应在 iPad 离线运行。

## 现在能做什么

- 带认证的画面、蒙版上传、持久任务队列与结果下载。
- 重复提交同一请求返回同一任务；服务重启后查询已有 ComfyUI 任务，不盲目重复生成。
- 根据原裁切尺寸和位置返回透明 PNG，服务端已把蒙版应用到结果 alpha。
- 可选的已结束任务删除：清理桥接输入、蒙版、工作流和结果，保留最小删除标记以避免旧请求重新生成。
- `.comp` ZIP 工程版本备份、完整性校验与恢复下载；这不是逐笔实时同步。
- `mock` 后端不需要显卡，返回明确标有 MOCK 的图像；`comfyui` 后端调用本机 ComfyUI。

首个真实预设使用 FLUX.2 Klein 4B 的参考图编辑，再用原蒙版限定返回图层。**蒙版目前不参与模型的去噪过程，尚未实现模型原生局部重绘。** 因此绘画风格、局部边缘融合和满意度仍需要用户试画评估。

Windows v0.2 增加共享预设目录、入队执行快照、依赖核验、队列预算与超时后的推理占用保护。Klein 保持默认；Qwen-Image-2.1 与 Turbo 是默认关闭的研究评估项。真实后端新增本机模型与 ComfyUI 安装目录配置，启动、Mac 选择器交接及升级回退见 [Windows 多预设增量说明](../docs/WINDOWS_PRESETS_V02.md)。多预设仍沿用单图、单蒙版、单结果的 API v1，不代表新模型已通过绘画质量验收。

## 开发顺序

1. Windows 服务与 API v1 固定，Mac agent 同时建立原生 iPad 画布和网络客户端。
2. Mac 本机运行 `mock`，验证裁切坐标、蒙版、结果图层、一次撤销、断网恢复。
3. iPad 和 Windows 连同一个局域网，换成 Windows 配对信息，完成真实生成闭环。
4. 闭环通过后，按产品需求继续推进完整常用编辑功能；Windows 侧同步完善 AI 预设、备份与恢复能力。

Mac agent 从 [API v1](docs/API_V1.md)、[示例请求](examples/metadata.json) 和 [验证客户端](examples/smoke_client.py) 开始。旧交接文档中的接口草案由 API v1 替代。

## Windows 安装和启动

需要 Python 3.12 或以上。桥接服务使用独立环境，无需安装 PyTorch。ComfyUI 使用用户现有环境。

在本目录 PowerShell 中：

```powershell
.\setup.ps1 -WithTests
.\start-bridge.ps1
```

默认启动本机模拟服务，地址为 `http://127.0.0.1:8190`，数据在 `data-mock/`。窗口中按 Ctrl+C 停止服务。

连接已经启动的本机 ComfyUI，并允许局域网客户端连接的示例：

```powershell
.\start-bridge.ps1 -Backend comfyui -ComfyUrl http://127.0.0.1:8188 -ComfyModelsDirectory D:/ExampleModels -ComfyInstallDirectory D:/ExampleComfyUI -ListenAddress 0.0.0.0 -BaseUrl http://192.168.1.100:8190
```

地址和两个 `Example` 目录仅为示例，请换成本机实际值。ComfyUI 本身保持监听 `127.0.0.1`；iPad 只访问桥接端口 8190。若 Windows 防火墙提示，按用户当前网络情况允许专用网络访问；本项目没有自动新增防火墙规则。

真实预设需要以下模型和 ComfyUI 内置节点，启动后访问受保护的 `/v1/backend/status` 检查具体缺项：

| 模型文件 | 通常所在子目录 |
| --- | --- |
| `flux-2-klein-4b-fp8.safetensors` | `diffusion_models` |
| `qwen_3_4b.safetensors` | `text_encoders` |
| `flux2-vae.safetensors` | `vae` |

已有兼容的 ComfyUI 服务时直接复用它。`tools/start_local_comfy.py` 可另外启动隔离的本机实例，读取已有安装和模型，把数据库、输入、输出及缓存放在指定 runtime 目录；不下载模型、不启动第三方节点。该辅助脚本要求安装目录含 `main.py` 与 `.venv`，且 ComfyUI 支持脚本使用的命令行参数；其他安装布局请用其原有启动方式。

## 升级候选删除能力

停止当前桥接进程，更新到包含候选删除扩展的代码，保留原数据目录、配对信息与本机启动参数，再启动同一服务。不要同时运行两个桥接进程操作一套数据。iPad 重新“检查连接”后，服务能力中的 `jobDeletionSupported=true` 才表示可远端删除；旧版本仍可生成、下载和备份，iPad 只能先移除本机候选。

删除按整个生成任务执行，仅接受已经成功或失败的任务，不取消排队和运行中的生成。服务先写持久删除标记，再移除任务文件；文件被占用时明确返回 503，客户端保留重试，服务重启也会继续清理。工程备份和 ComfyUI 自有 input/output 副本不在清理范围内，详见 [API v1](docs/API_V1.md#删除不需要的候选)。

执行过删除后，原数据库包含 `deleted` 墓碑，旧桥接代码不能正确读取这些记录，可能使任务列表出错。不宜直接回退旧服务代码后继续读取这套数据；需要保留支持墓碑的读取逻辑。不要手动清空墓碑，否则同一个 `clientRequestId` 的重试可能重新触发生成。运行数据库与升级前的私人备份均留在本机，不提交 Git。

## Mac 上先联调模拟后端

克隆本仓库后，进入 `ipad_bridge/`，再在该目录终端执行：

```sh
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements-dev.txt
.venv/bin/python -m bridge pairing --backend mock --data-dir ./data-mock --base-url http://127.0.0.1:8190
.venv/bin/python -m bridge serve --backend mock --data-dir ./data-mock --host 127.0.0.1 --port 8190
```

真实 iPad 访问 Mac 模拟服务时，改用 Mac 的局域网地址并监听 `0.0.0.0`；模拟器和真机网络地址不能混用。随后将配对信息切换为 Windows 服务即可，无需在 Mac 重写 Windows 后端。

## 配对和网络

首次启动生成随机 token。`data-*/pairing.json` 含 `protocolVersion`、`baseUrl`、`accessToken` 和 `backend`，只应私下传给自己的设备。不要把它放进 Git、公开交接包或日志。iPad 应保存 token 到 Keychain，并为 API 请求加入 `Authorization: Bearer ...`。

这是单人本地开发版本，所有配对设备共享一个拥有者的任务和备份。默认 HTTP 仅供受信任的局域网调试，token 不会加密网络流量；不要暴露到公网或端口转发。需要 HTTPS 时可传入 `-Certificate` 与 `-PrivateKey`，客户端必须正常校验证书。iPad 的本地网络权限和开发期 ATS 配置见 API 文档，避免全局允许不安全连接。

地址变更可以重新执行 `bridge pairing` 更新 `baseUrl`，保留同一数据目录就保留同一 token 和任务。凭据需要轮换时，停止服务后由拥有者替换 token 文件，再生成配对文件并重新配对设备。

## 验证

运行测试：

```powershell
.\.venv\Scripts\python.exe -m pytest -q
```

另开终端，运行完整 HTTP 闭环；根据后端选择正确的配对文件：

```powershell
.\.venv\Scripts\python.exe examples\smoke_client.py --pairing data-comfyui\pairing.json --output test-output\real
```

验证客户端自动生成测试画面、提交和重试同一任务、轮询、下载结果，检查尺寸、文件摘要、蒙版保护与非零裁切位置，并保存报告和合成预览。重复使用相同输出目录会找回原请求；需要新生成时换输出目录。

服务提供 `/health` 存活检查；`/v1/backend/status` 才检查 ComfyUI 和模型。模拟测试通过不能替代真实显卡推理，也不能替代 iPad 真机和 Pencil 测试。

## 范围和运行约束

- 一套数据目录只运行一个服务进程；当前串行处理生成任务，不支持桥接任务取消。
- API v1 使用轮询；客户端将 jobId 和请求原始 PNG 持久化。iPad 后台、断网或锁屏后恢复查询，不能把断线当作失败重开任务。
- 输入每文件最多 20 MiB、4,194,304 像素，8-bit sRGB PNG；蒙版为无 alpha 的灰度 PNG，白色编辑，黑色保留。
- 结果已含蒙版 alpha，iPad 不得再次乘同一蒙版。原稿作为底图保留；画布版本变化后，结果进入候选区，由用户决定应用。
- 工程快照每个 ZIP 最多 64 MiB。服务不修改原 `.comp` 工程，不做双端同时编辑合并。
- 数据目录保存任务、输入图、结果与工程备份，不按时间自动清理；用户可明确删除已结束任务的桥接文件，工程备份保留。应放在有足够空间且仅自己可访问的位置。
- `requirements.txt` 固定直接依赖；`requirements-lock.txt` 记录这次 Windows 验证环境的完整版本，不保证所有操作系统都使用同一 wheel。

桥接服务按 ComfyUI HTTP API 独立编写，没有复制 Photoshop UXP 插件代码。真实预设参考官方工作流模板并适配为 API 图，来源与许可证见 [第三方声明](../THIRD_PARTY_NOTICES.md)。Compositor 移植另须保留上游 LICENSE 与 NOTICE；模型不随本仓库分发，使用时遵守各自许可证。
