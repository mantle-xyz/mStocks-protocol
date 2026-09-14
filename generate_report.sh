#!/usr/bin/env bash
set -euo pipefail

LOGDIR="logs/qa"
REPORT="report.html"

if [[ ! -d "$LOGDIR" ]]; then
    echo "Error: $LOGDIR not found. Run 'sh run_qa_tests.sh' first."
    exit 1
fi

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

TOTAL=0
PASSED=0
FAILED=0

GENTIME=$(date '+%Y-%m-%d %H:%M:%S')
GENDATE=$(date '+%Y-%m-%d')
# 开发分支名: 优先 REPORT_BRANCH env, 否则从最近一次 merge commit 里提取 origin/<branch>,
# 都拿不到则退回到当前 checkout 的分支名
BRANCH=${REPORT_BRANCH:-$(git log --merges -1 --pretty=format:"%s" 2>/dev/null | grep -oE "origin/[^ ']+" | head -1 | sed 's|origin/||')}
[[ -z "$BRANCH" ]] && BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")

# ── Pass 1: collect all test data ──
for logfile in "$LOGDIR"/*.log; do
    [[ -f "$logfile" ]] || continue
    testname=$(basename "$logfile" .log)
    TOTAL=$((TOTAL + 1))

    caseid=""
    casename=""
    if grep -q "testcase id:" "$logfile" 2>/dev/null; then
        caseid=$(grep "testcase id:" "$logfile" | head -1 | sed 's/.*testcase id: //')
        casename=$(grep "testcase name:" "$logfile" | head -1 | sed 's/.*testcase name: //')
    fi
    [[ -z "$caseid" ]] && caseid="$testname"
    [[ -z "$casename" ]] && casename="$testname"

    if grep -q "\[PASS\]" "$logfile" 2>/dev/null; then
        result="passed"
        PASSED=$((PASSED + 1))
    else
        result="failed"
        FAILED=$((FAILED + 1))
    fi

    # Use full log file content
    linecount=$(wc -l < "$logfile" | tr -d ' ')
    loglines_escaped=$(sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g' "$logfile")

    # Save to temp files for later assembly
    echo "${testname}|${caseid}|${casename}|${result}|${linecount}" >> "$TMPDIR/all_cases"
    echo "$loglines_escaped" > "$TMPDIR/log_${testname}"
done

PASS_PCT=0
[[ $TOTAL -gt 0 ]] && PASS_PCT=$((PASSED * 100 / TOTAL))

# ── Build sidebar links and main content ──
SIDEBAR_PASSED=""
SIDEBAR_FAILED=""
MAIN_PASSED=""
MAIN_FAILED=""

if [[ -f "$TMPDIR/all_cases" ]]; then
    while IFS='|' read -r testname caseid casename result linecount; do
        casename_html=$(printf '%s' "$casename" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
        caseid_html=$(printf '%s' "$caseid" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
        logcontent=$(cat "$TMPDIR/log_${testname}")

        if [[ "$result" == "passed" ]]; then
            result_cn="通过"
            result_class="passed"
            anchor="passed_${testname}"
            SIDEBAR_PASSED="${SIDEBAR_PASSED}<a class=\"sub-link\" href=\"#${anchor}\" onclick=\"highlightSelected(this)\" title=\"${testname}\">${caseid_html} ${casename_html}</a>"
            MAIN_PASSED="${MAIN_PASSED}
            <div class=\"log-block\" id=\"${anchor}\">
              <h2>${caseid_html}</h2>
              <p><span class=\"p-bold\">执行结果:</span> <span class=\"${result_class}\">${result_cn}</span></p>
              <p><span class=\"p-bold\">用例名称:</span> ${casename_html}</p>
              <p><span class=\"p-bold\">测试函数:</span> ${testname}</p>
              <details>
                <summary>日志详情（${linecount} 行）</summary>
                <div class=\"log-content\"><pre>${logcontent}</pre></div>
              </details>
            </div>"
        else
            result_cn="失败"
            result_class="failed"
            anchor="failed_${testname}"
            SIDEBAR_FAILED="${SIDEBAR_FAILED}<a class=\"sub-link\" href=\"#${anchor}\" onclick=\"highlightSelected(this)\" title=\"${testname}\">${caseid_html} ${casename_html}</a>"
            MAIN_FAILED="${MAIN_FAILED}
            <div class=\"log-block\" id=\"${anchor}\">
              <h2>${caseid_html}</h2>
              <p><span class=\"p-bold\">执行结果:</span> <span class=\"${result_class}\">${result_cn}</span></p>
              <p><span class=\"p-bold\">用例名称:</span> ${casename_html}</p>
              <p><span class=\"p-bold\">测试函数:</span> ${testname}</p>
              <details open>
                <summary>日志详情（${linecount} 行）</summary>
                <div class=\"log-content\"><pre>${logcontent}</pre></div>
              </details>
            </div>"
        fi
    done < "$TMPDIR/all_cases"
fi

# ── Generate HTML ──
cat > "$REPORT" <<'STYLE_EOF'
<!DOCTYPE html>
<html lang="zh">
<head>
<meta charset="UTF-8">
<title>mStocks QA测试报告</title>
<style>
html, body {
    margin: 0; padding: 0; height: 100%;
    font-family: -apple-system, 'PingFang SC', '微软雅黑', Arial, sans-serif;
    font-size: 15px; line-height: 1.6;
}
#container { display: flex; height: 100%; }

.sidebar {
    width: 260px; min-width: 20%; max-width: 32%;
    flex: none; background: #0f1923;
    border-right: 1px solid #1e2a3a;
    box-sizing: border-box; display: flex; flex-direction: column;
}
.sidebar-inner {
    padding: 18px 18px 60px 18px;
    flex: 1; overflow-y: auto;
}
.sidebar-inner::-webkit-scrollbar { width: 5px; }
.sidebar-inner::-webkit-scrollbar-thumb { background: #2a3a4a; border-radius: 3px; }
.sidebar-brand {
    padding: 6px 0 14px 0;
    font-size: 16px; font-weight: 600; color: #e0e6ed;
    letter-spacing: 0.5px;
}
.sidebar input.search-box {
    width: 100%; padding: 7px 10px; margin-bottom: 14px;
    box-sizing: border-box; font-size: 13px;
    background: #162230; color: #c8d1dc;
    border: 1px solid #2a3a4a; border-radius: 4px; outline: none;
}
.sidebar input.search-box::placeholder { color: #5a6a7a; }
.sidebar input.search-box:focus { border-color: #65d9e4; }
.sidebar .nav-top {
    display: block; text-decoration: none;
    color: #e0e6ed; font-weight: bold; font-size: 14px;
    padding: 5px 0 5px 18px; cursor: pointer; white-space: nowrap;
    border-radius: 4px;
}
.sidebar .nav-top:hover { background: rgba(101,217,228,0.08); }
.sidebar .nav-top.selected { color: #65d9e4 !important; }
.sidebar .nav-section { margin: 1px 0; }
.sidebar .nav-header {
    display: flex; align-items: center;
    color: #e0e6ed; font-size: 14px;
    padding: 5px 0; cursor: pointer; white-space: nowrap;
    border-radius: 4px;
}
.sidebar .nav-header:hover { background: rgba(101,217,228,0.08); }
.sidebar .nav-header.selected { color: #65d9e4 !important; }
.sidebar .nav-cat { font-weight: bold; }
.sidebar .nav-header .arrow {
    display: inline-block; width: 18px; font-size: 9px;
    text-align: center; flex-shrink: 0;
    color: #5a6a7a;
    opacity: 0; transition: opacity 0.15s, transform 0.2s;
    user-select: none;
}
.sidebar .nav-section:hover > .nav-header > .arrow { opacity: 1; }
.sidebar .nav-section.collapsed > .nav-header > .arrow { transform: rotate(0deg); }
.sidebar .nav-section:not(.collapsed) > .nav-header > .arrow { transform: rotate(90deg); }
.sidebar .nav-section.collapsed > .nav-body { display: none; }
.sidebar .sub-link {
    display: block; text-decoration: none;
    color: #8899aa; font-size: 13px;
    padding: 3px 0 3px 36px; cursor: pointer; white-space: nowrap;
    border-radius: 4px;
}
.sidebar .sub-link:hover { background: rgba(101,217,228,0.08); color: #c8d1dc; }
.sidebar .sub-link.selected { color: #65d9e4 !important; }

.dragbar { width: 4px; cursor: col-resize; background: #1e2a3a; }
.dragbar:hover { background: #65d9e4; }

.main { flex: 1; padding: 40px 36px; overflow-y: auto; background: #fafbfc; }
h1:first-of-type {
    font-size: 28px; margin-top: 20px; margin-bottom: 50px;
    text-align: center; color: #0f1923;
}
h1 { font-size: 24px; margin-top: 28px; color: #0f1923; }
h2 { font-size: 19px; margin-top: 20px; color: #1a2a3a; }
p { font-size: 15px; margin: 6px 0; }
.p-bold { font-weight: bold; }
.passed { color: #00d395; font-weight: bold; }
.failed { color: #e74c3c; font-weight: bold; }
.log-block {
    border: 1px solid #e2e8f0; border-radius: 8px; margin: 14px 0;
    padding: 14px; font-size: 14px; background: #fff;
    box-shadow: 0 1px 3px rgba(0,0,0,0.04);
}
.log-content { max-height: 600px; overflow-y: auto; }
pre {
    background: #1e293b; color: #e2e8f0; padding: 12px 16px;
    border-radius: 6px; font-size: 12px; margin-top: 8px;
    white-space: pre-wrap; word-break: break-all;
    font-family: 'Menlo','Consolas', monospace;
}
.overview {
    display: flex; align-items: flex-start; justify-content: flex-start;
    gap: 20px; margin-bottom: 6px;
    background: #fff; border: 1px solid #e2e8f0; border-radius: 8px;
    padding: 20px 24px; box-shadow: 0 1px 3px rgba(0,0,0,0.04);
}
.overview-text { flex: none; }
.overview-chart {
    width: 200px; height: 180px;
    display: flex; align-items: center; justify-content: center; flex-shrink: 0;
}
.footer {
    text-align: center; color: #8899aa; font-size: 12px;
    padding: 10px 0; border-top: 1px solid #1e2a3a;
    background: #0f1923;
    position: fixed; bottom: 0; left: 0; width: 100%;
}
</style>
<script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
<script>
function searchLinks() {
    var filter = document.getElementById('searchInput').value.toUpperCase();
    document.querySelectorAll('.sidebar .sub-link').forEach(function(link) {
        var text = link.textContent.toUpperCase();
        var title = (link.getAttribute('title') || '').toUpperCase();
        link.style.display = (text.indexOf(filter) > -1 || title.indexOf(filter) > -1) ? '' : 'none';
    });
    document.querySelectorAll('.sidebar .nav-section').forEach(function(sec) {
        var vis = sec.querySelectorAll('.sub-link:not([style*="display: none"])');
        sec.style.display = vis.length > 0 ? '' : 'none';
    });
}
function highlightSelected(el) {
    document.querySelectorAll('.sidebar .nav-top, .sidebar .nav-header, .sidebar .sub-link').forEach(function(e) {
        e.classList.remove('selected');
    });
    el.classList.add('selected');
}
function navHeaderClick(el, target) {
    highlightSelected(el);
    var sec = document.querySelector(target);
    if (sec) sec.scrollIntoView({behavior: 'smooth'});
}
function toggleNav(header) {
    var sec = header.closest('.nav-section');
    if (sec) sec.classList.toggle('collapsed');
}
let dragbar=null, sidebar=null, startX=0, startWidth=0;
window.addEventListener('DOMContentLoaded', () => {
    dragbar = document.querySelector('.dragbar');
    sidebar = document.querySelector('.sidebar');
    let maxW = 0;
    sidebar.querySelectorAll('.nav-top, .nav-header, .sub-link').forEach(el => {
        if (el.scrollWidth > maxW) maxW = el.scrollWidth;
    });
    const fitW = maxW + 60;
    const minW = window.innerWidth * 0.2;
    const capW = window.innerWidth * 0.32;
    sidebar.style.width = Math.max(minW, Math.min(fitW, capW)) + 'px';
    dragbar.addEventListener('mousedown', e => {
        e.preventDefault();
        startX = e.clientX;
        startWidth = sidebar.getBoundingClientRect().width;
        document.body.style.userSelect = 'none';
        document.body.style.cursor = 'col-resize';
        document.addEventListener('mousemove', drag);
        document.addEventListener('mouseup', stopDrag);
    });
});
function drag(e) {
    e.preventDefault();
    sidebar.style.flex = 'none';
    sidebar.style.width = Math.max(100, startWidth + (e.clientX - startX)) + 'px';
}
function stopDrag() {
    document.body.style.userSelect = '';
    document.body.style.cursor = '';
    document.removeEventListener('mousemove', drag);
    document.removeEventListener('mouseup', stopDrag);
}
</script>
</head>
<body>
<div id="container">
STYLE_EOF

# ── Sidebar ──
cat >> "$REPORT" <<SIDEBAR_TOP
    <div class="sidebar">
        <div class="sidebar-inner">
            <div class="sidebar-brand">Mantle Network</div>
            <input type="text" id="searchInput" onkeyup="searchLinks()" class="search-box" placeholder="搜索用例...">
            <a class="nav-top" href="#overview" onclick="highlightSelected(this)">测试概览</a>
SIDEBAR_TOP

if [[ $PASSED -gt 0 ]]; then
    cat >> "$REPORT" <<SIDEBAR_PASS
            <div class="nav-section"><div class="nav-header nav-cat" onclick="navHeaderClick(this, '#passed_cases')"><span class="arrow" onclick="event.stopPropagation(); toggleNav(this.parentElement)">▶</span>通过用例 (${PASSED})</div><div class="nav-body">${SIDEBAR_PASSED}</div></div>
SIDEBAR_PASS
fi

if [[ $FAILED -gt 0 ]]; then
    cat >> "$REPORT" <<SIDEBAR_FAIL
            <div class="nav-section"><div class="nav-header nav-cat" onclick="navHeaderClick(this, '#failed_cases')"><span class="arrow" onclick="event.stopPropagation(); toggleNav(this.parentElement)">▶</span>失败用例 (${FAILED})</div><div class="nav-body">${SIDEBAR_FAILED}</div></div>
SIDEBAR_FAIL
fi

cat >> "$REPORT" <<'SIDEBAR_END'
        </div>
    </div>
    <div class="dragbar"></div>
    <div class="main">
SIDEBAR_END

# ── Main: overview ──
if [[ $FAILED -gt 0 ]]; then
    OVERALL_RESULT="<span class=\"failed\">失败</span>"
else
    OVERALL_RESULT="<span class=\"passed\">通过</span>"
fi

cat >> "$REPORT" <<OVERVIEW
        <h1>mStocks QA测试报告 (forge test)</h1>
        <h1 id="overview">测试概览</h1>
        <div class="overview">
            <div class="overview-text">
                <p><span class="p-bold">测试结果:</span> ${OVERALL_RESULT}</p>
                <p><span class="p-bold">测试版本:</span> ${BRANCH}</p>
                <p><span class="p-bold">测试时间:</span> ${GENDATE}</p>
                <p><span class="p-bold">测试人员:</span> mantle-qa</p>
                <p><span class="p-bold">用例数量:</span> ${TOTAL}</p>
                <p><span class="p-bold">用例统计:</span> 通过 <span class="passed">${PASSED}</span>，失败 <span class="failed">${FAILED}</span>，通过率 <span class="passed">${PASS_PCT}%</span></p>
            </div>
            <div class="overview-chart">
                <canvas id="resultChart"></canvas>
            </div>
        </div>
        <script>
        window.onload = function() {
            var ctx = document.getElementById('resultChart')?.getContext('2d');
            if(ctx){
                new Chart(ctx, {
                    type: 'pie',
                    data: {
                        labels: ['通过', '失败'],
                        datasets: [{
                            data: [${PASSED}, ${FAILED}],
                            backgroundColor: ['#00d395', '#e74c3c']
                        }]
                    },
                    options: {
                        responsive: true,
                        plugins: { legend: { position: 'bottom' } }
                    }
                });
            }
        };
        </script>
OVERVIEW

# ── Main: failed cases ──
if [[ $FAILED -gt 0 ]]; then
    cat >> "$REPORT" <<FAILED_HEADER
        <h1 id="failed_cases">失败用例</h1>
FAILED_HEADER
    printf '%s' "$MAIN_FAILED" >> "$REPORT"
fi

# ── Main: passed cases ──
if [[ $PASSED -gt 0 ]]; then
    cat >> "$REPORT" <<PASSED_HEADER
        <h1 id="passed_cases">通过用例</h1>
PASSED_HEADER
    printf '%s' "$MAIN_PASSED" >> "$REPORT"
fi

# ── Footer ──
cat >> "$REPORT" <<'FOOTER'
    </div>
</div>
<div class="footer">Foundry forge test · mStocks Protocol QA</div>
</body>
</html>
FOOTER

echo "Report generated: $REPORT"
echo "Total: $TOTAL | Passed: $PASSED | Failed: $FAILED | Rate: ${PASS_PCT}%"
