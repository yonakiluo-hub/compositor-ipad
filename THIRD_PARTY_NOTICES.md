# Third-party notices

## ComfyUI workflow template

`ipad_bridge/bridge/presets/paint-edit-v1.json` adapts the native node topology of Comfy Org's FLUX.2 Klein 4B distilled image-edit template into a ComfyUI API graph. This project adds its own input/output bindings and restores the output to the submitted crop dimensions; the bridge applies the user's mask to the returned alpha separately.

- Upstream project: [Comfy-Org/workflow_templates](https://github.com/Comfy-Org/workflow_templates)
- Template: [image_flux2_klein_image_edit_4b_distilled.json](https://github.com/Comfy-Org/workflow_templates/blob/main/templates/image_flux2_klein_image_edit_4b_distilled.json)
- Copyright: Copyright (c) 2023-present Comfy Org
- License: MIT; the upstream license is preserved in [licenses/ComfyUI-Workflow-Templates-MIT.txt](licenses/ComfyUI-Workflow-Templates-MIT.txt).
- License source: [upstream LICENSE](https://github.com/Comfy-Org/workflow_templates/blob/main/LICENSE), retrieved 2026-10-19.

This notice covers that adapted preset; it does not assign a license to the rest of this repository.

`ipad_bridge/bridge/presets/qwen21-edit-v1.json` and `qwen21-turbo-edit-v1.json` also adapt Comfy Org's MIT workflow templates, pinned at commit `d0e41fe5423f93db5b5872cf273d7b1af8aa68bc`:

- [Qwen-Image-2.1 image-edit template](https://github.com/Comfy-Org/workflow_templates/blob/d0e41fe5423f93db5b5872cf273d7b1af8aa68bc/templates/image_qwen_image_2_1_image_edit.json)
- [Qwen-Image-2.1 Turbo image-edit template](https://github.com/Comfy-Org/workflow_templates/blob/d0e41fe5423f93db5b5872cf273d7b1af8aa68bc/templates/image_qwen_image_2_1_turbo_image_edit.json)

The API adaptations retain a single reference, preserve source alpha, restore the submitted crop dimensions and leave the selection mask to bridge output compositing. The Turbo preset uses the base model with the official Turbo LoRA combination documented by [Comfy-Org/Qwen-Image-2.1](https://huggingface.co/Comfy-Org/Qwen-Image-2.1). Copyright (c) 2023-present Comfy Org; the same preserved [MIT license](licenses/ComfyUI-Workflow-Templates-MIT.txt) applies to these template adaptations. See [the experiment record](docs/QWEN_EXPERIMENT.md).

The Qwen-Image-2.1 and Turbo model weights have separate research/evaluation restrictions; commercial use requires a separate license. These workflow notices do not grant model-use rights. [Base model license](https://huggingface.co/Qwen/Qwen-Image-2.1/blob/main/LICENSE), [Turbo model license](https://huggingface.co/Qwen/Qwen-Image-2.1-Turbo/blob/main/LICENSE). Model weights are not distributed here.

## External applications and models

ComfyUI runs as a separately installed application. Python dependencies are installed from the requirements files and retain their respective licenses. Neither ComfyUI application code nor model weights are distributed in this repository.

## Compositor geometry and raster conventions

The iPad editor includes and adapts code from [Compositor-ZH](https://github.com/qidian2022/Compositor-ZH), commit `7c2a5a4a3e7f685a8a0ec282ef0b4284f20b5477`, based on Compositor v1.5.3 by Robbie Tilton / Wonder Assembly LLC.

- `ipad_app/Sources/Rendering/CanvasViewport.swift`: viewport geometry and anchored zoom; rotation-aware mapping and anchored view rotation are iPad additions.
- `ipad_app/Sources/Core/LayerGeometry.swift`: layer transforms and pass-through hierarchy semantics.
- `ipad_app/Sources/Core/FreeTransform.swift`: fixed-anchor resizing and angle-delta rotation adapted from `Document/LayerTransform.swift` (`TransformDrag`); finite-value guards and non-flipping minimum sizes are iPad adaptations.
- `ipad_app/Sources/Rendering/SelectionTransform.swift`: selected-pixel lift, affine placement and transactional merge adapted from `Document/FloatingSelection.swift`, `SelectionClipboard.swift` and `BrushStroke.swift`. Numeric gray-mask transport, stationary independent layer masks and coverage-aware premultiplied overlap composition are iPad adaptations; they prevent soft selections from fading when the moved content overlaps its original position.
- `ipad_app/Sources/App/TransformOverlay.swift`: transform handle geometry adapted from `Rendering/TransformOverlay.swift`, with touch-sized targets and rotated-viewport mapping.
- `ipad_app/Sources/Rendering/RasterImage.swift`: normalized Gaussian brush falloff adapted from `BrushRaster.falloff`.
- `ipad_app/Sources/Rendering/SelectionMask.swift`: path rasterization and Gaussian feather radius/edge conventions adapted from `Document/Selection.swift`; raster coverage combination and intersection are iPad additions.
- `ipad_app/Sources/App/SelectionGesture.swift`: document-coordinate draft and quarter-pixel path sampling adapted from `Document/Selection.swift`; touch-up vertices, frozen options, even-odd closure and command handling are iPad adaptations.
- `ipad_app/Sources/App/EditorLayerMask.swift` and the mask path in `App/BrushInput.swift`: numeric grayscale coverage copying, mask edit targets and one-stroke transactions adapted from `Document/LayerMask.swift`, `BrushStroke.swift` and `EditorSession+Brush.swift`. Pencil input, target invalidation and editing masks at their own resolution are iPad adaptations.
- `ipad_app/Sources/Rendering/LayerMerge.swift`: selected subtree normalization, raster merging and insertion adapted from `Document/LayerMerge.swift`, also reviewed in the official Compositor repository at `365b5745eda537f984f3d5bed1e53c361dbc9c91`. Full bounds beyond the canvas, explicit limits on backdrop-dependent merges and initially hidden stamped copies are iPad adaptations.
- `ipad_app/Sources/Rendering/DocumentRenderer.swift`, `Core/DocumentEditor.swift` and `Core/LayerGeometry.swift`: clipping-stack color composition with one-time base-alpha restoration adapted from `Rendering/LiveMaskRenderer.swift`, `Rendering/BrushPixels.c` and `Document/LiveLayerMask.swift`. The iPad subset requires contiguous same-parent raster stacks, atomically rejects mutations that detach dependencies, and hides the whole stack when its base is hidden. This differs from arbitrary upstream live-mask graphs, where a hidden source can still supply alpha.
- The native `.comp` reader/writer follows the inspected upstream v14 manifest and asset conventions; it implements an explicitly limited raster subset.
- Copyright (c) 2026 Wonder Assembly LLC. MIT license retained in [licenses/Compositor-MIT.txt](licenses/Compositor-MIT.txt), with the original Chinese branch notice in [licenses/Compositor-ZH-NOTICE.md](licenses/Compositor-ZH-NOTICE.md).

Apart from the adaptations listed above, the iPad UIKit input layer, bridge client, persistence extension and UI are developed in this repository. This notice does not change the license of unrelated project code. See [the port matrix](docs/COMPOSITOR_PORT_MATRIX.md) for inspected upstream files and feature boundaries.

[comfyui-photoshop](https://github.com/NimaNzrii/comfyui-photoshop) was reviewed as an integration reference; its Photoshop plugin and custom-node code are not included here.
