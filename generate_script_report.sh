#!/bin/bash
# 生成 script/qa/ 链上测试 HTML 报告（与 report1.html 同格式）
# Usage: bash generate_script_report.sh

LOGDIR="logs/script"
OUTPUT="script_report.html"
TOTAL=0
PASS=0
FAIL=0
RETRY=0

# 收集数据
declare -a FILES=()
declare -a TC_IDS=()
declare -a TC_NAMES=()
declare -a RESULTS=()

for f in $(ls "$LOGDIR"/*.log 2>/dev/null | sort); do
  [ -f "$f" ] || continue
  filename=$(basename "$f" .log)
  tc_id=$(grep -m1 "testcase id:" "$f" | sed 's/.*testcase id: *//')
  tc_name=$(grep -m1 "testcase name:" "$f" | sed 's/.*testcase name: *//')
  result=$(grep -m1 "test result:" "$f" | sed 's/.*test result: *//')

  [ -z "$tc_id" ] && tc_id="$filename"
  [ -z "$tc_name" ] && tc_name="$filename"

  FILES+=("$filename")
  TC_IDS+=("$tc_id")
  TC_NAMES+=("$tc_name")

  if [ "$result" = "passed" ]; then
    RESULTS+=("passed")
    PASS=$((PASS + 1))
  else
    RESULTS+=("failed")
    FAIL=$((FAIL + 1))
  fi
  TOTAL=$((TOTAL + 1))
done

# 获取 git commit
COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
COMMIT_FULL=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
TODAY=$(date '+%Y-%m-%d')

# 开始写 HTML
cat > "$OUTPUT" << 'STYLE_HEAD'

<!DOCTYPE html>
<html lang="zh">
<head>
<meta charset="UTF-8">
<title>mStocks Chain Script QA Report</title>
<style>
html, body {
    margin: 0; padding: 0; height: 100%;
    font-family: -apple-system, 'PingFang SC', Arial, sans-serif;
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
.retried { color: #f0a030; font-weight: bold; }
.failed { color: #e74c3c; font-weight: bold; }
.log-block {
    border: 1px solid #e2e8f0; border-radius: 8px; margin: 14px 0;
    padding: 14px; font-size: 14px; background: #fff;
    box-shadow: 0 1px 3px rgba(0,0,0,0.04);
}
.log-content { max-height: 600px; overflow-y: auto; }
.log-line { white-space: pre-wrap; word-break: break-all; overflow-wrap: break-word; font-family: 'Menlo','Consolas', monospace; font-size: 13px; }
.log-error, .log-stack { color: #e74c3c; font-weight: bold; }
.log-warning { color: #A64500; font-weight: bold; }
.log-scene { color: #00d395; font-weight: bold; }
.log-step { color: #3b82f6; font-weight: bold; }
.log-passed { color: #00d395; font-weight: bold; }
.log-syslog { color: #999; font-style: italic; }
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
STYLE_HEAD

# Chart.js + scripts
cat >> "$OUTPUT" << SCRIPTS
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
window.onload = function() {
    var ctx = document.getElementById('resultChart')?.getContext('2d');
    if(ctx){
        new Chart(ctx, {
            type: 'pie',
            data: {
                labels: ['通过', '重试', '失败'],
                datasets: [{
                    data: [${PASS}, ${RETRY}, ${FAIL}],
                    backgroundColor: ['#00d395', '#f0a030', '#e74c3c']
                }]
            },
            options: {
                responsive: true,
                plugins: { legend: { position: 'bottom' } }
            }
        });
    }
};
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
    <div class="sidebar">
        <div class="sidebar-inner">
            <div class="sidebar-brand">Mantle Network</div>
            <input type="text" id="searchInput" onkeyup="searchLinks()" class="search-box" placeholder="搜索用例...">
            <a class="nav-top" href="#overview" onclick="highlightSelected(this)">测试概览</a>
SCRIPTS

# Sidebar: passed section
if [ "$PASS" -gt 0 ]; then
  echo '            <div class="nav-section category"><div class="nav-header nav-cat" onclick="navHeaderClick(this, '"'"'#passed_cases'"'"')"><span class="arrow" onclick="event.stopPropagation(); toggleNav(this.parentElement)">▶</span>通过用例</div><div class="nav-body">' >> "$OUTPUT"
  for i in "${!FILES[@]}"; do
    if [ "${RESULTS[$i]}" = "passed" ]; then
      fn="${FILES[$i]}"
      tc_name_esc=$(echo "${TC_NAMES[$i]}" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g')
      echo "<a class=\"sub-link\" href=\"#passed_${fn}\" onclick=\"highlightSelected(this)\" title=\"${fn}\">${tc_name_esc}</a>" >> "$OUTPUT"
    fi
  done
  echo '</div></div>' >> "$OUTPUT"
fi

# Sidebar: failed section
if [ "$FAIL" -gt 0 ]; then
  echo '            <div class="nav-section category"><div class="nav-header nav-cat" onclick="navHeaderClick(this, '"'"'#failed_cases'"'"')"><span class="arrow" onclick="event.stopPropagation(); toggleNav(this.parentElement)">▶</span>失败用例</div><div class="nav-body">' >> "$OUTPUT"
  for i in "${!FILES[@]}"; do
    if [ "${RESULTS[$i]}" = "failed" ]; then
      fn="${FILES[$i]}"
      tc_name_esc=$(echo "${TC_NAMES[$i]}" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g')
      echo "<a class=\"sub-link\" href=\"#failed_${fn}\" onclick=\"highlightSelected(this)\" title=\"${fn}\">${tc_name_esc}</a>" >> "$OUTPUT"
    fi
  done
  echo '</div></div>' >> "$OUTPUT"
fi

# Close sidebar, open main
cat >> "$OUTPUT" << MAIN_HEAD
        </div>
    </div>
    <div class="dragbar"></div>
    <div class="main">
        <h1>mStocks Chain Script QA Report</h1>
        <h1 id="overview">测试概览</h1>
        <div class="overview">
            <div class="overview-text">
                <p><span class="p-bold">测试结果:</span> <span class="${FAIL:+failed}${FAIL:-passed}">$([ "$FAIL" -gt 0 ] && echo "失败" || echo "通过")</span></p>
                <p><span class="p-bold">测试版本:</span> PR#34 + PR#35</p>
                <p><span class="p-bold">测试时间:</span> ${TODAY}</p>
                <p><span class="p-bold">测试网络:</span> Mantle Sepolia (Chain ID: 5003)</p>
                <p><span class="p-bold">测试类型:</span> 链上脚本测试 (forge script)</p>
                <p><span class="p-bold">测试人员:</span> mantle-qa</p>
                <p><span class="p-bold">用例数量:</span> ${TOTAL}</p>
                <p><span class="p-bold">用例统计:</span> 通过 <span class="passed">${PASS}</span>，重试 <span class="retried">${RETRY}</span>，失败 <span class="failed">${FAIL}</span>，通过率 <span class="passed">$(( TOTAL > 0 ? PASS * 100 / TOTAL : 0 ))%</span></p>
            </div>
            <div class="overview-chart">
                <canvas id="resultChart"></canvas>
            </div>
        </div>
MAIN_HEAD

# Helper to classify log lines
classify_line() {
  local line="$1"
  if echo "$line" | grep -qE "test result: passed"; then
    echo "log-passed"
  elif echo "$line" | grep -qE "Error:|Revert|FAIL|failed"; then
    echo "log-error"
  elif echo "$line" | grep -qE "^\s*\[Step"; then
    echo "log-step"
  elif echo "$line" | grep -qE "PASS:"; then
    echo "log-passed"
  else
    echo "log-line"
  fi
}

# Passed cases
if [ "$PASS" -gt 0 ]; then
  echo '        <h1 id="passed_cases">通过用例</h1>' >> "$OUTPUT"
  for i in "${!FILES[@]}"; do
    [ "${RESULTS[$i]}" != "passed" ] && continue
    fn="${FILES[$i]}"
    tc_name_esc=$(echo "${TC_NAMES[$i]}" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
    logfile="$LOGDIR/${fn}.log"
    linecount=$(wc -l < "$logfile" | tr -d ' ')

    echo "            <div class=\"log-block\" id=\"passed_${fn}\">" >> "$OUTPUT"
    echo "              <h2>${fn}</h2>" >> "$OUTPUT"
    echo "              <p><span class=\"p-bold\">执行结果:</span> <span class=\"passed\">通过</span></p>" >> "$OUTPUT"
    echo "              <p><span class=\"p-bold\">用例名称:</span> ${tc_name_esc}</p>" >> "$OUTPUT"
    echo "              <details open>" >> "$OUTPUT"
    echo "                <summary>日志详情（${linecount} 行）</summary>" >> "$OUTPUT"
    echo -n "                <div class=\"log-content\">" >> "$OUTPUT"

    while IFS= read -r line; do
      line_esc=$(echo "$line" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
      css=$(classify_line "$line")
      echo -n "<div class=\"${css}\">${line_esc}</div>" >> "$OUTPUT"
    done < "$logfile"

    echo "</div>" >> "$OUTPUT"
    echo "              </details>" >> "$OUTPUT"
    echo "            </div>" >> "$OUTPUT"
    echo "            " >> "$OUTPUT"
  done
fi

# Failed cases
if [ "$FAIL" -gt 0 ]; then
  echo '        <h1 id="failed_cases">失败用例</h1>' >> "$OUTPUT"
  for i in "${!FILES[@]}"; do
    [ "${RESULTS[$i]}" != "failed" ] && continue
    fn="${FILES[$i]}"
    tc_name_esc=$(echo "${TC_NAMES[$i]}" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
    logfile="$LOGDIR/${fn}.log"
    linecount=$(wc -l < "$logfile" | tr -d ' ')

    echo "            <div class=\"log-block\" id=\"failed_${fn}\">" >> "$OUTPUT"
    echo "              <h2>${fn}</h2>" >> "$OUTPUT"
    echo "              <p><span class=\"p-bold\">执行结果:</span> <span class=\"failed\">失败</span></p>" >> "$OUTPUT"
    echo "              <p><span class=\"p-bold\">用例名称:</span> ${tc_name_esc}</p>" >> "$OUTPUT"
    echo "              <details open>" >> "$OUTPUT"
    echo "                <summary>日志详情（${linecount} 行）</summary>" >> "$OUTPUT"
    echo -n "                <div class=\"log-content\">" >> "$OUTPUT"

    while IFS= read -r line; do
      line_esc=$(echo "$line" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
      css=$(classify_line "$line")
      echo -n "<div class=\"${css}\">${line_esc}</div>" >> "$OUTPUT"
    done < "$logfile"

    echo "</div>" >> "$OUTPUT"
    echo "              </details>" >> "$OUTPUT"
    echo "            </div>" >> "$OUTPUT"
    echo "            " >> "$OUTPUT"
  done
fi

# Close HTML
cat >> "$OUTPUT" << 'HTMLFOOT'
    </div>
</div>
</body>
</html>
HTMLFOOT

echo "Report generated: $OUTPUT"
echo "Total: $TOTAL | Passed: $PASS | Failed: $FAIL | Rate: $(( TOTAL > 0 ? PASS * 100 / TOTAL : 0 ))%"
