# Collaboration instructions

- This repository is the shared source of truth for the iPad client and local Windows bridge. Do not edit older exported copies when working here.
- Read `README.md`, then `docs/MAC_AGENT_HANDOFF.md` for iPad work or `ipad_bridge/README.md` for backend work. The implemented protocol is `ipad_bridge/docs/API_V1.md`.
- Put native iPad work under `ipad_app/`; preserve existing upstream license/notice files when introducing Compositor source. An iPad simulator build is not proof of Pencil or real-device operation.
- Work on task branches (`mac/<task>` or `windows/<task>`) for concurrent development. Inspect Git status and preserve unrelated edits. Never force-push over another device's changes.
- Do not commit pairing files, tokens, personal artwork, model weights, runtime databases, generated outputs, private certificates or local machine paths. Use placeholders in public documentation. Ignore rules alone do not prove a change is safe to publish.
- Keep input pixels, crop coordinates, straight-alpha PNG output, mask conventions, idempotency and task-recovery semantics compatible. Update API documentation with protocol changes.
- The current model preset does reference-image editing followed by an output mask, not native masked diffusion inpainting. Describe that accurately.
- For bridge behavior changes, run the relevant tests from `ipad_bridge` with its environment (`python -m pytest -q`). Use `examples/smoke_client.py` for HTTP verification when relevant; it triggers real inference on a real backend. Avoid GPU runs for prose-only changes.
- Never weaken TLS verification or expose ComfyUI publicly to solve connectivity. Local development settings and credentials remain per-device.
