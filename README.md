# Compositor iPad

以 Compositor-ZH 为优先移植与复用基础，开发覆盖 Photoshop 大多数常用绘画、修图、合成和图层编辑功能的原生 iPad 软件，适配 Apple Pencil 与触控。ComfyUI 是其中的 AI 辅助模块，由 Windows 本地显卡生成候选并返回 iPad。

**最终目标是可日常使用的完整绘图与图像编辑软件。** 当前的“画布 → 蒙版 → AI → 新图层”闭环只是第一阶段；长期功能范围与验收见 [产品需求](docs/PRODUCT_REQUIREMENTS.md)。普通绘画、编辑、保存和导出应能在不连接 Windows 时独立使用。

**当前已实现 Windows 桥接 v0.1 和首版原生 iPad 编辑器，完整产品范围仍在推进。** 这是用于 Mac 与 Windows 协作开发的主仓库。Git 同步源码、文档和测试，画稿、模型、运行数据库与配对凭据留在各自设备上。

```text
iPad 本机绘画与图层
       │  局域网：画面、蒙版、任务状态
       ▼
Windows Local Bridge → 本机 ComfyUI / NVIDIA GPU
       │  返回带透明度的 PNG 候选
       └──────────────────────→ iPad 新图层
```

## 从这里开始

| 工作 | 入口 |
| --- | --- |
| 最终产品目标、功能范围和阶段路线 | [产品需求](docs/PRODUCT_REQUIREMENTS.md) |
| 构建与使用原生 iPad 端 | [iPad 客户端](ipad_app/README.md)、[实现与验证状态](docs/IPAD_STATUS.md) |
| Mac agent 后续开发 | [Mac 开发交接](docs/MAC_AGENT_HANDOFF.md)、[上游移植清单](docs/COMPOSITOR_PORT_MATRIX.md) |
| Windows 启动服务，或 Mac 启动模拟后端 | [桥接安装与运行](ipad_bridge/README.md) |
| 两端网络接口、坐标、蒙版、重试 | [API v1](ipad_bridge/docs/API_V1.md) |
| 两台电脑同步代码 | [Git 协作流程](docs/GIT_WORKFLOW.md) |
| 已验证内容与限制 | [Windows v0.1 状态](docs/WINDOWS_BRIDGE_STATUS.md) |

克隆本仓库：

```sh
git clone https://github.com/yonakiluo-hub/compositor-ipad.git
cd compositor-ipad
```

Windows 安装并启动模拟后端：

```powershell
cd ipad_bridge
.\setup.ps1 -WithTests
.\start-bridge.ps1
```

Mac 上先运行同一个模拟后端，不需要显卡：

```sh
cd ipad_bridge
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements-dev.txt
.venv/bin/python -m bridge pairing --backend mock --data-dir data-mock --base-url http://127.0.0.1:8190
.venv/bin/python -m bridge serve --backend mock --data-dir data-mock
```

桥接需要 Python 3.12 或以上。真实生成另需本机 ComfyUI 和指定模型，详见桥接 README。iPad 真机连接时使用服务所在电脑的局域网地址；不要把客户端的 `127.0.0.1` 当作 Windows 地址。

## 当前范围

- iPad 已实现：离线分层绘画、Pencil 输入、选区与链接蒙版、图层组与混合、基础变换和调整、撤销重做、分层自动保存及图片导出；已接入 AI 候选与工程备份。范围及真机验收状态见 [iPad 状态](docs/IPAD_STATUS.md)。
- 桥接已实现：认证、任务持久化、重试与恢复、结果下载、蒙版透明度处理、`.comp` ZIP 版本备份，以及模拟后端和固定真实生成预设。
- 验证：Windows 桥接的 62 项测试、81 个子测试在 Mac 通过；Mac 原生 Swift 客户端通过模拟后端和真实 Windows 合成输入闭环。iPad 真机验收单独记录。
- 当前预设使用 FLUX.2 Klein 4B 参考图编辑，再将蒙版应用到输出 alpha；蒙版尚不参与模型去噪，边缘融合与实际绘画质量需评估。
- 暂不包含完整 Windows 画图软件、Procreate 实时插件、逐笔同步或云端账户服务。

## 目录

```text
ipad_bridge/       Windows 服务、Mac 模拟后端与测试
ipad_app/          原生 iPad 工程、文档核心、渲染、网络客户端与测试
docs/              交接、协作和状态文档
licenses/          纳入的第三方许可证
```

参考项目：[Compositor-ZH](https://github.com/qidian2022/Compositor-ZH)、[ComfyUI Photoshop](https://github.com/NimaNzrii/comfyui-photoshop)。当前仓库已适配部分 Compositor 坐标与图层几何代码，并保留上游许可；未引入 Photoshop 插件代码。固定预设参考 Comfy Org 官方模板，声明见 [THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES.md)。本项目原创代码的整体许可证尚未指定，第三方材料按各自许可证提供。
