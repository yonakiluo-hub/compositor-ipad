# Third-party notices

## ComfyUI workflow template

`ipad_bridge/bridge/presets/paint-edit-v1.json` adapts the native node topology of Comfy Org's FLUX.2 Klein 4B distilled image-edit template into a ComfyUI API graph. This project adds its own input/output bindings and restores the output to the submitted crop dimensions; the bridge applies the user's mask to the returned alpha separately.

- Upstream project: [Comfy-Org/workflow_templates](https://github.com/Comfy-Org/workflow_templates)
- Template: [image_flux2_klein_image_edit_4b_distilled.json](https://github.com/Comfy-Org/workflow_templates/blob/main/templates/image_flux2_klein_image_edit_4b_distilled.json)
- Copyright: Copyright (c) 2023-present Comfy Org
- License: MIT; the upstream license is preserved in [licenses/ComfyUI-Workflow-Templates-MIT.txt](licenses/ComfyUI-Workflow-Templates-MIT.txt).
- License source: [upstream LICENSE](https://github.com/Comfy-Org/workflow_templates/blob/main/LICENSE), retrieved 2026-10-19.

This notice covers that adapted preset; it does not assign a license to the rest of this repository.

## External applications and models

ComfyUI runs as a separately installed application. Python dependencies are installed from the requirements files and retain their respective licenses. Neither ComfyUI application code nor model weights are distributed in this repository.

[Compositor-ZH](https://github.com/qidian2022/Compositor-ZH) is the reference for the planned iPad editor. Its Swift source is not currently included here. Any future imported or adapted files must preserve the applicable upstream license, copyright, and notices.

[comfyui-photoshop](https://github.com/NimaNzrii/comfyui-photoshop) was reviewed as an integration reference; its Photoshop plugin and custom-node code are not included here.
