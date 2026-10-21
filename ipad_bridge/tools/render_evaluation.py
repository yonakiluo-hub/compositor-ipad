"""Render a private local comparison gallery from painting evaluation suites.

Reads only suite indexes, case reports and fixture/result files. No network,
credentials or GPU calls. HTML contains local file URLs and must stay private;
the separate summary excludes file paths, artwork, prompts and job IDs.
"""
from __future__ import annotations

import argparse
import html
import json
import math
import re
import statistics
from datetime import datetime, timezone
from pathlib import Path

if __package__:
    from .evaluate_painting import completed_report
else:
    from evaluate_painting import completed_report


LABELS = {
    "paint-edit-v1": "Klein 4B · 4 步",
    "qwen21-edit-v1": "Qwen 2.1 · 25 步",
    "qwen21-turbo-edit-v1": "Qwen 2.1 Turbo · 8 步",
    "lineart_colorization": "线稿上色", "sketch_refinement": "草图细化",
    "local_repair": "局部修补", "value_lighting_design": "明度与光影",
    "still_life": "静物", "courtyard": "庭院", "portrait": "人像",
}
SAFE_ID = re.compile(r"[a-zA-Z0-9_-]{1,160}\Z")


def escape(value) -> str:
    return html.escape(str(value), quote=True)


def number(value) -> float | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value < 0:
        return None
    return float(value)


def within(root: Path, *parts: str) -> Path:
    candidate = root.joinpath(*parts).resolve()
    if not candidate.is_relative_to(root):
        raise ValueError("Evaluation files must stay inside their suite directory.")
    return candidate


def read_suite(directory: Path) -> dict:
    root = directory.resolve(strict=True)
    index = json.loads(within(root, "suite.json").read_text("utf-8"))
    preset = index.get("presetId")
    if not isinstance(preset, str) or SAFE_ID.fullmatch(preset) is None or not isinstance(index.get("cases"), list):
        raise ValueError("Invalid evaluation suite index.")
    cases = {}
    for item in index["cases"]:
        case_id = item.get("id")
        if not isinstance(case_id, str) or SAFE_ID.fullmatch(case_id) is None or case_id in cases:
            raise ValueError("Invalid or duplicate comparison identifier.")
        if type(item.get("size")) is not int or type(item.get("seed")) is not int:
            raise ValueError("Comparison size and seed must be integers.")
        folder = within(root, case_id)
        report = {}
        report_path = within(root, case_id, "report.json")
        if report_path.is_file():
            try:
                report = json.loads(report_path.read_text("utf-8"))
                if not isinstance(report, dict):
                    report = {}
            except (OSError, ValueError):
                pass  # A running writer may not have published its report yet.
        raw_state = report.get("state")
        state = raw_state if raw_state in {"succeeded", "failed", "poll_timeout"} else "pending"
        # Restrict every file read, including completed_report's known filenames.
        for name in ("metadata.json", "result.png", "composite.png", "input.png"):
            within(root, case_id, name)
        if state == "succeeded" and completed_report(folder) is None:
            state = "invalid_result"
        cases[case_id] = {"case": item, "folder": folder, "report": report, "state": state}
    return {"root": root, "presetId": preset, "cases": cases}


def summarize(suites: list[dict]) -> dict:
    result = {"formatVersion": 1, "generatedAt": datetime.now(timezone.utc).isoformat(),
              "synthetic": True, "qualityAdmission": "pending_human_review", "models": [],
              "measurementNotes": "Fresh submission times include upload, queueing, dependency verification and download. Recovery times are excluded. Sampled device memory includes other apps and may miss short peaks. These are not per-job allocation peaks."}
    for suite in suites:
        counts = {name: 0 for name in ("succeeded", "failed", "poll_timeout", "pending", "invalid_result")}
        durations, gpu, rss = [], [], []
        recovery_count = 0
        by_size = {}
        executions = {}
        for entry in suite["cases"].values():
            counts[entry["state"]] += 1
            report = entry["report"]
            if entry["state"] != "succeeded":
                continue
            size_stats = by_size.setdefault(entry["case"]["size"], {"times": [], "gpu": [], "rss": [], "completed": 0, "recovered": 0})
            size_stats["completed"] += 1
            execution = report.get("execution")
            if isinstance(execution, dict):
                safe_execution = {}
                for key in ("graphHash", "dependencyFingerprint", "sourceSha256"):
                    value = execution.get(key)
                    if isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value):
                        safe_execution[key] = value
                version = execution.get("presetVersion")
                if isinstance(version, str) and re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
                    safe_execution["presetVersion"] = version
                if safe_execution:
                    executions[json.dumps(safe_execution, sort_keys=True)] = safe_execution
            elapsed = number(report.get("elapsedSeconds"))
            is_fresh = report.get("firstSubmitStatus") == 202 and report.get("measurementKind", "fresh_submission_end_to_end") == "fresh_submission_end_to_end"
            if is_fresh and elapsed is not None:
                durations.append(elapsed)
                size_stats["times"].append(elapsed)
            elif not is_fresh:
                recovery_count += 1
                size_stats["recovered"] += 1
            resource = report.get("resourceMeasurement")
            if is_fresh and isinstance(resource, dict):
                for key, values in (("sampledPeakDeviceUsedMiB", gpu), ("sampledPeakProcessRssMiB", rss)):
                    value = number(resource.get(key))
                    if value is not None:
                        values.append(value)
                        size_stats["gpu" if key == "sampledPeakDeviceUsedMiB" else "rss"].append(value)
        def timing(values):
            return {"min": min(values), "p50": statistics.median(values), "max": max(values)} if values else None
        result["models"].append({"presetId": suite["presetId"], "counts": counts,
                                 "freshTimingSamples": len(durations), "recoveryResults": recovery_count,
                                 "freshEndToEndSeconds": timing(durations),
                                 "maxSampledDeviceUsedMiB": max(gpu) if gpu else None,
                                 "maxSampledProcessRssMiB": max(rss) if rss else None,
                                 "executionProvenance": list(executions.values()),
                                 "weightHashEvidence": "Individual weight hashes are not contained in these case reports; consult the private frozen execution snapshot before publication.",
                                 "byInputSize": [{"inputSize": size, "completed": values["completed"],
                                                  "freshTimingSamples": len(values["times"]), "recoveryResults": values["recovered"],
                                                  "freshEndToEndSeconds": timing(values["times"]),
                                                  "maxSampledDeviceUsedMiB": max(values["gpu"]) if values["gpu"] else None,
                                                  "maxSampledProcessRssMiB": max(values["rss"]) if values["rss"] else None}
                                                 for size, values in sorted(by_size.items())]})
    return result


def image_tag(path: Path, label: str) -> str:
    if not path.is_file():
        return '<div class="pending">图像尚未生成</div>'
    url = escape(path.as_uri())
    return f'<a href="{url}" target="_blank" rel="noopener"><img src="{url}" alt="{escape(label)}" loading="lazy"></a>'


def report_label(entry: dict) -> str:
    labels = {"succeeded": "接口检查通过 · 画质待评", "failed": "生成失败", "poll_timeout": "等待超时 · 需恢复查询", "pending": "待生成", "invalid_result": "结果文件或摘要不完整"}
    report, state = entry["report"], entry["state"]
    lines = [labels[state]]
    if report.get("isSimulation") is True:
        lines.append("模拟后端 · 无真实 AI 推理")
    seconds = number(report.get("elapsedSeconds"))
    if seconds is not None:
        kind = "首次提交总等待" if report.get("firstSubmitStatus") == 202 else "恢复查询等待"
        lines.append(f"{kind} {seconds:.2f} 秒")
    resource = report.get("resourceMeasurement")
    peak = number(resource.get("sampledPeakDeviceUsedMiB")) if isinstance(resource, dict) else None
    lines.append(f"设备显存采样峰值 {peak / 1024:.2f} GiB" if peak is not None else "资源未测量")
    return "<br>".join(escape(line) for line in lines)


def render(suites: list[dict], output: Path) -> dict:
    if not suites or len({suite["presetId"] for suite in suites}) != len(suites):
        raise ValueError("Choose one suite per distinct model preset.")
    case_order = list(dict.fromkeys(key for suite in suites for key in suite["cases"]))
    scenarios, sizes, seeds = set(), set(), set()
    sections = []
    for case_id in case_order:
        present = [suite["cases"][case_id] for suite in suites if case_id in suite["cases"]]
        case = present[0]["case"]
        signature = tuple(case.get(key) for key in ("scenario", "subject", "size", "seed"))
        if any(tuple(item["case"].get(key) for key in ("scenario", "subject", "size", "seed")) != signature for item in present):
            raise ValueError("Matching comparison identifiers have different case metadata.")
        scenario, subject, size, seed = signature
        scenarios.add(str(scenario)); sizes.add(size); seeds.add(seed)
        source = present[0]["folder"] / "input.png"
        expected_hashes = {item["case"].get("inputHashes", {}).get("input.png") for item in present}
        mismatch = len(expected_hashes) > 1
        cards = [f'<figure class="source"><figcaption>原始输入</figcaption>{image_tag(source, "原始输入")}<p>选区单独上传；本列不含生成结果。</p></figure>']
        for suite in suites:
            name = LABELS.get(suite["presetId"], suite["presetId"])
            entry = suite["cases"].get(case_id)
            content = image_tag(entry["folder"] / "composite.png", name) if entry and entry["state"] == "succeeded" else '<div class="pending">待生成或结果尚未验证</div>'
            label = report_label(entry) if entry else "此套样例中尚无对应任务"
            cards.append(f'<figure><figcaption>{escape(name)}</figcaption>{content}<p>{label}</p></figure>')
        title = f"{LABELS.get(str(scenario), scenario)} / {LABELS.get(str(subject), subject)} · {size}px · 种子 {seed}"
        warning = '<p class="warning">各套输入摘要不同，不能视为相同输入的模型比较。</p>' if mismatch else ""
        sections.append(f'<section data-scenario="{escape(scenario)}" data-size="{escape(size)}" data-seed="{escape(seed)}"><h2>{escape(title)}</h2>{warning}<div class="grid">{"".join(cards)}</div></section>')
    def options(values, labels=None):
        return '<option value="">全部</option>' + ''.join(f'<option value="{escape(v)}">{escape((labels or {}).get(str(v), v))}</option>' for v in sorted(values))
    summary = summarize(suites)
    overview = ''.join(f'<li><strong>{escape(LABELS.get(m["presetId"], m["presetId"]))}</strong>：完成 {m["counts"]["succeeded"]} / {sum(m["counts"].values())}，待生成 {m["counts"]["pending"]}，失败或不完整 {sum(m["counts"][k] for k in ("failed", "poll_timeout", "invalid_result"))}</li>' for m in summary["models"])
    page = '''<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>绘画模型样例对比</title><style>
:root{font-family:system-ui,"Microsoft YaHei",sans-serif;color:#e7eaf2;background:#111722;font-size:15px}body{margin:0 auto;max-width:1800px;padding:30px}h1{font-size:29px;margin:0 0 12px}h2{font-size:19px;font-weight:600;margin:0 0 16px}p{line-height:1.65;color:#aeb8ce}header{margin-bottom:28px}li{line-height:1.9}.controls{display:flex;gap:20px;flex-wrap:wrap;align-items:center;padding:16px 20px;background:#202a3c;border-radius:12px;position:sticky;top:8px;z-index:2;box-shadow:0 4px 22px #0006}select{margin-left:8px;background:#111722;color:#e7eaf2;border:1px solid #4c5970;border-radius:5px;padding:8px}section{margin-top:26px;padding:24px;background:#192130;border:1px solid #2c394e;border-radius:14px}.grid{display:grid;grid-template-columns:repeat(var(--columns),minmax(0,1fr));gap:16px}figure{margin:0;min-width:0}figcaption{font-size:15px;color:#e7eaf2;padding:0 0 10px;font-weight:600}img{width:100%;aspect-ratio:1;object-fit:contain;background:#fff;border-radius:7px;display:block}figure p{font-size:13px;margin:10px 0 0}.pending{min-height:160px;aspect-ratio:1;display:flex;align-items:center;justify-content:center;color:#8290a8;background:#111722;border:1px dashed #4c5970;border-radius:7px;padding:10px;box-sizing:border-box}.warning{color:#ffcc79}.hide-source .source{display:none}footer{margin:30px 0;color:#8d9bb3}input{accent-color:#83b6ff}@media(max-width:900px){body{padding:16px}.grid{grid-template-columns:repeat(2,minmax(0,1fr))}section{padding:16px}}@media(max-width:540px){.grid{grid-template-columns:1fr}.controls{position:static}}
</style><body>'''
    page += f'<header><h1>绘画模型样例对比</h1><p>原创合成输入 · 同主题、尺寸与种子横向比较 · 画质仍需人工确认</p><ul>{overview}</ul><p>显示的是生成结果叠回输入后的合成图。点击图片查看原尺寸；检查线条漂移、颜色边界、修补接缝和明暗分组。接口检查通过不代表绘画质量通过。</p></header>'
    page += f'<div class="controls"><label>场景<select id="scenario">{options(scenarios, LABELS)}</select></label><label>尺寸<select id="size">{options(sizes)}</select></label><label>种子<select id="seed">{options(seeds)}</select></label><label><input type="checkbox" id="source" checked> 显示原始输入</label><span id="count"></span></div>'
    page += ''.join(sections)
    page += '<footer>时间为端到端总等待，包含队列、依赖核验与传输；恢复查询的等待时间不能当成推理速度。资源是定时采样，可能漏掉短峰值，设备显存包含其他程序。此 HTML 引用私人本机文件，不应上传公开仓库。待生成项需完成后重新生成本页。</footer>'
    page += f'''<script>
const modelCount={len(suites)};
const filters=['scenario','size','seed'].map(id=>document.getElementById(id));
function update(){{let count=0;document.querySelectorAll('section').forEach(section=>{{const show=filters.every(filter=>!filter.value||section.dataset[filter.id]===filter.value);section.hidden=!show;if(show)count++;}});document.getElementById('count').textContent='显示 '+count+' 组';const show=document.getElementById('source').checked;document.body.classList.toggle('hide-source',!show);document.body.style.setProperty('--columns',modelCount+(show?1:0));}}
filters.forEach(filter=>filter.addEventListener('change',update));document.getElementById('source').addEventListener('change',update);update();
</script></body></html>'''
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(page, encoding="utf-8")
    output.with_suffix(".summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return summary


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--suite", action="append", type=Path, required=True, help="Repeat for each preset's suite directory")
    parser.add_argument("--output", type=Path, required=True, help="Private local HTML output")
    args = parser.parse_args()
    summary = render([read_suite(directory) for directory in args.suite], args.output)
    print(f"Rendered {len(summary['models'])} model columns. Human quality review remains pending.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
