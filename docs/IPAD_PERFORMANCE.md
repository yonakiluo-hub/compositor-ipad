# iPad 绘画处理性能基线

测量日期：2026 年 10 月 20 日，Asia/Shanghai。源码基线为 `6a3c7e6433d5f7979bf35ef5c7e54f4c6b3e7a25`，使用 **Debug** 构建；这是后续选区与笔刷改动之前的对照，不代表这些改动后的性能。

在 iPad Pro 11 英寸（第三代，iPadOS 26.5.2）上，独立性能测试宿主通过了两个测试：合成笔触处理基线，以及调用后台保存入口后的文稿重开一致性。测试来自 [EditorPerformanceTests.swift](../ipad_app/iOSTests/Unit/EditorPerformanceTests.swift)。模拟器也通过同样两个测试；下表只报告真机结果。

## 工作负载与测量边界

- 画布为 1200×900 像素，分别测试 2 层和 8 层。尺寸与 2 层数量来自已确认的真实工程备份清单；测试图像全部重新合成，没有使用用户画稿、提示词、配对信息或生成结果。
- 每层为合成条带像素，包含透明度、部分图层蒙版与 Multiply 混合；笔触受选区约束。此内容较易压缩，不能据此保证复杂真实画稿具有同样的 PNG 编码或保存时间。
- 每个工作负载只执行一条合成笔触，共 40 批，每批 4 个样本，总计 160 个样本。笔刷直径 28、硬度 0.8、不透明度 0.7，按确定路径变化压力与倾斜参数。批次没有按屏幕刷新周期限速。
- 分别计时 `PadBrushStroke.add`、`stroke.image()`、替换活动图层后的全层合成，再单独计时最终 PNG 编码和编辑提交／刷新。批次分布来自同一条笔触的 40 批，不是 40 次独立启动。
- **这些数值不是 Pencil 到屏幕的延迟，也不是帧率保证。** 测量不包含真实触控交付、系统合并采样、屏幕扫描、GPU 呈现、长时间温控或后台调度；没有进行真实 Pencil 硬件输入测量。

## 真机处理时间

单位为毫秒；Median 是批次中位数，P95 是 40 批中的第 95 百分位。

| 阶段 | 2 层 Median | 2 层 P95 | 8 层 Median | 8 层 P95 |
| --- | ---: | ---: | ---: | ---: |
| 4 样本笔触处理 | 0.516 | 0.775 | 0.509 | 0.824 |
| 生成整幅笔触预览 | 1.845 | 1.899 | 1.877 | 2.041 |
| 全层合成 | 1.532 | 1.628 | 7.528 | 8.196 |
| 批次总处理 | 3.968 | 4.230 | 10.012 | 11.022 |

下表每项只有一次测量，不提供 P95：

| 阶段 | 2 层 | 8 层 |
| --- | ---: | ---: |
| 首次合成，包含冷缓存解码 | 5.941 | 24.886 |
| 笔触覆盖缓冲分配 | 0.006 | 0.005 |
| 最终笔触 PNG 编码 | 7.239 | 7.251 |
| 提交事务并刷新合成 | 4.779 | 11.197 |

8 层时，全层合成约占批次中位处理时间的 75%；采样与笔触预览时间基本没有随层数增长。当前可确认的主要扩展瓶颈是每次预览都重新合成完整图层栈，而非这组负载下的压力样本插值。

源码路径也支持这个判断：`CanvasView` 每次收到一组输入后调用 `stroke.image()` 分配整幅预览缓冲，绘制时再调用 `DocumentRenderer.render` 遍历可见图层；结束笔触后同步编码 PNG 并刷新合成。后续可先评估减少同一显示周期内重复预览、记录笔触更新范围，以及复用未变化图层的合成结果；需要保留混合、蒙版和撤销语义并对照重测。本轮不以此为由扩展 Metal 渲染。

## 内存采样

使用 `task_vm_info.phys_footprint` 每 2 ms 采样，并在每个批次及提交后补采样。单位为 MiB（1,048,576 字节）。

| 工作负载 | 窗口开始时进程占用 | 窗口内采样最高占用 | 相对增加 | 采样次数 |
| --- | ---: | ---: | ---: | ---: |
| 1200×900，2 层 | 51.42 | 65.47 | 14.05 | 123 |
| 1200×900，8 层 | 51.58 | 65.56 | 13.98 | 252 |

采样窗口从合成数据构建、首次合成及选区准备完成后开始，覆盖笔触预览、PNG 编码、提交与刷新。数字包括独立测试宿主的进程占用，**不是整款应用所有流程的内存峰值**；不包含数据构建期间的峰值，也没有加载真实文稿、候选历史或用户的长期撤销栈。短于采样间隔的分配峰值可能被漏过，不能将它当作操作系统保证的最高值或内存预算。

## 后台保存入口与重开

独立目录中的 1200×900 合成文稿先加载两层及图层蒙版，然后新增一层、修改选区，调用实际 `EditorModel.suspend()`，再以相同隔离目录创建新的 `EditorModel`。完整文稿值、3 个图层、原像素与蒙版、选区及版本一致；此次同步保存耗时 11.742 ms。

这是**程序调用生命周期入口后的保存／重开验证**。它没有模拟操作系统杀进程、真正锁屏、低内存终止或文件写入中途掉电，不能替代这些场景的真机验收。测试禁用 Keychain 配对加载，文稿与偏好使用临时目录和独立域，不读取或修改生产应用的数据。

## 复现与后续对照

先选择要比较的提交。为保护实际画稿，真机性能测试必须使用不同于生产应用的 bundle identifier 和独立沙盒；不要直接将生产应用作为性能测试宿主运行。下面只包含公共标识与占位参数，开发团队和设备标识从本机配置取得，不写入仓库。

从仓库根目录创建临时源码副本，并叠加当前的合成测试：

```sh
source_revision=6a3c7e6433d5f7979bf35ef5c7e54f4c6b3e7a25
perf_root="$(mktemp -d)"
git archive "$source_revision" ipad_app | tar -x -C "$perf_root"
cp ipad_app/iOSTests/Unit/EditorPerformanceTests.swift "$perf_root/ipad_app/iOSTests/Unit/"
python3 - "$perf_root/ipad_app" <<'PY'
from pathlib import Path
import subprocess
import sys
root = Path(sys.argv[1])
generator = root / "tools/generate_project.py"
generator.write_text(generator.read_text().replace(
    "com.compositor.ipad.dev", "com.compositor.ipad.performance"))
info = root / "Resources/Info.plist"
info.write_text(info.read_text().replace(
    "<string>Compositor</string>", "<string>Compositor Performance</string>"))
subprocess.run([sys.executable, str(generator)], check=True)
PY
```

核对临时工程的应用和测试目标均使用独立标识，再在 Xcode 选定测试设备，或将下列占位参数替换为本机值后执行：

```sh
xcodebuild -project "$perf_root/ipad_app/CompositorPad.xcodeproj" \
  -scheme CompositorPad -configuration Debug \
  -destination 'platform=iOS,id=<IPAD_UDID>' \
  -only-testing:CompositorPadTests/EditorPerformanceTests \
  -parallel-testing-enabled NO \
  -resultBundlePath "$perf_root/performance.xcresult" \
  'DEVELOPMENT_TEAM=<YOUR_TEAM_ID>' -allowProvisioningUpdates test
```

构建环境若需要 `test-without-building`，可使用单独构建出的应用与 `CompositorPadTests.xctest` 配置 `.xctestrun`，同样只选本测试类，并核对 `TestHostBundleIdentifier` 为独立性能宿主。不要把模拟器的路径或注入配置直接用于真机。

测试输出 `COMPOSITOR_PERFORMANCE` JSON 和 `COMPOSITOR_BACKGROUND_SAVE` 行，并把每个工作负载的 JSON 作为 XCTest attachment 保留。用同样的构建类型、尺寸、层数、采样数和内容比较前后变化；测试进程可通过 `COMPOSITOR_PERFORMANCE_WIDTH`、`COMPOSITOR_PERFORMANCE_HEIGHT` 改变合成尺寸，必须同时记录该条件。不要把设备之间或 Debug 与 Release 之间的差异直接归因于代码改动。

结束后只卸载本次创建的 `com.compositor.ipad.performance` 测试宿主；保留本地报告与 `.xcresult`，不卸载生产应用、不删除用户画稿。本次已清理真机和既有模拟器中的独立性能宿主，没有新建或删除模拟器。
