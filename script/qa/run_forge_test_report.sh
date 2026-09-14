#!/usr/bin/env bash
# forge test → JSON log → HTML 报告
# 用法: bash script/qa/run_forge_test_report.sh [额外 forge test 参数]
# 示例:
#   bash script/qa/run_forge_test_report.sh                          # 全量
#   bash script/qa/run_forge_test_report.sh --match-path 'test/qa/*' # 只跑 QA
#   bash script/qa/run_forge_test_report.sh --match-contract DeployQA # 单文件

set -o pipefail

LOGDIR="logs/qa"
mkdir -p "$LOGDIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
JSON_LOG="$LOGDIR/forge_test_${TIMESTAMP}.json"
HTML_REPORT="$LOGDIR/forge_test_${TIMESTAMP}.html"

echo ">>> Running forge test (JSON output)..."
forge test --json "$@" > "$JSON_LOG" 2>&1
TEST_EXIT=$?

echo ">>> Parsing results and generating HTML report..."

python3 - "$JSON_LOG" "$HTML_REPORT" "$TIMESTAMP" <<'PYEOF'
import json, sys, os
from datetime import datetime

json_path = sys.argv[1]
html_path = sys.argv[2]
timestamp = sys.argv[3]

suites = []
total_pass = 0
total_fail = 0
total_skip = 0
total_duration_ms = 0

with open(json_path, 'r') as f:
    data = json.load(f)

for suite_key, suite_data in data.items():
    if not isinstance(suite_data, dict):
        continue
    test_results = suite_data.get("test_results", {})
    if not test_results:
        continue

    suite_name = suite_key.split(":")[-1] if ":" in suite_key else suite_key
    file_path = suite_key.split(":")[0] if ":" in suite_key else ""
    tests = []
    suite_pass = 0
    suite_fail = 0
    suite_skip = 0
    suite_duration = 0

    # parse suite-level duration "Xms Yus Zns"
    dur_str = suite_data.get("duration", "")
    if isinstance(dur_str, str):
        import re
        ms_m = re.search(r'(\d+)ms', dur_str)
        us_m = re.search(r'(\d+)\xb5s', dur_str)
        ns_m = re.search(r'(\d+)ns', dur_str)
        suite_duration = (int(ms_m.group(1)) if ms_m else 0) + (int(us_m.group(1))/1000 if us_m else 0) + (int(ns_m.group(1))/1e6 if ns_m else 0)

    for test_name, result in sorted(test_results.items()):
        status = result.get("status", "unknown")
        dur_s = result.get("duration", "")
        dur_ms = 0
        if isinstance(dur_s, str):
            ms_m2 = re.search(r'(\d+)ms', dur_s)
            us_m2 = re.search(r'(\d+)\xb5s', dur_s)
            ns_m2 = re.search(r'(\d+)ns', dur_s)
            dur_ms = (int(ms_m2.group(1)) if ms_m2 else 0) + (int(us_m2.group(1))/1000 if us_m2 else 0) + (int(ns_m2.group(1))/1e6 if ns_m2 else 0)
        elif isinstance(dur_s, dict):
            dur_ms = dur_s.get("secs",0)*1000 + dur_s.get("nanos",0)/1e6
        reason = result.get("reason", "") or ""
        decoded_logs = result.get("decoded_logs", []) or []

        if status == "Success":
            suite_pass += 1
        elif status == "Failure":
            suite_fail += 1
        else:
            suite_skip += 1

        tests.append({
            "name": test_name,
            "status": status,
            "duration_ms": dur_ms,
            "reason": reason,
            "logs": decoded_logs[:20],
        })

    suites.append({
        "name": suite_name,
        "file": file_path,
        "tests": tests,
        "pass": suite_pass,
        "fail": suite_fail,
        "skip": suite_skip,
        "duration_ms": suite_duration,
    })
    total_pass += suite_pass
    total_fail += suite_fail
    total_skip += suite_skip
    total_duration_ms += suite_duration

total = total_pass + total_fail + total_skip
pass_pct = (total_pass / total * 100) if total > 0 else 0

status_color = "#22c55e" if total_fail == 0 else "#ef4444"
status_text = "ALL PASSED" if total_fail == 0 else f"{total_fail} FAILED"

html = f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>mStocks Forge Test Report — {timestamp}</title>
<style>
  * {{ margin: 0; padding: 0; box-sizing: border-box; }}
  body {{ font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, monospace; background: #0f172a; color: #e2e8f0; padding: 24px; }}
  .header {{ text-align: center; padding: 32px 0; }}
  .header h1 {{ font-size: 24px; color: #f8fafc; }}
  .header .timestamp {{ color: #94a3b8; font-size: 14px; margin-top: 8px; }}
  .summary {{ display: flex; gap: 16px; justify-content: center; margin: 24px 0; flex-wrap: wrap; }}
  .stat {{ background: #1e293b; border-radius: 12px; padding: 20px 32px; text-align: center; min-width: 140px; }}
  .stat .value {{ font-size: 32px; font-weight: 700; }}
  .stat .label {{ font-size: 12px; color: #94a3b8; margin-top: 4px; text-transform: uppercase; letter-spacing: 1px; }}
  .stat.pass .value {{ color: #22c55e; }}
  .stat.fail .value {{ color: #ef4444; }}
  .stat.skip .value {{ color: #f59e0b; }}
  .stat.total .value {{ color: #38bdf8; }}
  .badge {{ display: inline-block; padding: 6px 20px; border-radius: 20px; font-weight: 700; font-size: 14px; color: #fff; background: {status_color}; margin: 16px 0; }}
  .suite {{ background: #1e293b; border-radius: 12px; margin: 16px 0; overflow: hidden; }}
  .suite-header {{ padding: 16px 20px; cursor: pointer; display: flex; justify-content: space-between; align-items: center; border-bottom: 1px solid #334155; }}
  .suite-header:hover {{ background: #263348; }}
  .suite-name {{ font-weight: 600; font-size: 15px; }}
  .suite-file {{ color: #64748b; font-size: 12px; margin-left: 12px; }}
  .suite-stats {{ display: flex; gap: 12px; font-size: 13px; }}
  .suite-stats .p {{ color: #22c55e; }} .suite-stats .f {{ color: #ef4444; }} .suite-stats .s {{ color: #f59e0b; }}
  .tests {{ display: none; }}
  .tests.open {{ display: block; }}
  .test-row {{ padding: 10px 20px 10px 36px; border-bottom: 1px solid #1a2332; display: flex; justify-content: space-between; align-items: center; font-size: 13px; }}
  .test-row:hover {{ background: #172033; }}
  .test-name {{ flex: 1; }}
  .test-status {{ width: 80px; text-align: center; font-weight: 600; border-radius: 4px; padding: 2px 8px; font-size: 11px; }}
  .test-status.Success {{ background: #14532d; color: #4ade80; }}
  .test-status.Failure {{ background: #7f1d1d; color: #fca5a5; }}
  .test-status.Skipped {{ background: #78350f; color: #fbbf24; }}
  .test-dur {{ width: 80px; text-align: right; color: #64748b; font-size: 12px; }}
  .test-reason {{ padding: 6px 20px 12px 52px; color: #fca5a5; font-size: 12px; background: #1a1a2e; white-space: pre-wrap; word-break: break-all; }}
  .progress {{ width: 100%; height: 8px; background: #334155; border-radius: 4px; overflow: hidden; margin: 8px 0; }}
  .progress-bar {{ height: 100%; background: linear-gradient(90deg, #22c55e {pass_pct:.1f}%, #ef4444 {pass_pct:.1f}%); }}
  .footer {{ text-align: center; color: #475569; font-size: 12px; margin-top: 32px; }}
</style>
</head>
<body>
<div class="header">
  <h1>mStocks Forge Test Report</h1>
  <div class="timestamp">{timestamp} | Duration: {total_duration_ms/1000:.1f}s</div>
  <div class="badge">{status_text}</div>
  <div class="progress"><div class="progress-bar"></div></div>
</div>
<div class="summary">
  <div class="stat total"><div class="value">{total}</div><div class="label">Total</div></div>
  <div class="stat pass"><div class="value">{total_pass}</div><div class="label">Passed</div></div>
  <div class="stat fail"><div class="value">{total_fail}</div><div class="label">Failed</div></div>
  <div class="stat skip"><div class="value">{total_skip}</div><div class="label">Skipped</div></div>
</div>
"""

for suite in sorted(suites, key=lambda s: (-s["fail"], s["name"])):
    indicator = "&#x2705;" if suite["fail"] == 0 else "&#x274C;"
    html += f"""
<div class="suite">
  <div class="suite-header" onclick="this.nextElementSibling.classList.toggle('open')">
    <span>
      <span>{indicator}</span>
      <span class="suite-name">{suite['name']}</span>
      <span class="suite-file">{suite['file']}</span>
    </span>
    <span class="suite-stats">
      <span class="p">{suite['pass']} pass</span>
      {'<span class="f">' + str(suite['fail']) + ' fail</span>' if suite['fail'] > 0 else ''}
      {'<span class="s">' + str(suite['skip']) + ' skip</span>' if suite['skip'] > 0 else ''}
    </span>
  </div>
  <div class="tests{'  open' if suite['fail'] > 0 else ''}">"""

    for t in suite["tests"]:
        dur_str = f"{t['duration_ms']:.0f}ms" if t['duration_ms'] < 1000 else f"{t['duration_ms']/1000:.1f}s"
        html += f"""
    <div class="test-row">
      <span class="test-name">{t['name']}</span>
      <span class="test-status {t['status']}">{t['status'].upper()}</span>
      <span class="test-dur">{dur_str}</span>
    </div>"""
        if t["reason"]:
            html += f"""
    <div class="test-reason">{t['reason']}</div>"""

    html += """
  </div>
</div>"""

html += f"""
<div class="footer">
  Generated by run_forge_test_report.sh | JSON log: {os.path.basename(json_path)}
</div>
</body>
</html>"""

with open(html_path, 'w') as f:
    f.write(html)

# Also print summary to terminal
print()
print("=" * 50)
print(f"  mStocks Forge Test Report")
print("=" * 50)
print()
for suite in sorted(suites, key=lambda s: (-s["fail"], s["name"])):
    icon = "PASS" if suite["fail"] == 0 else "FAIL"
    line = f"  [{icon}] {suite['name']}: {suite['pass']} pass"
    if suite["fail"]:
        line += f", {suite['fail']} fail"
    print(line)
    if suite["fail"]:
        for t in suite["tests"]:
            if t["status"] == "Failure":
                print(f"         x {t['name']}")
                if t["reason"]:
                    print(f"           {t['reason'][:120]}")
print()
print("-" * 50)
print(f"  Total: {total} | Pass: {total_pass} | Fail: {total_fail} | Skip: {total_skip}")
print(f"  Duration: {total_duration_ms/1000:.1f}s")
print("-" * 50)

sys.exit(0 if total_fail == 0 else 1)
PYEOF

PYEXIT=$?

echo ""
echo ">>> JSON log:    $JSON_LOG"
echo ">>> HTML report: $HTML_REPORT"
echo ""

if [ -f "$HTML_REPORT" ]; then
    echo ">>> Opening HTML report..."
    open "$HTML_REPORT" 2>/dev/null || xdg-open "$HTML_REPORT" 2>/dev/null || echo "    (open manually: $HTML_REPORT)"
fi

exit $TEST_EXIT
