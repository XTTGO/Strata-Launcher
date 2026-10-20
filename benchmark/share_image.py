from __future__ import annotations

import html
from typing import Any


def _fmt(value: Any, digits: int = 2) -> str:
    if value is None:
        return "—"
    return f"{value:.{digits}f}" if isinstance(value, float) else str(value)


def _summary_value(stats: dict[str, Any] | None, key: str) -> Any:
    return (stats or {}).get(key)


def render_share_svg(summary: dict[str, Any]) -> str:
    """Build a self-contained, screenshot-ready SVG using only measured report values."""
    manifest = summary.get("manifest") or {}
    request = manifest.get("request") or {}
    hardware = summary.get("hardware") or {}
    models = summary.get("models") or {}
    selected = request.get("stages")
    if isinstance(selected, list):
        selected = set(selected)
    else:
        selected = {stage for model in models.values() for stage in (model.get("stage_coverage") or {})
                    if stage not in {"startup", "warmup"}} or {
            stage for model in models.values()
            for stage in ("performance", "cache", "agent", "needle", "capacity", "load", "stability")
            if model.get(stage)
        }
    state = (summary.get("completion") or {}).get("state") or manifest.get("state") or "unknown"
    states = {"completed": "已完成", "partial": "部分完成", "failed": "失败", "cancelled": "已取消", "running": "运行中"}
    state_label = states.get(str(state), str(state))
    specs = {
        str(spec.get("model_id")): spec
        for spec in request.get("models", [])
        if isinstance(spec, dict) and spec.get("model_id")
    }
    case_labels = [str(case[0]) for case in request.get("performance_cases") or [] if isinstance(case, (list, tuple)) and case]
    if not case_labels:
        case_labels = sorted({key.removeprefix("performance-") for model in models.values() for key in (model.get("performance") or {})})
    load_count = sum(len(model.get("load") or []) for model in models.values())
    model_count = len(models)
    capacity_models = [(model_id, model) for model_id, model in models.items()
                       if "capacity" in selected and isinstance(model.get("context_tier"), int)]

    height = 1340 + max(0, model_count - 2) * 120 + max(0, load_count - 8) * 42
    if capacity_models:
        height += 130 + len(capacity_models) * 42
    max_decode = max(
        (
            (case.get("decode_tps") or {}).get("median") or 0
            for model in models.values()
            for case in (model.get("performance") or {}).values()
            if isinstance(case, dict)
        ),
        default=0,
    )
    pieces = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="1600" height="{height}" viewBox="0 0 1600 {height}" role="img" aria-label="Strata Benchmark 分享图">',
        f'<rect width="1600" height="{height}" fill="#eef2f7"/>',
    ]

    def text(
        x: int,
        y: int,
        value: Any,
        size: int = 16,
        weight: int = 400,
        color: str = "#172033",
        clip_id: str | None = None,
    ) -> None:
        safe = html.escape(str(value if value is not None else "—"), quote=True)
        clip = f' clip-path="url(#{clip_id})"' if clip_id else ""
        pieces.append(f'<text x="{x}" y="{y}" font-family="Segoe UI, Microsoft YaHei, sans-serif" font-size="{size}" font-weight="{weight}" fill="{color}"{clip}>{safe}</text>')

    def rect(
        x: int,
        y: int,
        width: int,
        height: int,
        fill: str = "#ffffff",
        *,
        radius: int = 12,
        stroke: str = "#d9e0ea",
    ) -> None:
        pieces.append(f'<rect x="{x}" y="{y}" width="{width}" height="{height}" rx="{radius}" fill="{fill}" stroke="{stroke}"/>')

    def rule(x1: int, y1: int, x2: int, y2: int, color: str = "#e7ebf1") -> None:
        pieces.append(f'<path d="M{x1} {y1}H{x2}" stroke="{color}" stroke-width="1"/>')

    def section(y: int, title: str, subtitle: str = "") -> None:
        text(54, y, title, 18, 650)
        if subtitle:
            text(1050, y, subtitle, 12, 400, "#596579")

    run_date = str(manifest.get("created_at") or summary.get("generated_at") or "未记录").replace("T", " ").replace("+00:00", " UTC")
    text(54, 78, "Strata Benchmark · 硬件分享概览", 26, 700)
    text(54, 104, f"{run_date} · {summary.get('record_count', 0)} 条记录 · {state_label}", 14, 500, "#596579")

    # Test conditions, in two compact rows.
    rect(48, 122, 1504, 84)
    contexts = " / ".join(case_labels) or "未记录"
    load_contexts = " / ".join(str(label) for label in request.get("load_input_lengths") or []) or "未记录"
    caps = sorted({int(model["effective_max_context"]) // 1024 for model in models.values() if model.get("effective_max_context")})
    model_context = " / ".join(f"{value}K" for value in caps) or request.get("model_max_context") or "未记录"
    metadata = [
        ("预设", request.get("preset_label") or request.get("preset", "未记录")),
        ("性能轮数", request.get("rounds", "—") if "performance" in selected else "未选择"),
        ("性能输入", contexts if "performance" in selected else "未选择"),
        ("模型上下文", model_context),
        ("并发输入", load_contexts if "load" in selected else "未选择"),
        ("并发档位", " / ".join(str(x) for x in request.get("load_clients") or []) if "load" in selected else "未选择"),
        ("并发负载", f"每档 {request.get('load_rounds', 3)} 轮 · {request.get('load_max_tokens', 256)} tokens" if "load" in selected else "未选择"),
        ("Strata", f"v{hardware.get('strata_engine_version')}" if hardware.get("strata_engine_version") else "版本未记录"),
        ("模型数", model_count),
    ]
    for index, (label, value) in enumerate(metadata):
        row, col = divmod(index, 4)
        text(66 + col * 372, 153 + row * 34, f"{label}  {value}", 14, 550)

    # Compact machine configuration.
    rect(48, 218, 1504, 78)
    gpus = hardware.get("gpus") or []
    gpu_label = " / ".join(f"{gpu.get('name', 'GPU')} · {_fmt((gpu.get('memory_total_mib') or 0) / 1024, 0)} GiB" for gpu in gpus) or "GPU 未获取"
    cpu = hardware.get("cpu_model") or hardware.get("cpu") or "CPU 未获取"
    if str(cpu).startswith("AMD64 Family "):
        cpu = "AMD64（具体型号未采集）"
    cores = f"{hardware.get('physical_cpu_count', '—')}C/{hardware.get('logical_cpu_count', '—')}T"
    text(68, 250, f"GPU  {gpu_label}", 14, 600)
    text(620, 250, f"CPU  {cpu} · {cores}", 14, 600)
    text(1210, 250, f"RAM  {_fmt((hardware.get('installed_ram_bytes') or 0) / (1024**3))} GiB", 14, 600)
    text(68, 279, f"系统  {hardware.get('platform') or '未获取'}", 12, 450, "#596579")
    driver = ", ".join(str(gpu.get("driver_version")) for gpu in gpus if gpu.get("driver_version")) or "未获取"
    text(620, 279, f"驱动  {driver}", 12, 450, "#596579")
    power_limits = hardware.get("gpu_power_limits") or []
    if power_limits:
        cap_label = " / ".join(f"{_fmt(item['watts'], 0)} W" for item in power_limits)
        text(1210, 279, f"功率上限  {cap_label}", 12, 450, "#596579")

    y = 330
    if "performance" in selected:
        # Context performance table.
        section(y, "输入上下文与生成速度", "Decode 中位数 · 范围为重复测试 min–max")
        context_card_height = 111 + max(0, model_count - 1) * 68
        rect(48, y + 14, 1504, context_card_height)
        text(66, y + 42, "模型 / 配置", 12, 600, "#596579")
        rule(64, y + 54, 1536, y + 54)
        col_start = 400
        cell_width = min(290, (1536 - col_start) // max(1, len(case_labels)))
        for index, label in enumerate(case_labels):
            text(col_start + index * cell_width, y + 42, label.upper(), 12, 600, "#596579")
        for model_index, (model_id, model) in enumerate(models.items()):
            row_y = y + 94 + model_index * 68
            if model_index:
                rule(64, row_y - 40, 1536, row_y - 40)
            config_hash = str(model.get("config_hash") or specs.get(model_id, {}).get("config_hash") or "未记录")[:8]
            label_clip_id = f"performance-model-label-{model_index}"
            pieces.append(
                f'<defs><clipPath id="{label_clip_id}" clipPathUnits="userSpaceOnUse">'
                f'<rect x="66" y="{row_y - 29}" width="318" height="18"/></clipPath></defs>'
            )
            text(66, row_y - 17, model.get("model_name") or model_id, 13, 600, clip_id=label_clip_id)
            text(66, row_y + 7, f"配置 {config_hash}", 10, 450, "#596579")
            for index, label in enumerate(case_labels):
                case = (model.get("performance") or {}).get(f"performance-{label}") or (model.get("performance") or {}).get(label) or {}
                decode = case.get("decode_tps") or {}
                spread = f"{_fmt(decode.get('min'))}–{_fmt(decode.get('max'))}" if decode.get("min") is not None and decode.get("max") is not None else "范围未记录"
                x = col_start + index * cell_width
                text(x, row_y - 19, f"{_fmt(decode.get('median'))} tok/s", 18, 700, "#087e78")
                text(x, row_y - 1, f"范围 {spread} tok/s", 11, 550, "#596579")
                text(x, row_y + 14, f"Prompt {_fmt(_summary_value(case.get('prompt_tps'), 'median'))} · 引擎预填充 {_fmt(_summary_value(case.get('prefill_seconds') or case.get('ttft_seconds'), 'median'))}s · n={decode.get('n', 0)}", 10, 400, "#596579")
                track_y = row_y + 22
                track_width = max(80, cell_width - 22)
                pieces.append(f'<rect x="{x}" y="{track_y}" width="{track_width}" height="4" rx="2" fill="#e8edf5" stroke="none"/>')
                bar_width = track_width * min(1.0, max(0.0, (decode.get("median") or 0) / max_decode)) if max_decode else 0
                pieces.append(f'<rect x="{x}" y="{track_y}" width="{bar_width:.1f}" height="4" rx="2" fill="#245fc7" stroke="none"/>')
        y += 155 + max(0, model_count - 1) * 68

    if "load" in selected:
        # Concurrency table: individual-request speed is the lead metric.
        section(y, "并发时单独一条请求的速度", "主指标：首 token 后单请求解码 tok/s · 总吞吐为辅助")
        concurrency_card_height = 100 + max(1, load_count) * 42
        rect(48, y + 14, 1504, concurrency_card_height)
        for x, label in [(66, "模型"), (380, "输入 / 并发"), (470, "单请求 tok/s"), (660, "总吞吐 tok/s"), (850, "TTFT P50/P95"), (1060, "完成延迟 P50/P95"), (1360, "错误")]:
            text(x, y + 40, label, 11, 600, "#596579")
        rule(64, y + 54, 1536, y + 54)
        line = 0
        for model_id, model in models.items():
            for row in sorted(model.get("load") or [], key=lambda item: (str(item.get("input_length") or ""), item.get("clients") or 0)):
                row_y = y + 83 + line * 42
                if line:
                    rule(64, row_y - 22, 1536, row_y - 22)
                label_clip_id = f"load-model-label-{line}"
                pieces.append(
                    f'<defs><clipPath id="{label_clip_id}" clipPathUnits="userSpaceOnUse">'
                    f'<rect x="66" y="{row_y - 15}" width="294" height="16"/></clipPath></defs>'
                )
                text(66, row_y - 3, model.get("model_name") or model_id, 12, 550, clip_id=label_clip_id)
                text(380, row_y - 3, f"{str(row.get('input_length') or '短').upper()} / {row.get('clients', '—')}", 13, 550)
                text(470, row_y - 3, _fmt(row.get("per_req_tps")), 18, 700, "#087e78")
                text(660, row_y - 3, _fmt(row.get("total_tps")), 14, 550)
                text(850, row_y - 3, f"{_fmt(row.get('first_p50'))} / {_fmt(row.get('first_p95'))}s", 12, 500)
                text(1060, row_y - 3, f"{_fmt(row.get('lat_p50'))} / {_fmt(row.get('lat_p95'))}s", 12, 500)
                text(1360, row_y - 3, row.get("errors", "—"), 13, 550)
                line += 1
        if line == 0:
            text(66, y + 83, "本次未执行并发测试", 14, 500, "#596579")
            line = 1
        text(66, y + 83 + line * 42 + 4, "单请求解码速度不含首 token 等待；端到端单请求 tok/s 未采集。TTFT / 完成延迟包含等待。", 11, 400, "#596579")
        y += 14 + 40 + 29 + line * 42 + 42 + 22

    foot_y = y + 20
    if selected & {"cache", "agent", "needle", "load", "stability"}:
        # Memory and capability summary for the stages included in this run.
        memory_stage = next((stage for stage in ("load", "needle", "cache", "stability", "agent")
                             if stage in selected), None)
        memory_labels = {"load": "并发", "needle": "长上下文召回", "cache": "缓存", "stability": "稳定性", "agent": "Agent"}
        memory_label = memory_labels.get(memory_stage, "未选择")
        capability_columns = [(stage, label) for stage, label in (
            ("cache", "缓存复用"), ("agent", "Agent 题集"), ("needle", "Needle"), ("stability", "稳定性"))
            if stage in selected]
        section(y, "内存与能力快速对比", f"{memory_label}阶段内存峰值 · 已选能力项目")
        memory_card_height = 126 + model_count * 48
        rect(48, y + 14, 1504, memory_card_height)
        for x, label in [(66, "模型"), (400, "整机 RAM"), (570, "Strata RSS"), (740, "VRAM")]:
            text(x, y + 40, label, 11, 600, "#596579")
        for index, (_, label) in enumerate(capability_columns):
            text(920 + index * 155, y + 40, label, 11, 600, "#596579")
        rule(64, y + 54, 1536, y + 54)
        for model_index, (model_id, model) in enumerate(models.items()):
            row_y = y + 84 + model_index * 48
            if model_index:
                rule(64, row_y - 24, 1536, row_y - 24)
            memory = model.get("memory_by_stage") or {}
            stage_memory = memory.get(memory_stage) or {}
            cache = model.get("cache") or {}
            agent = model.get("agent") or {}
            needle = model.get("needle") or {}
            stability = model.get("stage_coverage", {}).get("stability") or {}
            stable = f"{stability.get('successes', 0)}/{stability.get('expected') or stability.get('records', 0)}" if stability.get("state") == "completed" else states.get(str(stability.get("state")), "未选择")
            label_clip_id = f"summary-model-label-{model_index}"
            pieces.append(
                f'<defs><clipPath id="{label_clip_id}" clipPathUnits="userSpaceOnUse">'
                f'<rect x="66" y="{row_y - 16}" width="310" height="18"/></clipPath></defs>'
            )
            text(66, row_y - 2, model.get("model_name") or model_id, 12, 550, clip_id=label_clip_id)
            text(400, row_y - 2, f"{_fmt(_summary_value(stage_memory.get('system_ram_peak_gib'), 'max'))} GiB", 13, 550)
            text(570, row_y - 2, f"{_fmt(_summary_value(stage_memory.get('rss_peak_gib'), 'max'))} GiB", 13, 550)
            text(740, row_y - 2, f"{_fmt(_summary_value(stage_memory.get('vram_peak_mib'), 'max'), 0)} MiB", 13, 550)
            capability_values = {
                "cache": _fmt(_summary_value(cache.get("reused_tokens"), "median"), 0),
                "agent": f"{agent.get('passed', 0)}/{agent.get('cases', 0)}" if agent.get("cases") else "未执行",
                "needle": f"{needle.get('found', 0)}/{needle.get('cases', 0)}" if needle.get("cases") else "未执行",
                "stability": stable,
            }
            for index, (stage, _) in enumerate(capability_columns):
                text(920 + index * 155, row_y - 2, capability_values[stage], 13, 550)
        foot_y = y + 84 + model_count * 48 + 18
        text(66, foot_y, f"内存按整个{memory_label}阶段统计，约 1 秒间隔采样；瞬时峰值可能未捕获。", 11, 400, "#596579")
        text(66, foot_y + 24, f"分享图汇总 {summary.get('record_count', 0)} 条逐项记录；失败详情与原始记录仍以完整报告为准。", 11, 400, "#596579")
    if capacity_models:
        capacity_y = foot_y + 90
        section(capacity_y, "上下文容量验证", "真实输入 token · 前/中/后各两次召回")
        rect(48, capacity_y + 14, 1504, 80 + len(capacity_models) * 42)
        for x, label in ((66, "模型 / 配置"), (520, "上限"), (690, "真实输入 token"), (990, "召回"), (1130, "判定")):
            text(x, capacity_y + 43, label, 12, 600, "#596579")
        rule(64, capacity_y + 55, 1536, capacity_y + 55)
        for index, (model_id, model) in enumerate(capacity_models):
            cap = model["context_tier"]
            result = model.get("capacity") or {}
            low, high = result.get("actual_prompt_tokens_min"), result.get("actual_prompt_tokens_max")
            actual = f"{low:,}–{high:,}" if isinstance(low, int) and isinstance(high, int) else "—"
            state = {"verified": "已验证可用", "failed": "召回未通过", "insufficient": "证据不足"}.get(result.get("status"), "未执行")
            row_y = capacity_y + 85 + index * 42
            text(66, row_y, model.get("model_name") or model_id, 13, 550)
            text(520, row_y, f"{cap // 1024}K", 13, 550)
            text(690, row_y, actual, 13, 550)
            text(990, row_y, f"{result.get('hits', 0)}/{result.get('cases', 0)}", 13, 550)
            text(1130, row_y, state, 13, 550)
        highest = summary.get("highest_verified_context") or {}
        highest_label = " / ".join(f"{source} {cap // 1024}K" for source, cap in sorted(highest.items())) or "无"
        text(66, capacity_y + 105 + len(capacity_models) * 42, f"最高已验证档：{highest_label}；仅代表本次所选档位的召回结果。", 11, 400, "#596579")
    final_y = capacity_y + 135 + len(capacity_models) * 42 if capacity_models else foot_y + 75
    height = max(500, final_y)
    pieces[0] = f'<svg xmlns="http://www.w3.org/2000/svg" width="1600" height="{height}" viewBox="0 0 1600 {height}" role="img" aria-label="Strata Benchmark 分享图">'
    pieces[1] = f'<rect width="1600" height="{height}" fill="#eef2f7"/>'
    pieces.append("</svg>")
    return "".join(pieces)


def export_controls_and_script(svg: str) -> tuple[str, str]:
    controls = (
        '<div class="share-actions"><button type="button" id="export-share-image">导出分享 PNG（复制到剪贴板）</button>'
        '<a href="share.svg" target="_blank" rel="noopener">打开分享图</a><span id="share-status" role="status" aria-live="polite"></span></div>'
        '<div class="share-preview" id="share-preview" hidden><img id="share-image-preview" alt="Benchmark 分享图预览">'
        '<div><button type="button" id="download-share-image">下载 PNG</button><button type="button" id="close-share-preview">关闭预览</button></div></div>'
        f'<div class="share-art" aria-hidden="true">{svg}</div>'
    )
    script = r"""(()=>{
const svg=document.querySelector('.share-art svg'),status=document.getElementById('share-status');
const preview=document.getElementById('share-preview'),previewImage=document.getElementById('share-image-preview');
const copyButton=document.getElementById('export-share-image');let currentBlob=null,currentUrl=null;
async function makePng(){
 const source=new XMLSerializer().serializeToString(svg),url=URL.createObjectURL(new Blob([source],{type:'image/svg+xml;charset=utf-8'}));
 try{const image=new Image();image.src=url;if(image.decode)await image.decode();else await new Promise((ok,bad)=>{image.onload=ok;image.onerror=bad;});
  const canvas=document.createElement('canvas');canvas.width=Number(svg.getAttribute('width'));canvas.height=Number(svg.getAttribute('height'));
  canvas.getContext('2d').drawImage(image,0,0,canvas.width,canvas.height);
  return await new Promise((ok,bad)=>canvas.toBlob(blob=>blob?ok(blob):bad(new Error('PNG 编码失败')),'image/png'));
 }finally{URL.revokeObjectURL(url);}
}
function showPreview(blob){currentBlob=blob;if(currentUrl)URL.revokeObjectURL(currentUrl);currentUrl=URL.createObjectURL(blob);previewImage.src=currentUrl;preview.hidden=false;}
document.getElementById('close-share-preview').addEventListener('click',()=>preview.hidden=true);
document.getElementById('download-share-image').addEventListener('click',()=>{if(!currentBlob)return;const a=document.createElement('a');a.href=currentUrl;a.download='Strata-Benchmark-Share.png';a.click();});
copyButton.addEventListener('click',async()=>{copyButton.disabled=true;status.textContent='正在生成 PNG…';let blob=null;try{
 blob=await makePng();if(!navigator.clipboard||!window.ClipboardItem)throw new Error('剪贴板不可用');
 await navigator.clipboard.write([new ClipboardItem({'image/png':blob})]);status.textContent='分享图片已复制到剪贴板。';
 }catch(error){try{showPreview(blob||await makePng());status.textContent='浏览器未允许复制图片，已打开预览；可下载 PNG 或打开 SVG 分享图。';}
 catch(renderError){status.textContent='PNG 生成失败，请使用“打开分享图”查看 SVG。';}}finally{copyButton.disabled=false;}});
})();"""
    return controls, script
