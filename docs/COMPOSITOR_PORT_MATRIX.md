# Compositor → iPad 功能与移植清单

盘点更新：2026-10-29。产品范围仍以 [PRODUCT_REQUIREMENTS.md](PRODUCT_REQUIREMENTS.md) 为准；本文区分上游源码存在、iPad 已实现和实际运行验证，不能将其中任意一种当作另外两种。

## 官方主线复核与开发顺序

2026-10-20 按用户指定重新核对官方仓库 [robbietilton/Compositor](https://github.com/robbietilton/Compositor)，固定为 [`365b5745eda537f984f3d5bed1e53c361dbc9c91`](https://github.com/robbietilton/Compositor/tree/365b5745eda537f984f3d5bed1e53c361dbc9c91)。本节依据该提交的 [README](https://github.com/robbietilton/Compositor/blob/365b5745eda537f984f3d5bed1e53c361dbc9c91/README.md) 和下列相关源码；它与后文曾构建、测试的中文分支基线是两个不同的检查对象。本次未运行官方主线 Mac target，不能沿用中文分支的构建结果证明它可运行。

**继续参考并移植 Compositor 是合理的。** 当前 iPad 已有独立文档、事务、渲染和网络边界，应优先抽取上游参数、像素算法、图层关系规则及测试样例，接入这些边界。上游的 `EditorSession`、AppKit 面板、鼠标事件、桌面窗口和 GPU 视图不能整体搬进 UIKit；Pencil、触控手柄、后台保存及设备内存预算必须继续单独适配。无需推倒已经验收的 iPad 文稿、选区和 AI 链路，也不能只依照 README 重做一套简化算法。

本表包含自由变换、蒙版/合并、剪贴、组内整理、组蒙版、整层/整组共同变换、曲线/色阶调整层及本轮第 4、5、6 部分；自动化与真机验证分别见 [IPAD_STATUS.md](IPAD_STATUS.md)，最新顺序见 [接手入口](IPAD_NEXT_AGENT_HANDOFF.md)。**实现、测试通过和真机验收仍分别记录，合并后的跨端验收及后续计划不属于已完成能力**：

| 工作 | 官方主线依据 | iPad 当前缺口与移植重点 |
| --- | --- | --- |
| 图层蒙版 | [`LayerMask.swift`](https://github.com/robbietilton/Compositor/blob/365b5745eda537f984f3d5bed1e53c361dbc9c91/Compositor/Document/LayerMask.swift) 有灰度覆盖、独立 `placement`、链接状态和蒙版画笔入口；README 列出绘制、填充、反相、模糊及羽化。 | 已接入图像/蒙版编辑目标、全白新建、直接绘制、填充、反相、载入选区、启停及删除；黑色隐藏、白色恢复，原像素保持不变，软选区限制覆盖。本轮新增可绘制组蒙版，对整组结果应用一次覆盖，嵌套、剪贴、导出和合并共用合成路径，详见[组蒙版规则](IPAD_GROUP_MASKS.md)。尚缺蒙版专用模糊/羽化、独立位置/未链接蒙版，不能将可绘制的链接蒙版称为完整蒙版工具集。 |
| 多层选择、合并与整理 | [`LayerGroups.swift`](https://github.com/robbietilton/Compositor/blob/365b5745eda537f984f3d5bed1e53c361dbc9c91/Compositor/Document/LayerGroups.swift) 管理选择集合、后代、分组及移出；[`LayerMerge.swift`](https://github.com/robbietilton/Compositor/blob/365b5745eda537f984f3d5bed1e53c361dbc9c91/Compositor/Document/LayerMerge.swift) 区分向下合并、多选合并和组合并。 | 已接入多选导航、向下/多选/组合并、默认隐藏的画布盖印，以及已有层/子树整批移入移出组、同组连续项目成组和明确同级插入位置。整理保留原 PNG、UUID、蒙版、变换及完整剪贴关系，隐藏项可移动，锁定子树或祖先拒绝；一次事务预检并提交，拆散依赖整次拒绝。跨父组继承新祖先外观，不承诺画面恒定，详见[组整理范围](IPAD_GROUP_ORGANIZATION.md)。合并仍限连续、可见未锁定、正常混合及全不透明外部父组；跨组/不连续/混合依赖不合并。整层/整组共同变换已接入，见共同变换行；跨组/不连续成组和解散组仍待开发。 |
| 剪贴与组表现 | [`LiveLayerMask.swift`](https://github.com/robbietilton/Compositor/blob/365b5745eda537f984f3d5bed1e53c361dbc9c91/Compositor/Document/LiveLayerMask.swift) 有剪贴关系、循环校验、删除/合并后的处理；`LayerGroups.swift` 和 `LayerAppearance.swift` 定义层级与透明度规则。 | 同组连续普通栅格层的剪贴关系已接入：原像素保留、基底 alpha 仅合成一次，复制组重映射关系，拆散依赖的删除/重排/移动原子拒绝；完整堆栈可合并、移动和成组，标准 maskSourceID 保存。隐藏基底隐藏整个堆栈，与上游任意实时蒙版隐藏源语义不同；跨组/链式/分离关系仍拒绝。组蒙版已接入 iPad 整组结果覆盖规则，区别于上游逐子层覆盖；组仍只接受正常/穿透混合，更多组混合模式待开发。 |
| 曲线、色阶与可编辑调整层 | [`Curves.swift`](https://github.com/robbietilton/Compositor/blob/365b5745eda537f984f3d5bed1e53c361dbc9c91/Compositor/Document/Curves.swift) 有 RGB/单通道控制点、保形 Hermite 插值与查找表；[`LayerAdjustment.swift`](https://github.com/robbietilton/Compositor/blob/365b5745eda537f984f3d5bed1e53c361dbc9c91/Compositor/Document/LayerAdjustment.swift) 保存曲线、色阶等参数。 | 已适配四通道曲线控制点、保形 Hermite、色阶参数及 Float LUT/alpha 处理，接入实时预览和保存重开可再次编辑的调整层。普通层调整下方穿透合成，剪贴调整限制于基底覆盖，选区创建时捕获为独立数值蒙版。正常混合、严格参数/状态标记；其他调整类型及含调整层的直接合并拒绝，见[调整层范围](IPAD_COLOR_ADJUSTMENTS.md)。 |
| 绘画与修图 | README 列出平滑笔刷、渐变、仿制、修复和局部模糊；相关入口为 `BrushStroke.swift`、`Gradient.swift`、`CloneStamp.swift`、`ContentFill.swift`、`BlurTool.swift`。 | 基础 Pencil、橡皮、填充和吸色已具备；尚缺完整笔刷预设/预测输入、渐变、仿制、修复及局部模糊。应按笔迹事务、采样范围和软选区一致性逐项接入，性能与手感持续测量。 |
| 多层与组共同变换 | [`LayerTransform.swift`](https://github.com/robbietilton/Compositor/blob/365b5745eda537f984f3d5bed1e53c361dbc9c91/Compositor/Document/LayerTransform.swift) 的 `TransformGroup` 保存共同框与原几何，`following` 随框映射；`placing` 会丢弃斜切。 | 已接入多选整层及整组子树的移动、缩放、旋转和翻转；后代去重，PNG/蒙版/UUID/剪贴引用保留，预览不进历史，完成一次事务。包含隐藏层，锁定子树或祖先拒绝；有选区须先取消，旋转层强制比例锁，核心拒绝斜切。范围与上游差异见[共同变换说明](IPAD_MULTI_LAYER_TRANSFORM.md)。 |
| 后续几何与选区 | README 列出多层/组变换、扭曲、吸附、魔棒/对象/主体选择、扩选/缩选和移动选区轮廓。 | 已接入魔棒、Vision 前景对象/全部主体、数值 L8 扩缩与单层透视/四角扭曲；优先适配 `MagicWand.swift`、`WandPixels.c`、`ObjectSelection.swift`、`Selection.swift` 和 `Distort.swift`。冻结正式源稿、串行预览、一次事务；拒绝多层/组扭曲、折叠、凹形和奇点，文字/形状须先显式栅格化。已有形状选区与自由变换保留。角点与数字滑杆的新增 2 项 UI 修复后通过；多层选中像素、吸附和独立移动选区轮廓仍待后续。见[范围与采样](IPAD_ADVANCED_SELECTION.md)。 |
| 文字、形状及图层效果 | README 列出可编辑文字、基本形状；[`LayerEffects.swift`](https://github.com/robbietilton/Compositor/blob/365b5745eda537f984f3d5bed1e53c361dbc9c91/Compositor/Document/LayerEffects.swift) 保存描边、阴影、颜色叠加和内外发光等效果。 | 已适配 `TypeTool.swift`、`ShapeTool.swift`、`LayerEffects.swift` 与 `LiveMaskRenderer.swift`，使用 PNG 缓存加独立元数据，CoreText/UIKit 替代 AppKit。中文、多行、字体与局部参数、圆角/平滑角、直线及六种效果可保存重编；缺字体保留原缓存，编辑时提示。效果扩边、数值蒙版一次覆盖、剪贴成品 alpha 和原子预览已接入；像素编辑前显式栅格化，完整贝塞尔路径/富文本交互及真机字体/触控验收仍待后续。见[范围](IPAD_EDITABLE_CONTENT.md)。 |
| 调色滤镜、工作区与文件交换 | README 列出 Camera Raw、更多滤镜、多标签、导航器、裁切、辅助线/网格及 PSD/PSB；[`CameraRaw.swift`](https://github.com/robbietilton/Compositor/blob/365b5745eda537f984f3d5bed1e53c361dbc9c91/Compositor/Document/CameraRaw.swift) 有参数、像素处理及桌面会话交互。 | 已适配官方 `IO/PSD/PSDReader.swift`、`PSDTypes.swift`、`PSDChannelCoder.swift` 的记录/通道结构并新增受限 writer；接入真实 RGB8 分层 PSD、有限穿透组、蒙版与连续剪贴，独立工具核对真实结构和强制重合成。文字/形状/效果/调整、组蒙版/透明度、非正常混合剪贴配软基底、PSB/CMYK/高位深等明确拒绝。`Crop.swift`、`Guides.swift`、`ImageImporter.swift`、`ImageExporter.swift` 适配为无损坐标裁切、数值辅助线、更多系统图片导入和 TIFF/图像 PDF 导出，见[支持矩阵](IPAD_FILES_CROP_GUIDES.md)。Camera Raw、多标签、导航器、网格与完整格式兼容仍待后续。 |
| 性能、保存和移动端运行 | 官方 README 有大文档、后台保存和缩略渲染；上游提供 `TiledLayerRenderer.swift`、`GPUCanvas.swift`、`DownsampleCache.swift`。 | 当前 CG/CI 全图层栈合成、4096 单边/1600 万像素面上限、会话内历史仍有规模限制。分块/GPU 合成、低内存恢复、长笔迹与后台行为应贯穿各阶段，预算必须来自目标 iPad 测量，不能复制 Mac 物理内存公式。 |

README 用于发现功能，具体支持范围仍以源码和运行结果为准。例如官方 README 写 PSD/PSB “8-bit RGB; not CMYK”，但该提交 [`PSDReader.swift`](https://github.com/robbietilton/Compositor/blob/365b5745eda537f984f3d5bed1e53c361dbc9c91/Compositor/IO/PSD/PSDReader.swift) 实际允许 8 位 RGB 或 CMYK，并将 CMYK 转为 RGB；这既不代表 iPad 已支持，也不代表保留 CMYK 文稿。类似地，部分上游内部路径支持 16 位/HDR，不能据此推出 PSD 支持 16 位导入或导出。

### 接下来按完整操作流程交付

下列编号沿用 2026-10-21 的六部分范围。**2026-10-29 最新执行顺序为原第 4 → 第 5 → 第 6 部分，笔刷最后与用户细化；原第 3 部分其余扩展仍留待后续。** 不因调整顺序而把未实现项标为完成：

1. **图层合成与共同编辑**：剪贴已真机验收，组内整理、组蒙版和整层共同变换已实现、真机体验待确认；曲线/色阶与可编辑调整层也已在下一阶段接入。验收包括原像素与剪贴关系保留、隐藏/锁定项、半透明软边、同级次序、一步撤销/重做、保存重开与离线操作。
2. **常用调色**：曲线、色阶及可再次编辑的调整层已实现，真机体验待确认。验收包括 RGB/单通道、透明像素、选区与蒙版约束、图层顺序影响、预览/提交一致、取消不改文稿和重开后参数仍可编辑。
3. **绘画和修图工具**：笔刷预设与手感、渐变、仿制、修复；围绕真实作品验证采样范围、软选区、事务与持续输入性能。
4. **更多选区与几何工具**：魔棒和自动选取、选区扩缩、透视与扭曲；明确覆盖与插值规则，保留完整边界并可撤销。
5. **文字、形状及效果**：可编辑文字和形状、描边、阴影等；保存重开保留参数，缺字体和未知效果明确处理。
6. **文件交换与文稿辅助**：PSD 支持、更多格式、裁切与辅助线；建立可编辑/仅外观/拒绝的支持矩阵，不承诺未经验证的无损往返。

性能、备份恢复、低内存和后台保存贯穿各阶段。AI 继续使用现有 Windows 桥接，普通编辑保持离线可用；用途快捷入口和新工作流与 Windows 按独立计划协作。

每项提交都应同时交付可用入口、统一事务、工程往返和有代表性的回归测试；核心像素测试可复用上游样例，Pencil/触控/内存仍以 iPad 实测为准。以上为优先级和验收门槛，不是本次一次性完成所有项目的承诺。

## 早期中文分支基线与验证记录

- 早期上游基线：[qidian2022/Compositor-ZH，zh-Hans](https://github.com/qidian2022/Compositor-ZH/tree/zh-Hans)。当时获取并审查的 HEAD 为 [`7c2a5a4a3e7f685a8a0ec282ef0b4284f20b5477`](https://github.com/qidian2022/Compositor-ZH/tree/7c2a5a4a3e7f685a8a0ec282ef0b4284f20b5477)，与 Mac 交接记录完全相同。本条仅描述该次检查，不表示它是官方主线最新版本。
- 上游 `AGENTS.md`、`README.md`、指定的画布、画笔、会话、工程存储入口和格式说明已阅读；上游应用源码和原 Mac target 保持原样；兼容性验证临时添加的测试已移除。
- 基线平台：Apple Silicon、macOS 26.4、Xcode 26.6（17F113）。原 `Compositor` scheme 在 macOS 目标上 **构建成功**，关闭签名。首次受限构建无法启动 Swift Observation 宏插件，允许 Xcode 正常运行后成功，不属于源代码编译缺陷。
- 原 Mac 构建仍产生已有的 Swift actor 隔离、Metal 弃用等警告。构建成功不代表所有上游功能经过人工操作验证，也不代表 iPad 兼容。
- 许可证：MIT，Copyright (c) 2026 Wonder Assembly LLC；中文分支同为 MIT。复制或改写上游代码时须同时保留原 `LICENSE`、`NOTICE.md` 以及文件级来源记录。

复现原 Mac 构建：

```sh
git clone --branch zh-Hans https://github.com/qidian2022/Compositor-ZH.git
cd Compositor-ZH
git checkout 7c2a5a4a3e7f685a8a0ec282ef0b4284f20b5477
xcodebuild -project Compositor.xcodeproj -scheme Compositor \
  -destination 'platform=macOS' -derivedDataPath build/baseline \
  CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Compositor.xcodeproj -scheme Compositor \
  -destination 'platform=macOS' -derivedDataPath build/baseline \
  CODE_SIGNING_ALLOWED=NO test \
  -only-testing:CompositorTests/HistoryTests \
  -only-testing:CompositorTests/ProjectTests \
  -only-testing:CompositorTests/NavigatorTests \
  -only-testing:CompositorTests/BrushTests
```

下表“上游实际源码”列的路径相对于上述固定提交；“移植状态”列的 `Core/`、`Rendering/`、`App/` 路径相对于本仓库 `ipad_app/Sources/`。上游文件可在[固定源码树](https://github.com/qidian2022/Compositor-ZH/tree/7c2a5a4a3e7f685a8a0ec282ef0b4284f20b5477/Compositor)和[固定测试树](https://github.com/qidian2022/Compositor-ZH/tree/7c2a5a4a3e7f685a8a0ec282ef0b4284f20b5477/CompositorTests)核查。按功能列出的上游测试文件表示可用回归样本，不自动表示本次已执行；本地 iPad 测试和本次执行结果另列于本文末尾。

分类含义：**可复用**表示算法或数据规则可抽取；**需平台改造**表示含 AppKit、桌面交互或关联类型耦合；**缺失需开发**表示本次在相关入口未找到对应实现；**待验证**表示实现存在但还需平台、像素或设备验证。iPad 开发与验收记录见 [ipad_app/README.md](../ipad_app/README.md)。

## 中文分支源码明细与既有移植记录

| 功能类别 | 上游实际源码与支持情况 | 复用分类与 iPad 改造方式 | 回归样本与 iPad 验收 | 移植状态 |
| --- | --- | --- | --- | --- |
| 文档与画布 | `Document/EditorSession.swift` 的 `CanvasDocument`、`ImageLayer` 保留 UUID、层序、资产与独立变换；`IO/ProjectStore.swift` 保存分层目录包。`Rendering/CanvasViewport.swift` 有拟合、锚点缩放、平移及双向坐标转换。`Document/ProjectWorkspace.swift` 有多标签；`CanvasSize.swift`、`Crop.swift`、`CanvasRotation.swift` 有画布尺寸、裁切及文档 90° 旋转。 | 文档/坐标**可复用**；工作区和文件面板**需平台改造**，含 `NSWindow`/`NSOpenPanel`。`CanvasViewport` 无视图旋转参数，文档 90° 旋转不等于自由旋转视图。自动保存/进程异常恢复在相关存储入口未找到，属**缺失需开发**。 | `ProjectTests.swift`、`CanvasSizeTests.swift`、`CropTests.swift`、`CanvasRotationTests.swift`、`NavigatorTests.swift`；iPad 应验证非方形画布四角、缩放锚点、保存重开、原子替换失败及恢复。 | **基础能力及保留框外像素裁切已接入**：`CanvasDocument`、`EditorModel`、`DocumentStore` 与视口保留稳定 ID、资源和坐标；新增 `Core/CanvasCropPlan.swift`、`App/EditorCanvasCrop.swift` 冻结源稿，将所有普通层/组蒙版/调整蒙版的原点一次平移，保持 PNG/蒙版字节，选区裁切补黑。`CanvasGuide` 保存独立 UUID 与文稿像素位置。图像大小缩放几何和对应辅助线；文字/形状须先显式栅格化，单纯裁切/画布改大小保留结构。多标签、标尺拖线、吸附与网格仍未接入。 |
| 绘画与 Pencil | `Document/BrushStroke.swift` 有 256px 按需分块、硬度衰减、笔迹不透明度上限、平滑、选区裁切和笔迹提交；`EditorSession+Brush.swift` 管理工具事务；`Rendering/BrushPixels.c`、`MetalBrushCoverage.swift` 有 CPU/GPU 覆盖算法。`Gradient.swift` 支持线性/径向渐变；`SelectionEdits.swift` 支持填充。 | 软笔刷曲线、分块与覆盖算法**可复用**；整笔迹模块关联层、选区、深色彩和 Metal 类型，不能直接拷贝一文件。`EditorCanvas.swift` 的 `NSView`/`NSEvent` **需平台改造**。本次未找到 Pencil 的压力、倾斜、方位、合并/预测触点输入，属**缺失需开发**；`GPUCanvas` 的 pressure 是内存压力，不能视作笔压。 | `BrushTests.swift`、`LargeCanvasBrushTests.swift`、`NativeResolutionPaintTests.swift`、`BrushIntersectionTests.swift`、`GradientTests.swift`。真机需验证 Pencil 与手指区分、断续笔迹、压力、倾斜、防误触、橡皮和撤销。 | **已实现自有基础笔刷**：`App/BrushInput.swift`、`App/CanvasView.swift` 接入 Pencil 压力、倾斜/方位及合并触点，支持硬度/大小/浓度、橡皮、选区约束、吸色和填充；区分手指导航与绘画，每笔提交单次事务。完整上游分块笔刷、预测触点、笔刷预设与渐变未移植；真实 Pencil 手感、防误触和延迟待验收。 |
| 图层体系 | `EditorSession.swift`、`LayerGroups.swift`、`LayerMerge.swift`、`LayerAppearance.swift`、`LiveLayerMask.swift` 支持新建/复制/排序/合并、组、透明度、混合、剪贴来源。`LayerMask.swift` 有启用、链接、独立位置与灰度规则。`ImageLayer` 和 `ProjectLayerRecord` 未见图层锁定字段。 | 模型、组合法性、合成次序和蒙版**可复用**；需剥离 `EditorSession` 的桌面 UI 状态。`LayerAppearance` 枚举含 24 种模式；部分必须走 Core Image，不能统一映射为普通 Core Graphics 混合。图层锁定**缺失需开发**。 | `LayerTests.swift`、`GroupTests.swift`、`LayerAppearanceTests.swift`、`LayerMaskTests.swift`、`LiveMaskTests.swift`。透明底 + 半透明红蓝层、组中组、剪贴环、蒙版独立移动和保存重开是必要样本。 | **已实现基础图层体系**：`Core/DocumentEditor.swift`、`Core/LayerGeometry.swift` 与 `Rendering/DocumentRenderer.swift` 支持新建/复制/删除/同级排序、可见性、不透明度、锁定、穿透组层级、12 种直接实现的混合模式和链接式灰度图层蒙版。界面可新建组、在组内建层及批量移组/成组；本轮已接入可绘制组蒙版。本轮 `App/EditorLayers.swift` 和 `Rendering/LayerMerge.swift` 接入多选、受限合并与隐藏盖印，限制和验证见本文开头及 IPAD_STATUS。同组连续栅格剪贴关系已接入；独立蒙版位置及其余混合模式未接入。 |
| 选区与蒙版 | `Document/Selection.swift` 有矩形、椭圆、自由/多边形套索、羽化、扩展/收缩；`MagicWand.swift`、`ColorRangeSelection.swift`、`ObjectSelection.swift` 有颜色与对象选区；`SelectionEdits.swift` 将作用域用于像素编辑。`SelectionMode` 只有 replace/add/subtract；路径与画布求交不等于用户可用的选区交集模式。 | 路径/灰度覆盖和几何**可复用**，AppKit 工具与 Vision 对象选择**需平台改造及验证**；交集模式需补齐。灰度蒙版须无 alpha、无颜色转换；UI 显示用的红色遮罩不可直接拿来上传。 | `SelectionTests.swift`、`SelectionFeatherTests.swift`、`SelectionEditTests.swift`、`MagicWandTests.swift`、`MaskTransformTests.swift`；全黑、全白、128 灰度、羽化边缘和非零裁切原点。 | **形状与图像选区均已接入**：`SelectionMask`、`SelectionGesture` 与 `EditorSelection` 保留矩形/椭圆/自由/多边形、组合和羽化；新增 `Rendering/ImageSelection.swift` 与 `App/EditorImageSelection.swift`，按预乘 RGBA 容差生成 L8，连续扫描线/全图取样、真实 Vision 对象实例与全部主体、单调队列 max/min 灰度扩缩。正式源稿与参数冻结，取消/错误/旧结果保留原选区，完成一次事务；显式全黑仍不等于无选区。Mac 合成双主体实际 Vision 请求已验证，真实 iPad/照片质量待验收；快速选择笔和边缘精修仍缺。见[范围](IPAD_ADVANCED_SELECTION.md)。 |
| 几何编辑 | `Document/LayerTransform.swift` 有位移、旋转、翻转、缩放、比例锁、中心/边缘锚点与吸附；`Distort.swift`、`Rendering/MetalWarp.swift` 有四角扭曲；`SmudgeLiquify.swift` 有涂抹/液化。 | `LayerTransform` 的多数数学**可复用**，但 `unitToDocument` 依赖 `BrushRaster`，部分编辑结构依赖浮动选区；需抽取公共几何层。鼠标手柄/快捷键需替换为触控交互，Metal 能力及边界采样**待验证**。 | `TransformTests.swift`、`ResizeSnapTests.swift`、`DistortTests.swift`、`MetalWarpTests.swift`、`MaskTransformTests.swift`；带棋盘透明边的旋转图层、翻转、非整数原点、选区和蒙版随动。 | **单层/选中像素及整层/整组共同仿射已实现，新增单层四角几何**：现有 `FreeTransform`、`SelectionTransform`、`LayerRegrid`、`LayerBatchTransform` 和视图旋转保留；`Core/QuadWarp.swift`、`Rendering/QuadRaster.swift`、`App/EditorQuadWarp.swift` 适配凸四边形单应映射、逆采样、透视同边联动及独立扭曲。整层带链接蒙版；选中像素沿用数值灰度补集，独立蒙版原位，必要时重网格。保存/导出读取正式稿，完成一次重采样、取消/原位保留资源和重做。文字/形状须显式栅格化。四角增加精确坐标草稿、显式应用与非法输入保护，最终整合原生 148 项/UI 25 项通过；多层选中像素/多层扭曲、吸附、网格变形和液化仍待后续。 |
| 色彩与调整 | `Document/LayerAdjustment.swift` 有可保存的色阶、曲线、HSV、曝光、渐变映射、颗粒、噪点、模糊、反相、黑白和色彩平衡；`Levels.swift`、`Curves.swift`、`HueSaturation.swift`、`ImageAdjustments.swift` 与 C 像素实现提供处理。 | 参数、查找表与算法**可复用**；多个文件直接 `import AppKit` 且包含会话/面板行为，需拆开。不可把“已有曝光/色彩平衡”直接称为独立亮度/对比度工具已完成。可编辑调整层和选区作用域都必须保留。 | `AdjustmentLayerTests.swift`、`LevelsTests.swift`、`HueSaturationTests.swift`、`ImageAdjustmentTests.swift`、`PSDAdjustmentTests.swift`；灰阶/色阶图、调整顺序、组和蒙版影响域。 | **已实现可撤销的基础像素调整**：`Rendering/DocumentRenderer.adjusted` 使用 Core Image 处理亮度、对比度、饱和度和高斯模糊；`App/EditorModel.adjustmentImage/applyAdjustment` 预览并按选区应用，保留图层蒙版。另已适配四通道曲线/色阶及可再次编辑的调整层，整稿/剪贴/组/数值蒙版作用域、预览、一次撤销和工程重开已接入，见[本轮范围](IPAD_COLOR_ADJUSTMENTS.md)。完整 HSV/曝光/色彩平衡、直方图、自动色阶等仍待后续，不宣称完整调色工具集。 |
| 修图与滤镜 | `Document/CloneStamp.swift`、`BlurTool.swift`、`ContentFill.swift`、`SmudgeLiquify.swift`、`Filters.swift` 有仿制、模糊、修复/内容填充、液化及常用滤镜；`Rendering/HealPixels.c`、`PatchPixels.c`、`NoisePixels.c` 等包含像素算法。 | C 与 CG/CI 算法**可复用**，调用方仍依赖桌面会话及取样交互；需以共享文档事务接入，避免只复制 C 文件便声称工具可用。GPU/大图性能**待验证**。 | `CloneStampTests.swift`、`SpotHealingTests.swift`、`BlurBrushTests.swift`、`FilterTests.swift`、`FinishingFilterTests.swift`、`ProgressiveBlurTests.swift`；源点对齐、跨层取样、透明边缘、软选区、撤销。 | **已接入高斯模糊的图层像素调整**；仿制、局部模糊笔刷、修复/内容填充、液化及其余上游滤镜未移植，不能把一个 CI 模糊操作当作完整修图工具集。 |
| 文字与形状 | `Document/TypeTool.swift` 保存文字内容、字体、字号、对齐、字距、行距、文本框与局部字体/颜色；`Rendering/InlineTextEditor.swift` 使用桌面文本编辑器。`ShapeTool.swift` 有矩形/椭圆/直线和圆角/平滑角，并保留可重绘样式；像素被其他工具修改后会转为普通像素层。 | 样式数据与 `CGPath` 几何**可复用**；`NSFont`/`NSAttributedString` 布局和 `NSTextView` **需平台改造**，缺字体策略需显式实现。未找到完整贝塞尔路径编辑器；不可宣称全面矢量编辑。 | `TypeToolTests.swift`、`ShapeToolTests.swift`、`PSDVectorFixtures.swift`；中文换行、缺字体、带局部样式文本、缩放后可编辑、像素化转换提示。 | **已接入保存后可重编的子集**：`Core/LayerContent.swift`、`EditableLayerEdit.swift`、`Rendering/LayerContentRaster.swift` 和内容面板保留 text/shape 参数与 PNG 缓存，CoreText 支持中文、多行和已有局部样式，系统字体选择器替代 AppKit。缺字体保留旧图并提示；正文面板按整段修改，未知富文本字段拒绝。矩形/椭圆/直线、圆角和平滑角按参数重绘，几何预览与原子提交一致。`LayerEffects.swift`、`LayerEffectsRaster.swift` 接入六种效果、扩边、一次蒙版覆盖及剪贴成品 alpha；像素编辑需显式栅格化。完整路径编辑、真实字体/触控体验仍待后续。 |
| 文件与颜色 | `IO/ProjectStore.swift` 的 `.comp` 当前写 v14、读 v1–14；保存分层像素/蒙版、几何、组、调整、文字、形状和效果。`ImageImporter.swift`/`ImageExporter.swift` 提供系统图像解码和 PNG/JPEG/TIFF/PDF/EXR 输出。`IO/PSD/PSDReader.swift` 明确只接受 8 位 RGB/CMYK，PSB 通过版本 2 读取；复杂效果转换有局限，未见 PSD/PSB 导出实现。 | 安全读写规则、ImageIO 和 PSD 字节解析**可复用**；图像导入仍含 AppKit，CMYK 用 AppKit/ColorSync，字体/形状转换依赖上层工具。当前沿用标准 `.comp` 清单与资源，只接受可保真的功能子集；iPad 专属状态使用另行标识的 `com.compositor.ipad-state` sidecar。不支持的上游字段明确拒绝，不能静默丢失后继续写成“兼容 .comp”。 | `ProjectTests.swift`、`ImageImportTests.swift`、`ExportTests.swift`、`JPEGExportTests.swift`、`PSBImportTests.swift`、`PSDRoundTripTests.swift`、`CMYKTests.swift`；注意名为 RoundTrip 的上游测试不证明 PSD 导出。 | **原生可编辑工程与受限 PSD 交换已接入**：`.comp` 保留受支持的栅格、曲线/色阶、文字/形状、六种效果及辅助线，未知嵌套字段/语义拒绝；原有栅格上游双向样例不扩展为新记录已完成双端验证。`PSDCodec`/`PSDByteCodec` 读写 v1/RGB8/raw/PackBits 与真实分层结构，严格拒绝不能保真的可编辑记录、组表现和剪贴组合。PSD RGB ICC 转 sRGB8，写入 sRGB ICC；不是原颜色模式无损往返。`ImageFileCodec` 按系统解码器导入 PNG/JPEG/HEIC/HEIF/TIFF/WebP，预检帧数/位深/HDR，导出透明 TIFF 和单页图像 PDF。PSB、CMYK、16/32 位、HDR、EXR、完整 PSD 元数据与 PDF 导入仍未实现。见[支持矩阵](IPAD_FILES_CROP_GUIDES.md)。 |
| AI 辅助 | 上游编辑器没有本仓库 API v1 的任务客户端、Windows 配对、候选去重或恢复记录。Windows 桥接已独立实现这些服务，不属于 Compositor 已有功能。 | 上游无此模块，iPad **新增实现** `Sources/Bridge/` 与 `App/EditorBridge.swift`；复用现有桥接协议和本地文档事务，不把网络写进绘画核心。源 PNG、蒙版与 metadata 不可变；AI 图层只 source-over 一次，不能二次乘蒙版；旧版本结果留作候选。 | 本仓库 `ipad_bridge/tests` 及 `examples/smoke_client.py`；重试相同字节、未知提交、断网重启、Int64、结果摘要、灰度边缘、裁切位置、重复应用及旧文档版本。 | **已实现并完成原生 HTTP 验证**：Keychain 配对、能力/就绪预检、不可变提交、Int64、轮询恢复、摘要/几何校验、候选预览/防重复/旧版本拒绝，以及确定字节的 ZIP 备份缓存和上传。模拟后端及真实 Windows 32×24 合成生成闭环均通过；后者约 5.544 秒。客户端有快照列表/下载 API，界面目前只提供上传；iPad 真机网络、后台与绘画质量仍待验收。 |
| 撤销、保存与恢复 | `Document/DocumentHistory.swift` 是嵌套事务快照；共享不可变 `CGImage`，无操作不清空 redo，按条数与保留图像内存裁剪，保存版本独立标记。`IO/ProjectController+ExternalChanges.swift` 检测磁盘变更，读取成功后替换，存在本地修改时经 `NSAlert` 决策。 | 历史语义和原子存储**可复用**；依赖整个上游模型，需与新核心结构适配；桌面外部变更提示**需平台改造**。磁盘变更重载不等于崩溃恢复或协同合并。 | `HistoryTests.swift`、`ExternalChangeTests.swift`、`ProjectWorkspaceTests.swift`；绘画后请求 AI、继续绘画、结果到达、插入后撤销/重做；保存失败不能标成已保存。 | **已实现并有核心回归**：`Core/DocumentEditor.swift` 使用有界 Data 快照，失败回滚、空操作保留重做，文稿版本在编辑/撤销/重做时递增；`DocumentStore.swift` 原子替换分层工程，应用自动保存并恢复上次文稿；网络任务及原始归档独立持久化。撤销历史仅会话内保留；外部变更合并、多标签恢复及严格崩溃恢复仍未实现。 |
| 大画布与渲染 | `Rendering/GPUCanvas.swift`、`TiledLayerRenderer.swift`、`DownsampleCache.swift`、`RasterSnapshot.swift` 和 `BrushStroke.swift` 有 Metal 合成、分块笔迹与缓存。`DocumentLimits.swift` 当前代码为单边 30,000、单表面 200M 像素、文档预算按物理内存计算并限制为 200–800M；格式文档仍有旧的 100M 说明。 | 分块及缓存策略**可复用**；`MetalCanvasView: NSView`、显示/内存压力事件**需平台改造**。不能把桌面内存预算复制到 iPad，也不能使用桥接 4M 输入上限当作永久画布上限。真机分配峰值、热量和后台恢复**待验证**。 | `TiledLayerTests.swift`、`GPUCanvasTests.swift`、`LargeCanvasBrushTests.swift`、`BrushPerformanceTests.swift`；按设备分别记录画布尺寸、层数、撤销深度、内存峰值和耗时。 | **已实现有限规模 CG/CI 渲染**：当前应用限制每边 4096 像素、每个栅格面最多 1600 万像素，缓存图层解码结果并限制历史内存。该范围独立于桥接单次输入上限；完整分块/Metal 合成、磁盘历史交换和真实大画布性能仍未移植/验收。已按用户实际1200×900尺寸测独立真机合成2/8层笔触处理与内存，详见[性能基线](IPAD_PERFORMANCE.md)，不等于Pencil到屏延迟。 |

## 首次抽取的边界

本次已抽取或改写 `CanvasViewport.swift` 的文档/屏幕坐标与锚点缩放、`BrushRaster.falloff` 的规范化高斯笔刷衰减、`LayerTransform.swift` 的基础几何、`LayerGroups.swift` 的层级/穿透规则、`LayerAppearance.swift` 的受支持混合映射，以及 `ProjectStore.swift` 的清单和安全资源规则。文件级注释标明来源、固定提交和 MIT 许可证。独立 iPad 核心不等于已移植完整 Compositor 引擎。

基础图层组、可绘制的链接蒙版、多选及受限合并、历史和 `.comp` 子集已经接入；同组连续栅格剪贴关系已补齐，后续按模型/渲染边界补齐更完整的组表现、高级选区/变换、非破坏性调整、修图和文字形状，同时推进分块笔刷与 GPU 合成。组蒙版的独立位置/未链接状态、任意实时蒙版及上游复杂文档兼容性仍须逐项扩展和验证，不能由基础组/蒙版样例推断。

上游的 `ProjectStore` 虽未直接导入 AppKit，仍引用 `ImportedImage`、`LayerAdjustment`、`LayerTextStyle`、`LayerEffects`、`DeepLayer` 等类型，不能把它标记为“直接搬到 iOS 即可”。类似地，Metal/C 文件存在并不等于整条调用路径跨平台。

本次使用 UIKit 输入和自有栅格笔刷，没有用 PencilKit 代替编辑器核心。图层/像素/选区/蒙版保存为分层工程，任务和原始请求独立持久化，编辑历史在当前会话保留。压力/倾斜的采样与笔刷效果已有实现及测试，真实硬件体验仍需单独验收。

## 本轮第 4、5、6 部分的验证状态

2026-10-29 最终验证：完整整合 SwiftPM 296 项（3 HTTP 跳过）、同一最终应用构建的原生 148 项与 UI 25 项全部通过。第 5 部分独立最终分支核心 262 项（3 跳过）、原生 143 项通过；第 4 部分阶段记录为核心 234 项（3 跳过）、原生 127 项通过。首轮完整 UI 为 22/24，两项数字输入问题修复后保留原断言并完成最终全套；用户提醒的剪贴和竖屏整理取消/无操作重做两项另各连续三次通过。18 项 PSD 定向测试及最终代码新生成 16 份独立样例验证通过，包含中间色 Alpha、真实组/剪贴、蒙版和 4096 边界。不同阶段数量不相加；本轮未安装新物理 iPad 版本，远端发布/新 CI 待授权。

真实 Vision 生产入口在 Mac 合成双主体图验证了全部/点选实例及方向；PSD 使用独立 Pillow/psd-tools 核对真实组、层序、剪贴标记与安全组合强制重合成。实际 iPad 上的对象识别、字体/触控、效果大图性能与完整文件工作流仍需验收。新预览共用串行队列，取消的旧队列项不得开始分配。详细事实及后续修复以 [IPAD_STATUS.md](IPAD_STATUS.md) 持续补记，未将先前单路绿色 CI 视为最终通过。

## 历史验证记录

下表保留首次移植阶段的构建与测试证据，数字和当时“待验收”项不代表当前最新状态。截至本轮盘点，`c107ece` 的完整 SwiftPM 108 项、iPad 原生单测 60 项和 UI 测试 5 项通过；用户已确认选区/取消选区、整层及选区自由变换和越界修复正常，并在此前确认 AI 锁屏恢复、备份成功及重开图层保留。后续逐轮记录以 [IPAD_STATUS.md](IPAD_STATUS.md) 为准，未将这些确认扩大到完整断网、低内存或长时间 Pencil 性能验收。

| 验证 | 本次结果 | 可以得出的结论 |
| --- | --- | --- |
| 上游固定提交与交接比较 | 相同；上游工作区未修改 | 盘点具有确定的源码基线 |
| 原 Mac target 编译 | 成功；Xcode 26.6 / macOS 26.4，未签名 | 上游在此 Mac 工具链可构建 |
| 上游历史、工程、导航与画笔测试 | `TEST SUCCEEDED`；45 个测试通过、0 失败（History 7、Project 10、Navigator 9、Brush 19） | 仅以上 4 个 suite 的 Mac 回归通过；其他上游测试未执行，不能推断 iPad 行为 |
| iPad 原生工程与模拟器 | `CompositorPad` 模拟器构建成功；最新模拟器测试 7 项通过（笔刷 6、界面 1） | 模拟器上的输入算法、启动/手指绘画/图层/撤销/重开样例通过；不是 Pencil 硬件验收 |
| iPad 共享 Swift 核心 | 36 项：文档 11、ZIP 3、渲染 11、桥接 11；最终离线运行 34 项通过、2 项网络集成按环境跳过；另配置 mock 环境桥接 11 项全通过，并已执行真实 Windows 集成 | 已实现的文档/像素/传输规则有回归证据，不能扩大成完整产品验收 |
| `.comp` 双向互通 | iPad 生成带组/透明度/蒙版/Multiply/旋转翻转/空白层的样例，上游真实 `ProjectStore` 读取、重存成功，iPad 再读成功 | 标准栅格子集可往返；上游重存移除 iPad 专属状态/选区。未验证的高级记录仍拒绝 |
| ZIP 与模拟后端 | 原生生成的 3350 字节、5 文件归档通过 Python `zipfile` CRC 校验，以及 Swift 客户端上传/重复上传/列表/原字节下载 | ZIP 容器、原字节缓存及现有快照 API 互通；不是双端实时同步 |
| 原生 Swift → 真实 Windows | 32×24 合成输入完成真实 HTTP 生成闭环，`isSimulation=false`，约 5.544 秒 | 真实后端认证/提交/查询/结果校验链路可用；不代表真实尺寸画稿质量、通用推理速度或 iPad UI 全流程已验收 |
| 应用内选区生成 UI 联调 | 已修复 ImageIO 重编码附加灰度 ICC 导致的拒绝；模拟器应用内选区上传、真实 Windows 生成预览、加入独立图层、一步撤销/重做、退出重开及 31 KB 分层工程备份均成功 | 合成文稿的应用内生成回填与备份闭环通过；实际 Pencil 体验仍单独验收 |
| 物理 iPad 安装与 Pencil | 已签名构建、安装并启动；两次间隔 45 秒检查进程持续运行且无本应用崩溃记录；用户确认 Pencil 绘画、撤销和重做正常 | 基本真机操作通过；压力/倾斜、精确延迟、防误触、长时间性能、后台及真机局域网仍需专项验收 |

本地回归入口：

- `ipad_app/Tests/CoreDocumentTests.swift`：历史、Int64、组/锁定、AI 插入/去重、分层保存与严格导入。
- `ipad_app/Tests/CoreArchiveTests.swift`：确定字节的 ZIP、独立解压校验、限额与危险路径。
- `ipad_app/Tests/RenderingTests.swift`：非方形坐标、旋转/翻转、蒙版和 alpha 只应用一次、穿透组、混合、缓存、选区局部映射、PNG/JPEG 和视口。
- `ipad_app/Tests/BridgeTests.swift`：配对/认证、不可变请求与归档、Int64、能力校验、恢复、生成和快照 HTTP 往返。
- `ipad_app/iOSTests/Unit/PadBrushStrokeTests.swift` 与 `ipad_app/iOSTests/UI/EditorSmokeTests.swift`：笔迹覆盖上限、橡皮/软选区、灰度蒙版、压力/倾斜、变换图层笔刷坐标及应用启动/编辑/重开。

详细运行记录和仍待验收事项见 [IPAD_STATUS.md](IPAD_STATUS.md)；构建与操作说明见 [客户端 README](../ipad_app/README.md)。

完整产品仍有阶段 2–4 的明确未实现项，当前提交不能作为 Photoshop 常用功能覆盖已完成的证明。
