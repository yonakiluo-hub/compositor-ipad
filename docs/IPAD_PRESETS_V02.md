# iPad 多预设接入

接口复核：2026-10-21，固定 Windows [PR #9](https://github.com/yonakiluo-hub/compositor-ipad/pull/9) 提交 [`976e05f`](https://github.com/yonakiluo-hub/compositor-ipad/tree/976e05f1e94c084634282207e396fdd67260ba4f)。本轮 iPad 从 PR #7 的 `6c1c9ae` 继续，未合并或修改 Windows 部署；旧服务仍须可用。

## 客户端行为

- “检查连接”独立读取目录，再检查所选预设；目录默认采用 `defaultPreset`，旧版本缺字段时采用第一项。默认项失效不会静默改选实验模型。预设移除后保留提示，要求用户另选。
- 目录显示名称、默认/实验标记、输入限制、许可用途与当前选择的检查状态。关闭或配置损坏的项不可选；某实验项缺依赖不使其他项失效。固定采样参数不显示成可调整选项，也不增加请求字段。
- 选择后调用 `/v1/backend/status?presetId=…`；旧单预设服务沿用无查询参数的接口。检查 HTTP 与 `ok`，并匹配所选预设、后端和模拟标识。切换选择、重新连接或配对变化使旧检查失效，迟到响应不能启用错误模型。
- 模型安装、依赖结构、实际生成与绘画质量分别显示。目录 `not_checked`、状态 `unverified` 均不能解释为已验证。Qwen 默认不开启，许可用途来自服务描述；客户端不授予额外许可。
- 点击生成时固定文稿版本、提示词和预设 ID，再检查该预设。图像使用已提交图层合成（包括剪贴、图层蒙版、混合和组透明度），选区单独成为 L8 mask。裁切取全局和预设中的更严格限制，只增加上下文，不缩小或更换原像素。
- metadata、原 PNG、mask、请求 ID 和实际预设持久化；网络恢复仍找原任务。已持久化且尚未拿到回执的请求直接重放原字节，不先用今天的模型状态阻挡它，服务可先按幂等 ID 返回旧任务。429、超时、关闭预设或未知提交均不自动换模型或创建新 ID。
- 候选卡显示该任务实际使用的组合，切换当前选择不会改写旧候选。回填、旧版本确认、收据去重和撤销保持原流程。无多参考、多候选、原生 inpaint、取消或客户端强制释放 GPU 占用入口。

## 双端交接

本轮只增加客户端对既有可选扩展字段的读取，以及已支持的 `workflowPreset` 选择，不改变 multipart、坐标或 alpha 契约。旧版 Windows 只返回原默认预设时也可继续使用。新能力只有 Windows 实际部署对应服务后才出现，不能用 GitHub 有 PR 推断当前服务已经升级。

Windows 的部署、占用核对与回退步骤以该提交的 [Windows v0.2](https://github.com/yonakiluo-hub/compositor-ipad/blob/976e05f1e94c084634282207e396fdd67260ba4f/docs/WINDOWS_PRESETS_V02.md) 和 [API v1](https://github.com/yonakiluo-hub/compositor-ipad/blob/976e05f1e94c084634282207e396fdd67260ba4f/ipad_bridge/docs/API_V1.md) 为准。客户端没有替 Windows 开启 Qwen 实验或更换日常 ComfyUI。

验证分为三层：协议响应与竞争使用合成 fixture；实际 HTTP 使用独立本机 mock；真实 iPad → Windows 模型效果仍需更新部署后用用户画稿验收。mock 只提供 `mock-paint-v1`，不能把它当成 Qwen GPU 测试。当前运行结果记录在 [iPad 状态](IPAD_STATUS.md)。

真机建议：检查连接 → 查看默认及实验项状态 → 选择已启用且就绪的组合 → 套索衣服并羽化 → 提交后继续在剪贴层上色 → 取回旧版本候选并确认加入 → 撤销/重做 → 保存重开。切换模型后检查旧候选仍标识原组合；将未启用或缺依赖模型显示为不可生成，不静默回退。
