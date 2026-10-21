# Qwen-Image-2.1 绘画实验

本页记录 2026-10-21 的接入方案与复验方法。两个预设均为实验项，默认关闭；拥有权重、结构预检通过、真实 GPU 跑通和绘画质量准入是四个独立结论。未完成的项目不能标为通过。

## 两个固定组合

| 预设 | 固定生成设置 | 权重组合 |
| --- | --- | --- |
| `qwen21-edit-v1` | 25 steps、Euler、simple、CFG 1 | Qwen-Image-2.1 INT8 ConvRot + Qwen3-VL 8B INT8 ConvRot + 2.1 BF16 VAE |
| `qwen21-turbo-edit-v1` | 8 steps、Euler、CFG 1、官方非均匀 sigma 序列 | 上述基础组合 + 官方 Turbo BF16 LoRA，强度 1 |

基础版的 25 steps 来自 Comfy 官方编辑模板；Turbo 使用官方模型卡明确支持的基础模型加 Turbo LoRA 路径，不等同于把基础采样器的步数改为 8。其 sigma 序列为 `1, .978453, .95418, .926626, .89508, .845148, .704534, .414568, 0`。来源：[Comfy 官方模型卡](https://huggingface.co/Comfy-Org/Qwen-Image-2.1)、[固定版本基础编辑模板](https://github.com/Comfy-Org/workflow_templates/blob/d0e41fe5423f93db5b5872cf273d7b1af8aa68bc/templates/image_qwen_image_2_1_image_edit.json)、[固定版本 Turbo 编辑模板](https://github.com/Comfy-Org/workflow_templates/blob/d0e41fe5423f93db5b5872cf273d7b1af8aa68bc/templates/image_qwen_image_2_1_turbo_image_edit.json)。

图中只使用 ComfyUI 核心节点：不需要全局启用第三方节点，不引入可选提示词改写器。输入 RGBA 通过 `LoadImage` 与 `JoinImageWithAlpha` 保留源透明度；它与 iPad 选区是不同的数据。选区 mask 不进入模型，在桥接输出处乘一次。工作流属于参考图编辑加输出遮罩，不能称为原生蒙版重绘。VAE 输出 alpha 与选区覆盖相乘，例如两者各为 0.5 时输出约 0.25。

实验输入上限 1,048,576 像素、最短边 32、最大宽高比 4；先验证 768 和 1024。参考编码 `resolution=0`，仅按模型要求对齐到 32 的倍数；结果缩回提交 crop 的原尺寸。不增加输入图片、候选数量或返回画布范围，不支持真正扩图和超分辨率。基础 Klein 对照仍使用原有约 1MP 设置。

## 当前依赖边界

首次检查时，本机原 ComfyUI 为 `12d5279438bfefc058a269eae805ceab6047777f`（v0.34.0），源码缺少 `TextEncodeQwenImage21` 和 `QwenImage21Cache`，因此该安装不能直接运行本实验。不能把文件存在当作兼容。检查时官方候选源码固定为 `37ff76b4d3d47405ba46ac1e14698e280b70b33f`；与原环境比较，其 requirements 中 `comfy-kitchen` 从 0.2.31 到 0.2.39、`comfy-aimdo` 从 0.4.15 到 0.5.6，还有前端、模板及内置文档版本更新。新环境应独立准备，原服务和原环境留作回退。

随后已在独立环境启动上述固定版本，并完成两个 Qwen 预设各 48 项真实 GPU 测试，以及最终代码各一次复测；原 ComfyUI 安装与日常服务保留。桥接记录实际运行依赖、权重 SHA-256、图和源码摘要，详细结果与限制见 [Windows 验证记录](WINDOWS_PRESETS_V02.md#本次验证记录)及[脱敏证据](validation/windows-presets-v02-20261021.json)。这仅证明本次固定组合在本机能运行，不能推断其它精度、分辨率、节点或显卡也可用；绘画质量仍待人工审阅。[官方节点源码](https://github.com/Comfy-Org/ComfyUI/blob/37ff76b4d3d47405ba46ac1e14698e280b70b33f/comfy_extras/nodes_qwen.py)

## 许可

Qwen-Image-2.1 与 Turbo 的当前 Qwen Research License 将非商业使用限定为研究或评估；商业使用需另获许可。实验开关只代表允许本地评估，不授予商业使用权。仓库不分发模型权重，代码或工作流的许可不能覆盖模型许可。[基础模型 LICENSE](https://huggingface.co/Qwen/Qwen-Image-2.1/blob/main/LICENSE)、[Turbo LICENSE](https://huggingface.co/Qwen/Qwen-Image-2.1-Turbo/blob/main/LICENSE)

## 可复现的小样工具

在 `ipad_bridge` 内执行，输出目录应位于 Git 忽略的私人 `test-output` 下：

```powershell
python tools/evaluate_painting.py --preset paint-edit-v1 --output test-output/klein-eval
python tools/evaluate_painting.py --preset qwen21-edit-v1 --output test-output/qwen-eval
python tools/evaluate_painting.py --preset qwen21-turbo-edit-v1 --output test-output/qwen-turbo-eval
```

默认只生成原创合成样本，不调用 GPU。每种预设产生 4 类任务 × 3 个主题 × 2 个种子 × 2 种尺寸，共 48 项：线稿上色、草图细化、局部修补、明度与光影。明度样本分别包含两大调子与四大调子的指令，不承诺严格二/四阶像素量化。基础离线量化仍应由 iPad 独立实现。

```powershell
python tools/evaluate_painting.py --preset qwen21-turbo-edit-v1 --output test-output/qwen-turbo-eval --run --pairing data-experiment/pairing.json --limit 1
```

确认依赖、显存及单例完成后再扩大 `--limit`。工具串行提交；失败或轮询超时立即停止本批次。重跑同一目录使用原请求 ID 和原始字节以恢复已有任务，绝不把超时改成一个新请求。选择不同预设、尺寸或种子必须使用新目录；任何已保存输入被修改都会拒绝恢复。

每项保存原输入、选区、metadata、结果、合成预览及 report；不保存配对 token。自动检查仅覆盖接口、尺寸、crop、摘要、透明度范围和选区外合成保护。工具明确标记 `qualityAdmission=pending_human_review`；耗时为客户端端到端等待，恢复已有任务的耗时不算新推理速度。已完成且结果摘要正确的项目直接跳过，保留原有耗时与资源记录。

运行时每 0.5 秒采样显存与系统内存；提供经核验的 `--comfy-pid` 时同时记录该进程 RSS。没有 NVIDIA 工具时显存标为不可用，不记为零。采样可能遗漏短暂峰值，显存包含其它程序，RSS 不包含子进程；这些数值不是精确的单任务 CUDA 分配峰值。首次加载、已缓存和切换模型应在独立运行记录中区分，不能从文件大小推断可用性。

生成本机对比页：

```powershell
python tools/render_evaluation.py --suite test-output/klein-eval --suite test-output/qwen-eval --suite test-output/qwen-turbo-eval --output test-output/comparison.html
```

页面并排显示原图及各模型合成结果，可按场景、尺寸和种子筛选；未完成与文件不完整的项目明确标记。页面引用私人本机图片，不上传公开仓库。旁边的 `.summary.json` 排除任务 ID、路径与提示词，分尺寸汇总新提交的耗时及采样资源；公开前仍需核对对应执行快照和权重摘要。

人工审查每个种子的结果：线条与轮廓漂移、色块越界、明暗分组、修补接缝、材质和人像特征变化；保留原线稿独立图层。合成样本用于发现工程与基础指令问题，正式绘画准入仍需用户授权的代表画稿与视觉确认。全量通过之前不替换默认 Klein 预设。

## 第三方工作流声明

两个图由 Comfy Org 官方 MIT 工作流改编为单输入 API 图；增加源 alpha 保留与回到原 crop 尺寸，删除多参考和可选提示词改写模块，Turbo 使用官方模型卡的 LoRA 组合。上游模板版本为 `d0e41fe5423f93db5b5872cf273d7b1af8aa68bc`。Copyright (c) 2023-present Comfy Org；许可全文见 [已保留的 MIT 许可](../licenses/ComfyUI-Workflow-Templates-MIT.txt)。这份工作流许可不改变 Qwen 模型使用限制。
