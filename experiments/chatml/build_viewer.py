#!/usr/bin/env python3
"""Generate a self-contained HTML viewer for qualitative voice comparison.

Reads per-variant Phase-2 transcripts (and an optional variant-A baseline
transcript) from a probe run directory and emits a single HTML file with:

  - Top metrics strip per column
  - Three synchronized columns (A | B | C)
  - Per-epoch row in each column: diary text + action JSON + memory diff
    + collapsible "messages shown to the model" + per-epoch token / time
  - Picker to filter by epoch range, hide/show columns

All data is inlined as a `const RUNS = {...}` JS object — no CDN deps,
no external assets — opens cold in any browser.
"""

from __future__ import annotations

import argparse
import html
import json
from pathlib import Path
from typing import Any, Dict, List, Optional


def _load_jsonl(path: Path) -> List[Dict[str, Any]]:
    if not path.exists():
        return []
    out = []
    for line in path.read_text().splitlines():
        line = line.strip()
        if line:
            out.append(json.loads(line))
    return out


def _normalize_baseline(records: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    """Reshape variant A's run-21 records into the same shape we use here."""
    out = []
    for r in records:
        if r.get("scenario") != "S1":
            continue
        out.append({
            "epoch": r.get("epoch"),
            "seed": r.get("seed"),
            "diary": r.get("diary", ""),
            "raw_action": r.get("raw_action"),
            "clamped_action": r.get("clamped_action"),
            "memory_before": r.get("memory_before") or r.get("worldview_before") or [],
            "memory_after": r.get("memory_after") or r.get("worldview_after") or [],
            "slots_changed": r.get("slots_changed", []),
            "pass1_attempts": r.get("pass1_attempts"),
            "elapsed_s": r.get("elapsed_s"),
            "tokens": r.get("tokens"),
            # Variant A doesn't have messages — just full_prompt.
            "messages_pass1": r.get("full_prompt") or "",
        })
    return out


HTML_TEMPLATE = r"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>ChatML Experiment — Side-by-Side Voice Comparison</title>
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body {
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif;
    color: #1a1a1a;
    background: #f7f7f5;
    line-height: 1.5;
  }
  .topbar {
    position: sticky; top: 0; z-index: 50;
    background: #fff; border-bottom: 1px solid #d4d4d2;
    padding: 12px 20px;
    display: flex; gap: 16px; flex-wrap: wrap; align-items: center;
  }
  .topbar h1 { font-size: 16px; font-weight: 600; }
  .topbar .controls { display: flex; gap: 12px; align-items: center; flex-wrap: wrap; }
  .topbar label { font-size: 13px; display: flex; gap: 4px; align-items: center; cursor: pointer; }
  .topbar input[type="checkbox"] { cursor: pointer; }

  .grid {
    display: grid;
    grid-template-columns: repeat(var(--cols, 3), 1fr);
    gap: 12px;
    padding: 12px;
  }

  .col { background: #fff; border: 1px solid #d4d4d2; border-radius: 6px; overflow: hidden; }
  .col.hidden { display: none; }
  .col-header {
    padding: 12px 14px;
    background: #fafaf8;
    border-bottom: 1px solid #d4d4d2;
    position: sticky; top: 65px; z-index: 10;
  }
  .col-header h2 {
    font-size: 14px; font-weight: 700; margin-bottom: 4px;
    text-transform: uppercase; letter-spacing: 0.04em;
  }
  .col-A h2 { color: #6b6b65; }
  .col-B h2 { color: #2563eb; }
  .col-C h2 { color: #16a34a; }
  .col-header .desc { font-size: 12px; color: #555; margin-bottom: 8px; }
  .metrics-strip {
    display: grid; grid-template-columns: repeat(2, 1fr); gap: 4px 8px;
    font-size: 11px; color: #444;
  }
  .metric { display: flex; justify-content: space-between; }
  .metric .label { color: #666; }
  .metric .value { font-weight: 600; color: #1a1a1a; }

  .epoch {
    border-top: 1px solid #ececea;
    padding: 10px 14px;
  }
  .epoch:first-of-type { border-top: none; }
  .epoch-header {
    display: flex; gap: 10px; align-items: baseline; margin-bottom: 6px;
    font-size: 12px;
  }
  .epoch-num { font-weight: 700; color: #1a1a1a; }
  .epoch-meta { color: #888; font-family: ui-monospace, monospace; font-size: 11px; }
  .badge {
    display: inline-block; padding: 1px 6px; border-radius: 3px; font-size: 10px;
    font-weight: 600; text-transform: uppercase;
  }
  .badge-retry { background: #fee; color: #c33; }
  .badge-multi { background: #efe; color: #060; }

  .diary {
    font-family: ui-serif, Georgia, "Times New Roman", serif;
    font-size: 14px; color: #1a1a1a;
    padding: 6px 0; white-space: pre-wrap;
  }
  .action {
    font-family: ui-monospace, "SF Mono", Menlo, monospace;
    font-size: 11px; color: #444;
    background: #f6f6f4; padding: 6px 8px; border-radius: 3px;
    margin-top: 6px; white-space: pre-wrap; overflow-x: auto;
  }
  .mem-diff { margin-top: 6px; font-size: 12px; }
  .mem-diff .slot {
    padding: 4px 6px; border-left: 2px solid #16a34a; background: #f5fdf6;
    margin: 2px 0; font-family: ui-monospace, monospace; font-size: 11px;
  }
  .mem-diff .slot .from { color: #888; text-decoration: line-through; }
  .mem-diff .slot .to { color: #166534; font-weight: 500; }

  details.messages {
    margin-top: 8px; font-size: 11px; color: #555;
  }
  details.messages summary {
    cursor: pointer; padding: 3px 6px; background: #fafaf8;
    border-radius: 3px; user-select: none;
  }
  details.messages .messages-list {
    margin-top: 6px; max-height: 360px; overflow-y: auto;
    border: 1px solid #ececea; border-radius: 3px; padding: 6px;
  }
  .msg { padding: 4px 6px; margin: 4px 0; border-radius: 3px; }
  .msg.system { background: #fef9e7; }
  .msg.user { background: #eff6ff; }
  .msg.assistant { background: #f0fdf4; }
  .msg-role {
    font-weight: 700; font-size: 9px; text-transform: uppercase;
    color: #666; letter-spacing: 0.04em;
  }
  .msg-content {
    font-family: ui-monospace, monospace; font-size: 10px;
    white-space: pre-wrap; max-height: 180px; overflow-y: auto;
    margin-top: 2px;
  }

  .empty-banner {
    padding: 14px; color: #888; font-style: italic; text-align: center;
  }

  .scenario-picker { display: flex; gap: 6px; }
  .scenario-picker input { width: 60px; padding: 2px 4px; }
</style>
</head>
<body>

<div class="topbar">
  <h1>ChatML Experiment — Voice Comparison</h1>
  <div class="controls">
    <label><input type="checkbox" id="show-A" checked> A (baseline)</label>
    <label><input type="checkbox" id="show-B" checked> B (ChatML, no history)</label>
    <label><input type="checkbox" id="show-C" checked> C (ChatML + history)</label>
    <span class="scenario-picker">
      epoch range:
      <input type="number" id="ep-min" min="1" max="200">–
      <input type="number" id="ep-max" min="1" max="200">
    </span>
  </div>
</div>

<div class="grid" id="grid"></div>

<script>
const RUNS = __DATA_PLACEHOLDER__;

const VARIANT_DESC = {
  A: 'raw /v1/completions, "Dear Diary," prefill + retry, no history (run-21 baseline)',
  B: '/v1/chat/completions, two user/assistant exchanges, no history',
  C: '/v1/chat/completions, two exchanges, last 5 prior diaries as past pairs'
};

function escapeHtml(s) {
  return String(s)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

function fmtMetric(label, value) {
  return `<div class="metric"><span class="label">${label}</span><span class="value">${value}</span></div>`;
}

function buildMetricsStrip(records) {
  if (!records || records.length === 0) return '<div class="empty-banner">no records</div>';
  const openers = records.map(r => (r.diary || '').trim().slice(0, 50));
  const distinct = new Set(openers).size;
  const meanLen = records.reduce((s, r) => s + (r.diary || '').length, 0) / records.length;
  const actions = {};
  records.forEach(r => {
    const a = (r.clamped_action && r.clamped_action.action) || 'unknown';
    actions[a] = (actions[a] || 0) + 1;
  });
  const multi = records.filter(r => (r.slots_changed || []).length >= 2).length;
  const empty = records.filter(r => (r.pass1_attempts || 0) > 1).length;
  return `
    ${fmtMetric('epochs', records.length)}
    ${fmtMetric('unique openers', `${distinct}/${records.length}`)}
    ${fmtMetric('mean diary len', meanLen.toFixed(0))}
    ${fmtMetric('multi-update', `${multi}/${records.length}`)}
    ${fmtMetric('action mix', Object.entries(actions).map(([k, v]) => `${k.slice(0,4)}=${v}`).join(' '))}
    ${fmtMetric('empty 1st try', `${empty}/${records.length}`)}
  `;
}

function renderMemDiff(before, after, slotsChanged) {
  if (!slotsChanged || slotsChanged.length === 0) return '';
  const rows = slotsChanged.map(i => {
    const b = (before && before[i]) || {title: '', body: ''};
    const a = (after && after[i]) || {title: '', body: ''};
    const ba = (b.title || '') + (b.body ? ': ' + b.body : '');
    const aa = (a.title || '(untitled)') + (a.body ? ': ' + a.body : '');
    return `<div class="slot">
      <div>[${i}]</div>
      ${b.title || b.body ? `<div class="from">${escapeHtml(ba.slice(0, 120))}</div>` : ''}
      <div class="to">${escapeHtml(aa.slice(0, 200))}</div>
    </div>`;
  }).join('');
  return `<div class="mem-diff">${rows}</div>`;
}

function renderMessages(messages) {
  if (!messages) return '';
  // Variant A messages are a string (the full_prompt), not a list.
  if (typeof messages === 'string') {
    return `<div class="msg"><div class="msg-role">RAW PROMPT</div>
      <div class="msg-content">${escapeHtml(messages.slice(0, 8000))}</div></div>`;
  }
  return messages.map(m => `<div class="msg ${m.role}">
    <div class="msg-role">${m.role}</div>
    <div class="msg-content">${escapeHtml((m.content || '').slice(0, 2000))}</div>
  </div>`).join('');
}

function renderEpoch(rec) {
  const epoch = rec.epoch;
  const phaseIdx = rec.phase2_index || rec.epoch_idx || '';
  const action = rec.clamped_action || {};
  const actionStr = JSON.stringify(action, null, 2);
  const retryBadge = (rec.pass1_attempts && rec.pass1_attempts > 1)
    ? `<span class="badge badge-retry">${rec.pass1_attempts}x retry</span>` : '';
  const multiBadge = ((rec.slots_changed || []).length >= 2)
    ? `<span class="badge badge-multi">${rec.slots_changed.length}-slot</span>` : '';
  const tokens = rec.tokens || {};
  const meta = `epoch ${epoch} · seed ${rec.seed || '?'} · ${rec.elapsed_s || '?'}s · ` +
               `${tokens.completion_tokens || '?'} tok`;
  return `
    <div class="epoch">
      <div class="epoch-header">
        <span class="epoch-num">#${phaseIdx || epoch}</span>
        <span class="epoch-meta">${meta}</span>
        ${retryBadge}${multiBadge}
      </div>
      <div class="diary">${escapeHtml(rec.diary || '(empty)')}</div>
      <div class="action">${escapeHtml(actionStr)}</div>
      ${renderMemDiff(rec.memory_before, rec.memory_after, rec.slots_changed)}
      <details class="messages">
        <summary>show prompt / messages (${(typeof rec.messages_pass1 === 'string' ? 1 : (rec.messages_pass1 || []).length)} messages)</summary>
        <div class="messages-list">${renderMessages(rec.messages_pass1)}</div>
      </details>
    </div>
  `;
}

function buildColumn(variant, records) {
  const desc = VARIANT_DESC[variant] || '';
  const metrics = buildMetricsStrip(records);
  const epochs = (records || []).map(renderEpoch).join('');
  return `
    <div class="col col-${variant}" data-variant="${variant}">
      <div class="col-header">
        <h2>variant ${variant}</h2>
        <div class="desc">${escapeHtml(desc)}</div>
        <div class="metrics-strip">${metrics}</div>
      </div>
      ${epochs || '<div class="empty-banner">no records</div>'}
    </div>
  `;
}

function applyFilters() {
  const epMin = parseInt(document.getElementById('ep-min').value) || 0;
  const epMax = parseInt(document.getElementById('ep-max').value) || 9999;
  const visible = ['A', 'B', 'C'].filter(v => document.getElementById('show-' + v).checked);
  const cols = visible.map(v => buildColumn(v, (RUNS[v] || []).filter(r => {
    const e = r.epoch || 0;
    return e >= epMin && e <= epMax;
  })));
  document.getElementById('grid').innerHTML = cols.join('');
  document.documentElement.style.setProperty('--cols', visible.length || 1);
}

document.querySelectorAll('input').forEach(el => el.addEventListener('change', applyFilters));
const allEpochs = ['A','B','C'].flatMap(v => (RUNS[v] || []).map(r => r.epoch || 0)).filter(x => x);
if (allEpochs.length) {
  document.getElementById('ep-min').value = Math.min(...allEpochs);
  document.getElementById('ep-max').value = Math.max(...allEpochs);
}
applyFilters();
</script>

</body>
</html>
"""


def build_viewer(
    run_dir: Path,
    baseline_transcript: Optional[Path],
    out_path: Path,
    variants: List[str] = ("B", "C"),
) -> None:
    runs: Dict[str, List[Dict[str, Any]]] = {}
    if baseline_transcript and baseline_transcript.exists():
        runs["A"] = _normalize_baseline(_load_jsonl(baseline_transcript))
    for v in variants:
        var_dir = run_dir / v
        runs[v] = _load_jsonl(var_dir / "phase2_sequential.jsonl")

    data_json = json.dumps(runs, default=str)
    html_out = HTML_TEMPLATE.replace("__DATA_PLACEHOLDER__", data_json)
    out_path.write_text(html_out)
    print(f"wrote {out_path} ({out_path.stat().st_size // 1024} KB)")


def main():
    p = argparse.ArgumentParser()
    p.add_argument("run_dir")
    p.add_argument("--baseline-transcript", default=None,
                   help="Path to a run-21 transcript.jsonl for variant A")
    p.add_argument("--variants", default="B,C")
    p.add_argument("-o", "--output", default=None,
                   help="Default: <run_dir>/viewer.html")
    args = p.parse_args()

    run_dir = Path(args.run_dir).resolve()
    out_path = Path(args.output) if args.output else run_dir / "viewer.html"
    variants = tuple(v.strip() for v in args.variants.split(",") if v.strip())
    baseline = Path(args.baseline_transcript) if args.baseline_transcript else None
    build_viewer(run_dir, baseline, out_path, variants)


if __name__ == "__main__":
    main()
