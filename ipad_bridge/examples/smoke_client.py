"""Exercise the bridge HTTP contract using a small generated drawing.

Requires httpx and Pillow. A real ComfyUI bridge will run ONE GPU generation.
Reusing --output reuses the persisted request and bytes instead of generating
a new job. Credentials are read only from --pairing and never saved in reports.
"""
from __future__ import annotations

import argparse
import hashlib
import io
import json
import sys
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlsplit

import httpx
from PIL import Image, ImageChops, ImageCms, ImageDraw


def now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def read_pairing(path: Path) -> dict:
    pairing = json.loads(path.read_text(encoding="utf-8-sig"))
    if pairing.get("protocolVersion") != 1:
        raise ValueError("Pairing requires protocolVersion 1.")
    origin = pairing.get("baseUrl", "")
    parsed = urlsplit(origin)
    if (parsed.scheme not in {"http", "https"} or not parsed.hostname or parsed.username
            or parsed.password or parsed.query or parsed.fragment or parsed.path not in {"", "/"}):
        raise ValueError("Pairing baseUrl must be an HTTP(S) origin without credentials or a path.")
    token = pairing.get("accessToken")
    if not isinstance(token, str) or len(token) < 32 or not token.isascii():
        raise ValueError("Pairing accessToken is missing or invalid.")
    if pairing.get("backend") not in {"mock", "comfyui"}:
        raise ValueError("Pairing backend must be mock or comfyui.")
    return pairing


def prepared_input(output: Path, preset: str) -> tuple[dict, bytes, bytes]:
    paths = [output / name for name in ("metadata.json", "input.png", "mask.png")]
    present = [path.exists() for path in paths]
    if any(present):
        if not all(present):
            raise ValueError("This output directory has an incomplete sample; choose a fresh --output directory.")
        metadata = json.loads(paths[0].read_text("utf-8"))
        if metadata["workflowPreset"] != preset:
            raise ValueError("This directory belongs to a different backend preset; choose a fresh --output directory.")
        return metadata, paths[1].read_bytes(), paths[2].read_bytes()

    metadata = json.loads(Path(__file__).with_name("metadata.json").read_text("utf-8"))
    metadata["clientRequestId"] = str(uuid.uuid4())
    metadata["documentId"] = str(uuid.uuid4())
    metadata["workflowPreset"] = preset
    canvas = Image.new("RGBA", (512, 384), (232, 222, 203, 255))
    drawing = ImageDraw.Draw(canvas)
    drawing.rectangle((36, 45, 118, 338), fill=(87, 118, 101, 255))
    drawing.ellipse((385, 72, 474, 161), fill=(214, 168, 71, 255))
    drawing.rectangle((145, 112, 360, 300), fill=(167, 79, 61, 255))
    drawing.line((161, 124, 191, 286), fill=(196, 108, 87, 255), width=7)
    drawing.line((224, 121, 255, 286), fill=(132, 57, 47, 255), width=8)
    drawing.line((300, 121, 325, 286), fill=(192, 103, 81, 255), width=5)
    coverage = Image.new("L", canvas.size, 0)
    mask_draw = ImageDraw.Draw(coverage)
    mask_draw.rectangle((145, 112, 360, 300), fill=128)
    mask_draw.rectangle((153, 120, 352, 292), fill=255)
    srgb = ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes()
    canvas.save(paths[1], format="PNG", icc_profile=srgb)
    coverage.save(paths[2], format="PNG")
    paths[0].write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return metadata, paths[1].read_bytes(), paths[2].read_bytes()


def checked_response(response: httpx.Response, allowed=(200,)) -> httpx.Response:
    if response.status_code not in allowed:
        try:
            error = response.json().get("error", {})
            code, message = error.get("code", "request_failed"), error.get("message", "")
        except (ValueError, AttributeError):
            code, message = "request_failed", "No structured error returned."
        raise RuntimeError(f"HTTP {response.status_code}: {code}: {message}")
    return response


def submit(client: httpx.Client, metadata: dict, image: bytes, mask: bytes) -> tuple[dict, int]:
    request = client.build_request("POST", "/v1/jobs", data={
        "metadata": json.dumps(metadata, ensure_ascii=False, separators=(",", ":")),
    }, files={"image": ("input.png", image, "image/png"), "mask": ("mask.png", mask, "image/png")})
    # Byte-backed multipart bodies have a known length. Never use chunked input.
    if "transfer-encoding" in request.headers or not request.headers.get("content-length", "").isdigit():
        raise RuntimeError("The client could not construct a fixed-length multipart request.")
    response = checked_response(client.send(request), (200, 202))
    return response.json(), response.status_code


def verify_result(output: Path, content: bytes, descriptor: dict, source: dict, metadata: dict, mask: bytes) -> dict:
    expected_source = {key: metadata[key] for key in ("documentId", "baseRevision", "sourceLayerIds", "canvasSize", "cropRect", "inputSize", "colorSpace")}
    if source != expected_source or descriptor.get("cropRect") != metadata["cropRect"]:
        raise RuntimeError("Returned source or crop coordinates differ from the submitted snapshot.")
    if descriptor.get("alphaMode") != "straight" or descriptor.get("maskApplied") is not True:
        raise RuntimeError("The result does not declare straight alpha with its mask already applied.")
    digest = hashlib.sha256(content).hexdigest()
    if descriptor.get("sha256") != digest or descriptor.get("bytes") != len(content):
        raise RuntimeError("The downloaded result length or SHA-256 does not match its descriptor.")
    with Image.open(io.BytesIO(content)) as decoded:
        decoded.load()
        if decoded.format != "PNG" or decoded.mode != "RGBA":
            raise RuntimeError("Expected a PNG with RGBA channels.")
        result = decoded.copy()
    expected_size = (metadata["cropRect"]["width"], metadata["cropRect"]["height"])
    if result.size != expected_size or (descriptor.get("width"), descriptor.get("height")) != expected_size:
        raise RuntimeError("Returned image dimensions differ from the crop dimensions.")
    with Image.open(io.BytesIO(mask)) as decoded:
        coverage = decoded.copy()
    alpha = result.getchannel("A")
    black = coverage.point(lambda value: 255 if value == 0 else 0)
    if ImageChops.multiply(alpha, black).getbbox() is not None:
        raise RuntimeError("A black mask pixel has nonzero result alpha.")
    if ImageChops.subtract(alpha, coverage).getbbox() is not None:
        raise RuntimeError("Result alpha exceeds its allowed mask coverage.")
    (output / "result.png").write_bytes(content)
    with Image.open(output / "input.png") as decoded:
        original = decoded.convert("RGBA")
    composed = Image.alpha_composite(original, result)
    changed = ImageChops.difference(original.convert("RGB"), composed.convert("RGB"))
    if ImageChops.multiply(changed, black.convert("RGB")).getbbox() is not None:
        raise RuntimeError("Compositing changed a pixel outside the mask.")
    composed.save(output / "composite.png", icc_profile=ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes())
    histogram = coverage.histogram()
    return {
        "sha256": digest, "width": result.width, "height": result.height,
        "sourceAndCropMatch": True, "maskZeroAlphaZero": True,
        "alphaWithinMask": True, "compositeOutsideMaskUnchanged": True,
        "blackMaskPixels": histogram[0], "grayMaskPixels": sum(histogram[1:255]),
        "maskApplied": True, "alphaMode": "straight",
    }


def run(pairing: dict, output: Path, timeout: float, report: dict) -> None:
    start = time.monotonic()
    with httpx.Client(base_url=pairing["baseUrl"].rstrip("/"),
                      headers={"Authorization": "Bearer " + pairing["accessToken"]},
                      timeout=httpx.Timeout(30, connect=10), trust_env=False, follow_redirects=False) as client:
        capabilities = checked_response(client.get("/v1/capabilities")).json()
        if capabilities.get("protocolVersion") != 1:
            raise RuntimeError("The bridge does not advertise protocol version 1.")
        backend = capabilities.get("backend")
        if backend != pairing["backend"]:
            raise RuntimeError("Pairing backend differs from the active service; refresh the pairing file.")
        preset_id = {"mock": "mock-paint-v1", "comfyui": "paint-edit-v1"}.get(backend)
        if not any(p.get("id") == preset_id for p in capabilities.get("presets", [])):
            raise RuntimeError("The expected preset is not advertised by this bridge.")
        report.update(backend=backend, isSimulation=capabilities.get("isSimulation"), presetId=preset_id)
        print("Backend:", backend, "(SIMULATION / NO AI)" if capabilities.get("isSimulation") else "(real ComfyUI)")
        readiness = checked_response(client.get("/v1/backend/status")).json()
        report["backendStatus"] = readiness
        if not readiness.get("ok"):
            raise RuntimeError("The backend preflight is not ready; inspect report.json backendStatus.")
        metadata, image, mask = prepared_input(output, preset_id)
        report.update(clientRequestId=metadata["clientRequestId"], documentId=metadata["documentId"])
        job, first_code = submit(client, metadata, image, mask)
        report.update(jobId=job["jobId"], firstSubmitStatus=first_code)
        repeated, second_code = submit(client, metadata, image, mask)
        if repeated.get("jobId") != job["jobId"] or second_code != 200:
            raise RuntimeError("Retrying the identical request did not return the same job.")
        report.update(idempotencyPassed=True, retrySubmitStatus=second_code)
        listing = checked_response(client.get("/v1/jobs", params={"documentId": metadata["documentId"], "limit": 100})).json()
        if sum(entry.get("jobId") == job["jobId"] for entry in listing.get("jobs", [])) != 1:
            raise RuntimeError("The document job list does not contain exactly one matching job.")
        report["jobListPassed"] = True
        previous_state = None
        while True:
            job = checked_response(client.get(f"/v1/jobs/{job['jobId']}")).json()
            if job["state"] != previous_state:
                print("Job:", job["jobId"], job["state"])
                previous_state = job["state"]
            report["state"] = job["state"]
            if job["state"] == "failed":
                report["jobError"] = job.get("error")
                raise RuntimeError("Generation failed; inspect report.json jobError.")
            if job["state"] == "succeeded":
                break
            if job["state"] not in {"queued", "running"}:
                raise RuntimeError("The bridge returned an unknown job state.")
            if time.monotonic() - start >= timeout:
                raise TimeoutError("Polling timeout. The server job continues; rerun with the same --output to recover it.")
            time.sleep(min(1.0, max(0.0, timeout - (time.monotonic() - start))))
        if not job.get("results"):
            raise RuntimeError("The completed job has no result descriptor.")
        descriptor = job["results"][0]
        expected_url = f"/v1/jobs/{job['jobId']}/results/{descriptor['resultId']}"
        if descriptor.get("url") != expected_url:
            raise RuntimeError("The result URL is outside the expected job endpoint.")
        downloaded = checked_response(client.get(expected_url))
        report["verification"] = verify_result(output, downloaded.content, descriptor, job["source"], metadata, mask)
        if downloaded.headers.get("x-content-sha256") != report["verification"]["sha256"]:
            raise RuntimeError("The result SHA-256 response header does not match its contents.")
        report.update(ok=True, elapsedSeconds=round(time.monotonic() - start, 2))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pairing", type=Path, required=True, help="Private pairing.json file")
    parser.add_argument("--output", type=Path, default=Path("smoke-output"), help="Sample, result and report directory; reuse it to resume")
    parser.add_argument("--timeout", type=float, default=900.0, help="Maximum polling wait in seconds")
    args = parser.parse_args()
    if args.timeout <= 0:
        parser.error("--timeout must be positive")
    args.output.mkdir(parents=True, exist_ok=True)
    report = {"startedAt": now(), "ok": False, "protocolVersion": 1}
    token = ""
    try:
        pairing = read_pairing(args.pairing)
        token = pairing["accessToken"]
        run(pairing, args.output, args.timeout, report)
    except (ValueError, OSError, RuntimeError, KeyError, httpx.HTTPError) as error:
        # Never include request headers or dump the pairing object on failure.
        message = str(error).replace(token, "[redacted]") if token else str(error)
        report["error"] = {"type": type(error).__name__, "message": message}
        print(message, file=sys.stderr)
    finally:
        report["finishedAt"] = now()
        serialized = json.dumps(report, ensure_ascii=False, indent=2)
        if token:
            serialized = serialized.replace(token, "[redacted]")
        (args.output / "report.json").write_text(serialized + "\n", encoding="utf-8")
    print("Report:", args.output / "report.json")
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
