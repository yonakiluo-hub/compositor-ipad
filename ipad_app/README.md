# 原生 iPad 应用

此目录预留给 Mac 端的 iOS/iPadOS Xcode 工程，当前还没有可运行的 iPad 应用。

先读 [产品需求](../docs/PRODUCT_REQUIREMENTS.md) 与 [Mac 开发交接](../docs/MAC_AGENT_HANDOFF.md)。最终目标是以 Compositor 为优先移植与复用基础、覆盖 Photoshop 大多数常用功能的原生 iPad 绘画和图像编辑软件。普通编辑、保存与导出需离线可用。

画布、蒙版、任务客户端、候选图层和撤销是第一阶段；随后继续完成常用笔刷、图层组与混合、选区、变换、调整、修图、滤镜、文字形状和文件交换。按产品需求建立上游功能移植清单，不能以简单 AI 画板作为最终交付。

网络协议见 [API v1](../ipad_bridge/docs/API_V1.md)。开发期间可直接在 Mac 运行 `ipad_bridge` 的 `mock` 后端，不需要另写一套服务。
