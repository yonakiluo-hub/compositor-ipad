# Compositor → iPad 功能与移植清单

盘点日期：2026-10-20。产品范围仍以 [PRODUCT_REQUIREMENTS.md](PRODUCT_REQUIREMENTS.md) 为准；本文区分上游源码存在、iPad 已实现和实际运行验证，不能将其中任意一种当作另外两种。

## 版本与基线验证

- 上游：[qidian2022/Compositor-ZH，zh-Hans](https://github.com/qidian2022/Compositor-ZH/tree/zh-Hans)。本次获取并审查的 HEAD 为 [`7c2a5a4a3e7f685a8a0ec282ef0b4284f20b5477`](https://github.com/qidian2022/Compositor-ZH/tree/7c2a5a4a3e7f685a8a0ec282ef0b4284f20b5477)，与 Mac 交接记录完全相同，无新增提交差异。
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

## 按产品范围核查

| 功能类别 | 上游实际源码与支持情况 | 复用分类与 iPad 改造方式 | 回归样本与 iPad 验收 | 移植状态 |
| --- | --- | --- | --- | --- |
| 文档与画布 | `Document/EditorSession.swift` 的 `CanvasDocument`、`ImageLayer` 保留 UUID、层序、资产与独立变换；`IO/ProjectStore.swift` 保存分层目录包。`Rendering/CanvasViewport.swift` 有拟合、锚点缩放、平移及双向坐标转换。`Document/ProjectWorkspace.swift` 有多标签；`CanvasSize.swift`、`Crop.swift`、`CanvasRotation.swift` 有画布尺寸、裁切及文档 90° 旋转。 | 文档/坐标**可复用**；工作区和文件面板**需平台改造**，含 `NSWindow`/`NSOpenPanel`。`CanvasViewport` 无视图旋转参数，文档 90° 旋转不等于自由旋转视图。自动保存/进程异常恢复在相关存储入口未找到，属**缺失需开发**。 | `ProjectTests.swift`、`CanvasSizeTests.swift`、`CropTests.swift`、`CanvasRotationTests.swift`、`NavigatorTests.swift`；iPad 应验证非方形画布四角、缩放锚点、保存重开、原子替换失败及恢复。 | **已实现基础子集**：`Core/CanvasDocument.swift`、`App/EditorModel.swift` 和 `App/CanvasView.swift` 提供本地分层文稿、新建/导入/文稿库切换、自动保存、拟合/平移/锚点缩放、画布宽高调整及按比例改变图层几何。多标签并行编辑、自由视图旋转、完整裁切/重采样工具仍待开发。 |
| 绘画与 Pencil | `Document/BrushStroke.swift` 有 256px 按需分块、硬度衰减、笔迹不透明度上限、平滑、选区裁切和笔迹提交；`EditorSession+Brush.swift` 管理工具事务；`Rendering/BrushPixels.c`、`MetalBrushCoverage.swift` 有 CPU/GPU 覆盖算法。`Gradient.swift` 支持线性/径向渐变；`SelectionEdits.swift` 支持填充。 | 软笔刷曲线、分块与覆盖算法**可复用**；整笔迹模块关联层、选区、深色彩和 Metal 类型，不能直接拷贝一文件。`EditorCanvas.swift` 的 `NSView`/`NSEvent` **需平台改造**。本次未找到 Pencil 的压力、倾斜、方位、合并/预测触点输入，属**缺失需开发**；`GPUCanvas` 的 pressure 是内存压力，不能视作笔压。 | `BrushTests.swift`、`LargeCanvasBrushTests.swift`、`NativeResolutionPaintTests.swift`、`BrushIntersectionTests.swift`、`GradientTests.swift`。真机需验证 Pencil 与手指区分、断续笔迹、压力、倾斜、防误触、橡皮和撤销。 | **已实现自有基础笔刷**：`App/BrushInput.swift`、`App/CanvasView.swift` 接入 Pencil 压力、倾斜/方位及合并触点，支持硬度/大小/浓度、橡皮、选区约束、吸色和填充；区分手指导航与绘画，每笔提交单次事务。完整上游分块笔刷、预测触点、笔刷预设与渐变未移植；真实 Pencil 手感、防误触和延迟待验收。 |
| 图层体系 | `EditorSession.swift`、`LayerGroups.swift`、`LayerMerge.swift`、`LayerAppearance.swift`、`LiveLayerMask.swift` 支持新建/复制/排序/合并、组、透明度、混合、剪贴来源。`LayerMask.swift` 有启用、链接、独立位置与灰度规则。`ImageLayer` 和 `ProjectLayerRecord` 未见图层锁定字段。 | 模型、组合法性、合成次序和蒙版**可复用**；需剥离 `EditorSession` 的桌面 UI 状态。`LayerAppearance` 枚举含 24 种模式；部分必须走 Core Image，不能统一映射为普通 Core Graphics 混合。图层锁定**缺失需开发**。 | `LayerTests.swift`、`GroupTests.swift`、`LayerAppearanceTests.swift`、`LayerMaskTests.swift`、`LiveMaskTests.swift`。透明底 + 半透明红蓝层、组中组、剪贴环、蒙版独立移动和保存重开是必要样本。 | **已实现基础图层体系**：`Core/DocumentEditor.swift`、`Core/LayerGeometry.swift` 与 `Rendering/DocumentRenderer.swift` 支持新建/复制/删除/同级排序、可见性、不透明度、锁定、穿透组层级、12 种直接实现的混合模式和链接式灰度图层蒙版。界面可新建组并在组内建层；已有层重新分组仅有核心 API。合并/盖印、剪贴关系、独立蒙版位置、组蒙版及其余混合模式未接入。 |
| 选区与蒙版 | `Document/Selection.swift` 有矩形、椭圆、自由/多边形套索、羽化、扩展/收缩；`MagicWand.swift`、`ColorRangeSelection.swift`、`ObjectSelection.swift` 有颜色与对象选区；`SelectionEdits.swift` 将作用域用于像素编辑。`SelectionMode` 只有 replace/add/subtract；路径与画布求交不等于用户可用的选区交集模式。 | 路径/灰度覆盖和几何**可复用**，AppKit 工具与 Vision 对象选择**需平台改造及验证**；交集模式需补齐。灰度蒙版须无 alpha、无颜色转换；UI 显示用的红色遮罩不可直接拿来上传。 | `SelectionTests.swift`、`SelectionFeatherTests.swift`、`SelectionEditTests.swift`、`MagicWandTests.swift`、`MaskTransformTests.swift`；全黑、全白、128 灰度、羽化边缘和非零裁切原点。 | **已实现常用形状选区**：`Rendering/SelectionMask.swift` 适配上游路径光栅化、Gaussian sigma=radius/2 羽化和边缘钳制，补充灰度 max/饱和减/min 组合与交集；自由套索采用 even-odd 规则。`App/SelectionGesture.swift` 适配文档坐标采样并增加触控多边形、参数冻结及取消语义，`EditorSelection.swift` 接入单步事务。矩形、椭圆、自由/多边形套索支持新建/添加/减去/相交和0–100像素羽化，保存同一灰度PNG，绘画/填充/调整/AI共享软边。原选区笔、反选、选区转图层蒙版保留。魔棒、边缘精修、独立蒙版画笔及未链接蒙版仍待开发。 |
| 几何编辑 | `Document/LayerTransform.swift` 有位移、旋转、翻转、缩放、比例锁、中心/边缘锚点与吸附；`Distort.swift`、`Rendering/MetalWarp.swift` 有四角扭曲；`SmudgeLiquify.swift` 有涂抹/液化。 | `LayerTransform` 的多数数学**可复用**，但 `unitToDocument` 依赖 `BrushRaster`，部分编辑结构依赖浮动选区；需抽取公共几何层。鼠标手柄/快捷键需替换为触控交互，Metal 能力及边界采样**待验证**。 | `TransformTests.swift`、`ResizeSnapTests.swift`、`DistortTests.swift`、`MetalWarpTests.swift`、`MaskTransformTests.swift`；带棋盘透明边的旋转图层、翻转、非整数原点、选区和蒙版随动。 | **已实现基础几何操作**：`Core/LayerGeometry.swift` 保存独立位移/尺寸/旋转/翻转，画布可拖动普通图层，面板支持缩放、水平翻转和 90° 旋转；变换保留源像素和链接蒙版。画布大小调整可选同步缩放图层几何，尚非源图像重采样。自由变换手柄、任意角度交互旋转、吸附/透视、扭曲和液化尚未移植。 |
| 色彩与调整 | `Document/LayerAdjustment.swift` 有可保存的色阶、曲线、HSV、曝光、渐变映射、颗粒、噪点、模糊、反相、黑白和色彩平衡；`Levels.swift`、`Curves.swift`、`HueSaturation.swift`、`ImageAdjustments.swift` 与 C 像素实现提供处理。 | 参数、查找表与算法**可复用**；多个文件直接 `import AppKit` 且包含会话/面板行为，需拆开。不可把“已有曝光/色彩平衡”直接称为独立亮度/对比度工具已完成。可编辑调整层和选区作用域都必须保留。 | `AdjustmentLayerTests.swift`、`LevelsTests.swift`、`HueSaturationTests.swift`、`ImageAdjustmentTests.swift`、`PSDAdjustmentTests.swift`；灰阶/色阶图、调整顺序、组和蒙版影响域。 | **已实现可撤销的基础像素调整**：`Rendering/DocumentRenderer.adjusted` 使用 Core Image 处理亮度、对比度、饱和度和高斯模糊；`App/EditorModel.adjustmentImage/applyAdjustment` 预览并按选区应用，保留图层蒙版。未移植上游可编辑调整图层、色阶、曲线、完整 HSV/曝光/色彩平衡等，不宣称完整调色工作流。 |
| 修图与滤镜 | `Document/CloneStamp.swift`、`BlurTool.swift`、`ContentFill.swift`、`SmudgeLiquify.swift`、`Filters.swift` 有仿制、模糊、修复/内容填充、液化及常用滤镜；`Rendering/HealPixels.c`、`PatchPixels.c`、`NoisePixels.c` 等包含像素算法。 | C 与 CG/CI 算法**可复用**，调用方仍依赖桌面会话及取样交互；需以共享文档事务接入，避免只复制 C 文件便声称工具可用。GPU/大图性能**待验证**。 | `CloneStampTests.swift`、`SpotHealingTests.swift`、`BlurBrushTests.swift`、`FilterTests.swift`、`FinishingFilterTests.swift`、`ProgressiveBlurTests.swift`；源点对齐、跨层取样、透明边缘、软选区、撤销。 | **已接入高斯模糊的图层像素调整**；仿制、局部模糊笔刷、修复/内容填充、液化及其余上游滤镜未移植，不能把一个 CI 模糊操作当作完整修图工具集。 |
| 文字与形状 | `Document/TypeTool.swift` 保存文字内容、字体、字号、对齐、字距、行距、文本框与局部字体/颜色；`Rendering/InlineTextEditor.swift` 使用桌面文本编辑器。`ShapeTool.swift` 有矩形/椭圆/直线和圆角/平滑角，并保留可重绘样式；像素被其他工具修改后会转为普通像素层。 | 样式数据与 `CGPath` 几何**可复用**；`NSFont`/`NSAttributedString` 布局和 `NSTextView` **需平台改造**，缺字体策略需显式实现。未找到完整贝塞尔路径编辑器；不可宣称全面矢量编辑。 | `TypeToolTests.swift`、`ShapeToolTests.swift`、`PSDVectorFixtures.swift`；中文换行、缺字体、带局部样式文本、缩放后可编辑、像素化转换提示。 | 尚未移植。 |
| 文件与颜色 | `IO/ProjectStore.swift` 的 `.comp` 当前写 v14、读 v1–14；保存分层像素/蒙版、几何、组、调整、文字、形状和效果。`ImageImporter.swift`/`ImageExporter.swift` 提供系统图像解码和 PNG/JPEG/TIFF/PDF/EXR 输出。`IO/PSD/PSDReader.swift` 明确只接受 8 位 RGB/CMYK，PSB 通过版本 2 读取；复杂效果转换有局限，未见 PSD/PSB 导出实现。 | 安全读写规则、ImageIO 和 PSD 字节解析**可复用**；图像导入仍含 AppKit，CMYK 用 AppKit/ColorSync，字体/形状转换依赖上层工具。当前沿用标准 `.comp` 清单与资源，只接受可保真的功能子集；iPad 专属状态使用另行标识的 `com.compositor.ipad-state` sidecar。不支持的上游字段明确拒绝，不能静默丢失后继续写成“兼容 .comp”。 | `ProjectTests.swift`、`ImageImportTests.swift`、`ExportTests.swift`、`JPEGExportTests.swift`、`PSBImportTests.swift`、`PSDRoundTripTests.swift`、`CMYKTests.swift`；注意名为 RoundTrip 的上游测试不证明 PSD 导出。 | **已实现分层 `.comp` v1–14 栅格子集读入、v14 写出及 PNG/JPEG 导出**：`Core/DocumentStore.swift` 原子保存原 PNG、变换、组、混合与链接蒙版；`ipad-state.json`/`selection.png` 保留版本、锁定、选区及 AI 收据。上游真实读写器双向样例验证通过。含未实现文本/形状/效果/调整/辅助线/剪贴/其他蒙版/混合或未知字段的工程拒绝加载；PSD/PSB、CMYK、16 位/HDR 及完整 v14 功能未接入。 |
| AI 辅助 | 上游编辑器没有本仓库 API v1 的任务客户端、Windows 配对、候选去重或恢复记录。Windows 桥接已独立实现这些服务，不属于 Compositor 已有功能。 | 上游无此模块，iPad **新增实现** `Sources/Bridge/` 与 `App/EditorBridge.swift`；复用现有桥接协议和本地文档事务，不把网络写进绘画核心。源 PNG、蒙版与 metadata 不可变；AI 图层只 source-over 一次，不能二次乘蒙版；旧版本结果留作候选。 | 本仓库 `ipad_bridge/tests` 及 `examples/smoke_client.py`；重试相同字节、未知提交、断网重启、Int64、结果摘要、灰度边缘、裁切位置、重复应用及旧文档版本。 | **已实现并完成原生 HTTP 验证**：Keychain 配对、能力/就绪预检、不可变提交、Int64、轮询恢复、摘要/几何校验、候选预览/防重复/旧版本拒绝，以及确定字节的 ZIP 备份缓存和上传。模拟后端及真实 Windows 32×24 合成生成闭环均通过；后者约 5.544 秒。客户端有快照列表/下载 API，界面目前只提供上传；iPad 真机网络、后台与绘画质量仍待验收。 |
| 撤销、保存与恢复 | `Document/DocumentHistory.swift` 是嵌套事务快照；共享不可变 `CGImage`，无操作不清空 redo，按条数与保留图像内存裁剪，保存版本独立标记。`IO/ProjectController+ExternalChanges.swift` 检测磁盘变更，读取成功后替换，存在本地修改时经 `NSAlert` 决策。 | 历史语义和原子存储**可复用**；依赖整个上游模型，需与新核心结构适配；桌面外部变更提示**需平台改造**。磁盘变更重载不等于崩溃恢复或协同合并。 | `HistoryTests.swift`、`ExternalChangeTests.swift`、`ProjectWorkspaceTests.swift`；绘画后请求 AI、继续绘画、结果到达、插入后撤销/重做；保存失败不能标成已保存。 | **已实现并有核心回归**：`Core/DocumentEditor.swift` 使用有界 Data 快照，失败回滚、空操作保留重做，文稿版本在编辑/撤销/重做时递增；`DocumentStore.swift` 原子替换分层工程，应用自动保存并恢复上次文稿；网络任务及原始归档独立持久化。撤销历史仅会话内保留；外部变更合并、多标签恢复及严格崩溃恢复仍未实现。 |
| 大画布与渲染 | `Rendering/GPUCanvas.swift`、`TiledLayerRenderer.swift`、`DownsampleCache.swift`、`RasterSnapshot.swift` 和 `BrushStroke.swift` 有 Metal 合成、分块笔迹与缓存。`DocumentLimits.swift` 当前代码为单边 30,000、单表面 200M 像素、文档预算按物理内存计算并限制为 200–800M；格式文档仍有旧的 100M 说明。 | 分块及缓存策略**可复用**；`MetalCanvasView: NSView`、显示/内存压力事件**需平台改造**。不能把桌面内存预算复制到 iPad，也不能使用桥接 4M 输入上限当作永久画布上限。真机分配峰值、热量和后台恢复**待验证**。 | `TiledLayerTests.swift`、`GPUCanvasTests.swift`、`LargeCanvasBrushTests.swift`、`BrushPerformanceTests.swift`；按设备分别记录画布尺寸、层数、撤销深度、内存峰值和耗时。 | **已实现有限规模 CG/CI 渲染**：当前应用限制每边 4096 像素、每个栅格面最多 1600 万像素，缓存图层解码结果并限制历史内存。该范围独立于桥接单次输入上限；完整分块/Metal 合成、磁盘历史交换和真实大画布性能仍未移植/验收。已按用户实际1200×900尺寸测独立真机合成2/8层笔触处理与内存，详见[性能基线](IPAD_PERFORMANCE.md)，不等于Pencil到屏延迟。 |

## 首次抽取的边界

本次已抽取或改写 `CanvasViewport.swift` 的文档/屏幕坐标与锚点缩放、`BrushRaster.falloff` 的规范化高斯笔刷衰减、`LayerTransform.swift` 的基础几何、`LayerGroups.swift` 的层级/穿透规则、`LayerAppearance.swift` 的受支持混合映射，以及 `ProjectStore.swift` 的清单和安全资源规则。文件级注释标明来源、固定提交和 MIT 许可证。独立 iPad 核心不等于已移植完整 Compositor 引擎。

基础图层组、链接蒙版、历史及 `.comp` 子集已经接入；后续按模型/渲染边界补齐高级选区/变换、非破坏性调整、修图和文字形状，同时推进分块笔刷与 GPU 合成。图层组蒙版、剪贴图及上游复杂文档兼容性仍须逐项扩展和验证，不能由基础组/蒙版样例推断。

上游的 `ProjectStore` 虽未直接导入 AppKit，仍引用 `ImportedImage`、`LayerAdjustment`、`LayerTextStyle`、`LayerEffects`、`DeepLayer` 等类型，不能把它标记为“直接搬到 iOS 即可”。类似地，Metal/C 文件存在并不等于整条调用路径跨平台。

本次使用 UIKit 输入和自有栅格笔刷，没有用 PencilKit 代替编辑器核心。图层/像素/选区/蒙版保存为分层工程，任务和原始请求独立持久化，编辑历史在当前会话保留。压力/倾斜的采样与笔刷效果已有实现及测试，真实硬件体验仍需单独验收。

## 验证状态

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
