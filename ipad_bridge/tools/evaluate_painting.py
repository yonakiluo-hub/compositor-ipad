"""Create a reproducible painting evaluation suite; GPU runs require --run.

Only synthetic fixtures are generated. Outputs stay in --output, never in Git.
This checks transport/geometry/alpha and prepares human comparisons; it does not
score artistic quality or imply that a preset is admitted for production.
"""
from __future__ import annotations

import argparse
import hashlib
import io
import json
import sys
import time
import uuid
from pathlib import Path

import httpx
from PIL import Image, ImageDraw

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from examples.smoke_client import checked_response, now, read_pairing, submit, verify_result
from tools.resource_sampler import ResourceSampler


SCENARIOS = {
    "lineart_colorization": "Color this line drawing with restrained warm and cool flat colors. Preserve every silhouette, line position and the composition.",
    "sketch_refinement": "Refine this rough sketch into clean controlled line work. Preserve the composition, object positions, proportions and perspective.",
    "local_repair": "Replace the bright magenta damage on the central object with continuous surface detail matching the surrounding image. Preserve composition and outlines.",
    "value_lighting_design": "Develop this grayscale block-in into an artistic four-value study with a clear upper-left light source. Preserve composition and silhouettes; make light and shadow groups readable.",
}
SUBJECTS = ("still_life", "courtyard", "portrait")
SEEDS = (20261021, 424242)


def fixture(scenario: str, subject: str, size: int) -> tuple[bytes, bytes]:
    """Original vector-like fixtures, including a feathered 0/128/255 edit mask."""
    if scenario not in SCENARIOS or subject not in SUBJECTS or size not in (768, 1024):
        raise ValueError("Unknown fixture or unsupported size.")
    line_mode = scenario in {"lineart_colorization", "sketch_refinement"}
    image = Image.new("RGBA", (size, size), (248, 248, 244, 255) if line_mode else (180, 180, 180, 255))
    draw = ImageDraw.Draw(image)
    scale = size / 1024
    def box(coords):
        return tuple(round(x * scale) for x in coords)
    width = max(2, round(4 * scale))
    fill = (248, 248, 244, 255) if line_mode else (145, 145, 145, 255)
    ink = (45, 45, 45, 255)
    if subject == "still_life":
        draw.line(box((70, 780, 950, 780)), fill=ink, width=width)
        draw.ellipse(box((135, 430, 445, 740)), fill=fill, outline=ink, width=width)
        draw.rectangle(box((490, 300, 775, 740)), fill=fill, outline=ink, width=width)
        draw.ellipse(box((490, 250, 775, 350)), fill=fill, outline=ink, width=width)
        draw.arc(box((725, 375, 875, 620)), -90, 90, fill=ink, width=width)
    elif subject == "courtyard":
        draw.polygon([box(p) for p in ((90, 730), (460, 540), (940, 755), (930, 925), (100, 925))], fill=fill, outline=ink, width=width)
        draw.rectangle(box((210, 280, 740, 740)), fill=fill, outline=ink, width=width)
        draw.polygon([box(p) for p in ((180, 280), (485, 105), (780, 280))], fill=fill, outline=ink, width=width)
        draw.rectangle(box((405, 480, 555, 740)), fill=(245, 245, 240, 255) if line_mode else (80, 80, 80, 255), outline=ink, width=width)
        for x in (275, 605):
            draw.rectangle(box((x, 360, x + 70, 455)), fill=fill, outline=ink, width=width)
    else:
        draw.ellipse(box((330, 160, 690, 640)), fill=fill, outline=ink, width=width)
        draw.polygon([box(p) for p in ((430, 600), (430, 720), (210, 820), (150, 960), (875, 960), (810, 820), (590, 720), (590, 600))], fill=fill, outline=ink, width=width)
        draw.arc(box((375, 340, 460, 390)), 180, 355, fill=ink, width=width)
        draw.arc(box((555, 340, 640, 390)), 180, 355, fill=ink, width=width)
        draw.line(box((510, 375, 490, 470, 530, 470)), fill=ink, width=width)
        draw.arc(box((435, 485, 585, 550)), 0, 180, fill=ink, width=width)
    if scenario == "sketch_refinement":
        for offset in (-9, 6):
            draw.line(box((190 + offset, 815, 505 + offset, 115, 785 + offset, 810)), fill=(150, 150, 150, 255), width=max(1, width // 2))
    mask = Image.new("L", image.size, 255)
    if scenario == "local_repair":
        draw.rectangle(box((445, 430, 575, 570)), fill=(255, 0, 255, 255))
        mask = Image.new("L", image.size, 0)
        coverage = ImageDraw.Draw(mask)
        coverage.rectangle(box((390, 375, 630, 625)), fill=128)
        coverage.rectangle(box((415, 400, 605, 600)), fill=255)
    encoded = []
    for value in (image, mask):
        stream = io.BytesIO()
        value.save(stream, format="PNG")
        encoded.append(stream.getvalue())
    return tuple(encoded)


def prepare_suite(output: Path, preset: str, sizes=(768, 1024), seeds=SEEDS) -> dict:
    if not preset or any(c not in "abcdefghijklmnopqrstuvwxyz0123456789-" for c in preset):
        raise ValueError("Invalid preset identifier.")
    if any(s not in (768, 1024) for s in sizes) or len(set(sizes)) != len(sizes):
        raise ValueError("Sizes must be unique 768 and/or 1024.")
    if any(type(s) is not int or not 0 <= s <= 2**63 - 1 for s in seeds) or len(set(seeds)) != len(seeds):
        raise ValueError("Seeds must be unique unsigned 63-bit integers.")
    output.mkdir(parents=True, exist_ok=True)
    index_path = output / "suite.json"
    if index_path.exists():
        suite = json.loads(index_path.read_text("utf-8"))
        if (suite.get("presetId"), suite.get("sizes"), suite.get("seeds")) != (preset, list(sizes), list(seeds)):
            raise ValueError("This output directory has a different evaluation configuration.")
        for case in suite["cases"]:
            folder = output / case["id"]
            for filename, digest in case["inputHashes"].items():
                if hashlib.sha256((folder / filename).read_bytes()).hexdigest() != digest:
                    raise ValueError("A persisted evaluation input was changed; do not silently replace request bytes.")
        return suite
    if any(output.iterdir()):
        raise ValueError("Use an empty output directory or an intact existing suite.")
    suite_id = uuid.uuid4()
    suite = {"formatVersion": 1, "suiteId": str(suite_id), "createdAt": now(), "presetId": preset,
             "sizes": list(sizes), "seeds": list(seeds), "synthetic": True,
             "qualityAdmission": "pending_human_review", "cases": []}
    for scenario in SCENARIOS:
        for subject in SUBJECTS:
            for size in sizes:
                image, mask = fixture(scenario, subject, size)
                for seed in seeds:
                    case_id = f"{scenario}-{subject}-{size}-{seed}"
                    folder = output / case_id
                    folder.mkdir()
                    prompt = SCENARIOS[scenario]
                    if scenario == "value_lighting_design" and subject == "still_life":
                        prompt = prompt.replace("four-value", "two-value")
                    metadata = {
                        "protocolVersion": 1, "clientRequestId": str(uuid.uuid5(suite_id, case_id)),
                        "documentId": str(suite_id), "baseRevision": 1, "sourceLayerIds": ["synthetic-source"],
                        "canvasSize": {"width": size + 128, "height": size + 128},
                        "cropRect": {"x": 64, "y": 64, "width": size, "height": size},
                        "inputSize": {"width": size, "height": size}, "colorSpace": "sRGB",
                        "maskConvention": "white_edit_black_preserve", "workflowPreset": preset,
                        "prompt": prompt, "seed": seed,
                    }
                    files = {"input.png": image, "mask.png": mask,
                             "metadata.json": (json.dumps(metadata, indent=2) + "\n").encode()}
                    for name, content in files.items():
                        (folder / name).write_bytes(content)
                    suite["cases"].append({"id": case_id, "scenario": scenario, "subject": subject,
                                           "size": size, "seed": seed,
                                           "inputHashes": {name: hashlib.sha256(content).hexdigest() for name, content in files.items()}})
    index_path.write_text(json.dumps(suite, indent=2) + "\n", encoding="utf-8")
    return suite


def run_case(client: httpx.Client, folder: Path, timeout: float) -> dict:
    metadata = json.loads((folder / "metadata.json").read_text("utf-8"))
    image, mask = (folder / "input.png").read_bytes(), (folder / "mask.png").read_bytes()
    start = time.monotonic()
    job, status = submit(client, metadata, image, mask)
    report = {"startedAt": now(), "jobId": job["jobId"], "firstSubmitStatus": status,
              "presetId": metadata["workflowPreset"], "seed": metadata["seed"],
              "measurementKind": "fresh_submission_end_to_end" if status == 202 else "recovery_wait",
              "qualityAdmission": "pending_human_review", "resourceMeasurement": "not_collected"}
    while job["state"] in {"queued", "running"}:
        if time.monotonic() - start >= timeout:
            report.update(state="poll_timeout", elapsedSeconds=round(time.monotonic() - start, 3))
            return report
        time.sleep(min(1, timeout))
        job = checked_response(client.get(f"/v1/jobs/{job['jobId']}")).json()
    report.update(state=job["state"], elapsedSeconds=round(time.monotonic() - start, 3), execution=job.get("execution"))
    if job["state"] == "failed":
        report["error"] = job.get("error")
        return report
    if job["state"] != "succeeded" or len(job.get("results", [])) != 1:
        raise RuntimeError("Unexpected terminal job response.")
    descriptor = job["results"][0]
    expected_url = f"/v1/jobs/{job['jobId']}/results/0"
    if descriptor.get("url") != expected_url:
        raise RuntimeError("Unexpected result URL.")
    content = checked_response(client.get(expected_url)).content
    report["verification"] = verify_result(folder, content, descriptor, job["source"], metadata, mask)
    return report


def completed_report(folder: Path) -> dict | None:
    """Keep a completed run's original timing/resource evidence during resume."""
    try:
        report = json.loads((folder / "report.json").read_text("utf-8"))
        metadata = json.loads((folder / "metadata.json").read_text("utf-8"))
        verification = report.get("verification", {})
        digest = verification.get("sha256")
        if (report.get("state") != "succeeded" or report.get("presetId") != metadata["workflowPreset"]
                or report.get("seed") != metadata["seed"] or not isinstance(digest, str)
                or len(digest) != 64 or hashlib.sha256((folder / "result.png").read_bytes()).hexdigest() != digest):
            return None
        if any(verification.get(key) is not True for key in (
            "sourceAndCropMatch", "maskZeroAlphaZero", "alphaWithinMask", "compositeOutsideMaskUnchanged", "maskApplied",
        )) or verification.get("alphaMode") != "straight":
            return None
        if (verification.get("width"), verification.get("height")) != (
            metadata["cropRect"]["width"], metadata["cropRect"]["height"],
        ):
            return None
        return report
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        return None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--preset", default="paint-edit-v1")
    parser.add_argument("--sizes", type=int, nargs="+", default=[768, 1024], choices=[768, 1024])
    parser.add_argument("--seeds", type=int, nargs="+", default=list(SEEDS))
    parser.add_argument("--run", action="store_true", help="Submit real jobs sequentially; otherwise create fixtures only")
    parser.add_argument("--pairing", type=Path)
    parser.add_argument("--limit", type=int, help="Run only the first N fixtures; resume uses identical persisted requests")
    parser.add_argument("--timeout", type=float, default=900)
    parser.add_argument("--comfy-pid", type=int, help="Optional verified ComfyUI PID for sampled process RAM measurement")
    args = parser.parse_args()
    if args.timeout <= 0 or (args.limit is not None and args.limit <= 0):
        parser.error("Timeout and limit must be positive.")
    if args.run and not args.pairing:
        parser.error("--run requires --pairing.")
    suite = prepare_suite(args.output, args.preset, tuple(args.sizes), tuple(args.seeds))
    print(f"Prepared {len(suite['cases'])} synthetic comparisons. Artistic acceptance remains pending.")
    if not args.run:
        return 0
    pairing = read_pairing(args.pairing)
    with httpx.Client(base_url=pairing["baseUrl"].rstrip("/"), headers={"Authorization": "Bearer " + pairing["accessToken"]},
                      timeout=60, trust_env=False, follow_redirects=False) as client:
        capabilities = checked_response(client.get("/v1/capabilities")).json()
        if capabilities.get("backend") != pairing["backend"]:
            raise ValueError("Pairing backend does not match the service.")
        if not any(p.get("id") == args.preset and p.get("enabled", True) for p in capabilities.get("presets", [])):
            raise ValueError("Requested preset is not enabled by this service.")
        for case in suite["cases"][:args.limit]:
            folder = args.output / case["id"]
            if completed_report(folder) is not None:
                print(case["id"], "already verified; original measurement retained")
                continue
            with ResourceSampler(pid=args.comfy_pid) as resources:
                report = run_case(client, folder, args.timeout)
            report["resourceMeasurement"] = resources.report()
            report["isSimulation"] = capabilities.get("isSimulation", False)
            (folder / "report.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
            print(case["id"], report["state"])
            if report["state"] != "succeeded":
                # Never submit the next case after an unconfirmed GPU release.
                return 1
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except httpx.HTTPError:
        print("HTTP transport failed. Resume the same output directory; do not create a replacement request.", file=sys.stderr)
        raise SystemExit(1)
