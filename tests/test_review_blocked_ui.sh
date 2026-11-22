#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/private-event-logs.sh"  # #255: never write the real event logs
# tests/test_review_blocked_ui.sh — the blocked-issue review page (#313, part of #308).
#
# Static checks on review-blocked-ui.html: no external resources, issue text never
# set as HTML, the token on every API call, and every API path the page uses
# served by review-blocked-server.py. Then, when node (with a global WebSocket)
# and a Chromium are installed, an end-to-end run: the server in a private temp
# repo on the file backend, the page in headless Chromium driven over the
# DevTools protocol, and each decision (approve, reject, ask, skip, batch)
# checked on the issues themselves.

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS="$ROOT/plugins/autocoder/scripts"
UI="$SCRIPTS/review-blocked-ui.html"
SERVER="$SCRIPTS/review-blocked-server.py"
ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — expected '$3', got '$2'"; fi; }

[ -f "$UI" ] || { bad "no $UI"; echo "Results: $PASS passed, $FAIL failed"; exit 1; }

# ── Static checks ──────────────────────────────────────────────────────────
EXT=$(grep -inE 'https?://|//[a-z0-9-]+\.[a-z]' "$UI")
[ -z "$EXT" ] && ok "the page names no external URL" || bad "the page names an external URL: $(printf '%s' "$EXT" | head -3)"
if grep -nE '<(script|link|img|iframe)[^>]*(src|href)=' "$UI" | grep -q .; then
  bad "the page loads a resource: $(grep -nE '<(script|link|img|iframe)[^>]*(src|href)=' "$UI" | head -3)"
else ok "the page loads no script, stylesheet, image or frame"; fi
grep -q "Content-Security-Policy" "$UI" && grep -q "default-src 'none'" "$UI" \
  && ok "a CSP forbids loading anything but the page's own API" || bad "no default-src 'none' CSP"

if grep -nE 'innerHTML|outerHTML|insertAdjacentHTML|document\.write|eval\(|new Function' "$UI" | grep -q .; then
  bad "the page parses strings as HTML or code: $(grep -nE 'innerHTML|outerHTML|insertAdjacentHTML|document\.write|eval\(|new Function' "$UI" | head -3)"
else ok "the page never parses a string as HTML or code"; fi

eq "the page calls fetch in exactly one place" "$(grep -c 'fetch(' "$UI")" 1
FETCH_FN=$(sed -n '/^async function api(/,/^}/p' "$UI")
case "$FETCH_FN" in
  *'fetch('*'"X-Review-Token": TOKEN'*|*'"X-Review-Token": TOKEN'*'fetch('*) ok "that one fetch sends the token header" ;;
  *) bad "the fetch helper does not send X-Review-Token" ;;
esac
grep -q 'URLSearchParams(location.search).get("token")' "$UI" && ok "the token comes from the page URL" \
  || bad "the page does not read the token from its URL"
if grep -nE 'XMLHttpRequest|sendBeacon|WebSocket|EventSource' "$UI" | grep -q .; then
  bad "the page has another way to reach the network"
else ok "no other network API is used"; fi

PATHS=$(grep -oE '"/api/[a-z/]+"' "$UI" | tr -d '"' | sort -u)
[ -n "$PATHS" ] || bad "the page uses no /api/ path"
for p in $PATHS; do
  grep -qF "path != \"$p\"" "$SERVER" && ok "the server serves $p" || bad "the page uses $p, which the server does not serve"
done

SERVER_LABELS=$(sed -n '/^BLOCKING_LABELS/,/\]/p' "$SERVER" | grep -oE '"[a-z-]+"' | sort -u | tr '\n' ' ')
UI_LABELS=$(sed -n '/^const BLOCKING_LABELS/,/;/p' "$UI" | grep -oE '"[a-z-]+"' | sort -u | tr '\n' ' ')
eq "the page and the server list the same blocking labels" "$UI_LABELS" "$SERVER_LABELS"

# ── End to end in headless Chromium ────────────────────────────────────────
CHROME=""
for c in chromium chromium-browser google-chrome-stable google-chrome; do
  command -v "$c" >/dev/null 2>&1 && { CHROME=$(command -v "$c"); break; }
done
if ! command -v node >/dev/null 2>&1 || ! node -e 'process.exit(typeof WebSocket === "function" ? 0 : 1)' 2>/dev/null \
   || [ -z "$CHROME" ]; then
  echo "SKIP: end-to-end checks need node with a global WebSocket (22+) and Chromium"
  echo ""
  echo "Results: $PASS passed, $FAIL failed"
  [ "$FAIL" -eq 0 ]; exit
fi

TMP=$(mktemp -d)
SERVER_PID=""; CHROME_PID=""
cleanup() {
  [ -n "$CHROME_PID" ] && kill "$CHROME_PID" 2>/dev/null
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
  wait 2>/dev/null; rm -rf "$TMP" 2>/dev/null || { sleep 1; rm -rf "$TMP"; }
}
trap cleanup EXIT
unset ISSUE_SOURCE ISSUE_BACKEND ISSUE_DIR AUTOCODER_BLOCKED_CACHE_DIR
export AUTOCODER_ISSUE_EVENTS="$TMP/issue-events.jsonl"

git init -q "$TMP/repo"; cd "$TMP/repo" || exit 1
git config user.email t@example.com; git config user.name T
printf '{"issueSource": "file"}\n' > .autocoder.json
echo a > a; git add -A; git commit -qm base

IF() { ( source "$SCRIPTS/issue-fns.sh" >/dev/null 2>&1; "$@" ); }
new_issue() { IF issue_create --title "$1" --body "$2" | jq -r .number; }
labels_of() { IF issue_get "$1" | jq -r '[.labels[] | (.name? // .)] | sort | join(",")'; }
state_of()  { IF issue_get "$1" | jq -r '.state | ascii_downcase'; }
text_of()   { IF issue_get "$1" | jq -r '[.body, (.comments[]?.body)] | join("\n")'; }
block() { IF issue_update "$1" --add-label "$2" >/dev/null 2>&1; }

# An issue body that would run script if the page ever parsed it as HTML.
XSS='<img src=x onerror="window.__pwned=1"><script>window.__pwned=1</script><b>bold</b>'
A=$(new_issue "Pick a storage backend" "$XSS");  block "$A" needs-design; block "$A" P1
B=$(new_issue "Rewrite the parser" "too big");    block "$B" too-complex
C=$(new_issue "Add a dark mode" "later");         block "$C" future
D=$(new_issue "Unclear request" "what?");         block "$D" needs-clarification
E=$(new_issue "Batch one" "e");                   block "$E" needs-approval
F=$(new_issue "Batch two" "f");                   block "$F" needs-approval
IF issue_comment "$A" --body "🎨 **Blocked — Needs Design**: two storage options, no winner" >/dev/null 2>&1

cat > "$TMP/analysis.json" <<'JSON'
{"summary": "Pick a storage backend",
 "options": [
   {"title": "SQLite", "pros": ["one file"], "cons": ["locking"], "effort": "small"},
   {"title": "JSON files", "pros": ["no dependency"], "cons": ["no queries"], "effort": "tiny"}
 ],
 "recommended": 1}
JSON

python3 "$SERVER" > "$TMP/server.out" 2> "$TMP/server.err" &
SERVER_PID=$!
URL=""
for _ in $(seq 1 50); do
  URL=$(sed -n 's/^review-blocked-server: //p' "$TMP/server.out" | head -1)
  [ -n "$URL" ] && break
  sleep 0.1
done
[ -n "$URL" ] || { bad "the server printed no startup URL: $(cat "$TMP/server.err")"; echo "Results: $PASS passed, $FAIL failed"; exit 1; }
BASE=${URL%%/\?*}; TOKEN=${URL##*token=}

# Cache analyses under the keys the server computes, so A, E and F read as current.
KEYS=$(curl -s -H "X-Review-Token: $TOKEN" "$BASE/api/issues")
for n in "$A" "$E" "$F"; do
  key=$(printf '%s' "$KEYS" | jq -r --argjson n "$n" '.issues[] | select(.number == $n) | .analysisKey')
  python3 "$SCRIPTS/blocked-analysis-cache.py" put "$n" --updated-at "$key" --file "$TMP/analysis.json" >/dev/null
done

DEVPORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
"$CHROME" --headless=new --no-sandbox --disable-gpu --no-first-run --no-default-browser-check \
  --user-data-dir="$TMP/chrome" --remote-debugging-address=127.0.0.1 --remote-debugging-port="$DEVPORT" \
  about:blank > "$TMP/chrome.log" 2>&1 &
CHROME_PID=$!

# The driver: one page, a step per argument; each step's result is printed as JSON.
cat > "$TMP/drive.mjs" <<'JS'
const [devport, url] = process.argv.slice(2);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let targets;
for (let i = 0; i < 100; i++) {
  try { targets = await (await fetch(`http://127.0.0.1:${devport}/json/list`)).json(); break; }
  catch { await sleep(100); }
}
const page = targets.find((t) => t.type === "page");
const ws = new WebSocket(page.webSocketDebuggerUrl);
await new Promise((r, j) => { ws.onopen = r; ws.onerror = j; });
let id = 0; const waiting = new Map();
ws.onmessage = (m) => { const d = JSON.parse(m.data); if (waiting.has(d.id)) { waiting.get(d.id)(d); waiting.delete(d.id); } };
const send = (method, params = {}) => new Promise((r) => { const i = ++id; waiting.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
const evaluate = async (expr) => {
  const r = await send("Runtime.evaluate", { expression: `(async () => { ${expr} })()`, awaitPromise: true, returnByValue: true });
  if (r.result.exceptionDetails) throw new Error(JSON.stringify(r.result.exceptionDetails));
  return r.result.result.value;
};
const until = async (cond) => { for (let i = 0; i < 200; i++) { if (await evaluate(`return !!(${cond});`)) return true; await sleep(50); } return false; };
await send("Page.enable");
await send("Runtime.enable");
await send("Page.navigate", { url });
const out = {};
out.loaded = await until(`document.querySelectorAll("#list .item").length >= 6`);
out.list = await evaluate(`return [...document.querySelectorAll("#list h2, #list .item")].map((n) => n.tagName === "H2" ? n.textContent : n.dataset.issue + ":" + n.querySelector(".badge:last-child").textContent);`);
for (const step of process.argv.slice(4)) {
  const [name, n, ...rest] = step.split(":");
  const arg = rest.join(":");
  await evaluate(`[...document.querySelectorAll("#list .item")].find((x) => x.dataset.issue === "${n}")?.click();`);
  await until(`document.querySelector("#detail h2")?.textContent.startsWith("#${n} ")`);
  if (name === "inspect") {
    out.inspect = await evaluate(`return { body: document.getElementById("body").textContent,
      reason: document.getElementById("block-reason")?.textContent || null,
      injected: document.querySelectorAll("#detail img, #detail script, #detail b").length,
      pwned: !!window.__pwned,
      options: document.querySelectorAll("#detail .option").length,
      recommended: document.querySelector("#detail .option.recommended h4")?.textContent || null };`);
    continue;
  }
  const before = await evaluate(`return document.getElementById("status").textContent;`);
  if (name === "approve") await evaluate(`document.querySelector('[data-approve="${arg}"]').click();`);
  if (name === "reject") await evaluate(`const t = document.getElementById("reject-reason"); t.value = ${JSON.stringify(arg)}; document.getElementById("reject-btn").click();`);
  if (name === "ask") await evaluate(`const t = document.getElementById("ask-question"); t.value = ${JSON.stringify(arg)}; document.getElementById("ask-btn").click();`);
  if (name === "skip") await evaluate(`document.getElementById("skip-btn").click();`);
  if (name === "batch") {
    await evaluate(`document.getElementById("select-fresh").click(); document.getElementById("batch").click();`);
    await until(`document.querySelectorAll("#results li").length > 0`);
    out.batch = await evaluate(`return { results: [...document.querySelectorAll("#results li")].map((li) => li.dataset.result + ":" + li.querySelector(".badge").textContent),
      status: document.getElementById("status").textContent };`);
    continue;
  }
  await until(`document.getElementById("status").textContent !== ${JSON.stringify(before)} && !document.getElementById("status").textContent.startsWith("Sending")`);
  out[name] = await evaluate(`return document.getElementById("status").textContent;`);
}
console.log(JSON.stringify(out));
ws.close();
process.exit(0);
JS

# The batch selects every issue with a current analysis: A (approved first, so no
# longer batchable), E and F.
OUT=$(timeout 90 node "$TMP/drive.mjs" "$DEVPORT" "$URL" \
  "inspect:$A" "approve:$A:0" "reject:$B:not worth it" "ask:$D:which page do you mean?" "skip:$C" "batch:$E" 2>"$TMP/drive.err")
[ -n "$OUT" ] || bad "the browser driver printed nothing: $(tail -5 "$TMP/drive.err") $(tail -3 "$TMP/chrome.log")"

eq "the page lists every blocked issue" "$(printf '%s' "$OUT" | jq -r .loaded)" "true"
eq "issues are grouped by blocking label, each with its analysis state" \
  "$(printf '%s' "$OUT" | jq -c .list)" \
  "[\"needs-approval (2)\",\"$E:analysis\",\"$F:analysis\",\"needs-design (1)\",\"$A:analysis\",\"needs-clarification (1)\",\"$D:analysis missing\",\"too-complex (1)\",\"$B:analysis missing\",\"future (1)\",\"$C:analysis missing\"]"

eq "the body is shown as text, markup and all" "$(printf '%s' "$OUT" | jq -r .inspect.body | head -1)" "$XSS"
eq "issue markup creates no elements" "$(printf '%s' "$OUT" | jq -r .inspect.injected)" 0
eq "issue markup runs no script" "$(printf '%s' "$OUT" | jq -r .inspect.pwned)" "false"
case "$(printf '%s' "$OUT" | jq -r .inspect.reason)" in
  *"Needs Design"*) ok "the detail pane shows the comment that explains the block" ;;
  *) bad "block reason: $(printf '%s' "$OUT" | jq -r .inspect.reason)" ;;
esac
eq "the analysis shows each option" "$(printf '%s' "$OUT" | jq -r .inspect.options)" 2
case "$(printf '%s' "$OUT" | jq -r .inspect.recommended)" in
  *"JSON files"*recommended*) ok "the recommended option is highlighted" ;;
  *) bad "recommended: $(printf '%s' "$OUT" | jq -r .inspect.recommended)" ;;
esac

eq "approve reports success" "$(printf '%s' "$OUT" | jq -r .approve)" "#$A: approve done"
case ",$(labels_of "$A")," in *,needs-design,*) bad "approve left needs-design on #$A" ;; *) ok "approve removed the blocking label" ;; esac
case "$(text_of "$A")" in *"Option 1 of 2: SQLite (effort: small)"*) ok "approve posted the chosen option" ;; *) bad "approval text: $(text_of "$A" | tail -5)" ;; esac

eq "reject reports success" "$(printf '%s' "$OUT" | jq -r .reject)" "#$B: reject done"
eq "reject closed the issue" "$(state_of "$B")" "closed"
case "$(text_of "$B")" in *"not worth it"*) ok "reject posted the reason" ;; *) bad "reject text missing" ;; esac

eq "ask reports success" "$(printf '%s' "$OUT" | jq -r .ask)" "#$D: ask done"
case "$(text_of "$D")" in *"which page do you mean?"*) ok "ask posted the question" ;; *) bad "question missing on #$D" ;; esac
case ",$(labels_of "$D")," in *,needs-clarification,*) ok "ask leaves the issue blocked" ;; *) bad "ask removed the label" ;; esac

eq "skip reports success" "$(printf '%s' "$OUT" | jq -r .skip)" "#$C: skip done"
case ",$(labels_of "$C")," in *,future,*) ok "skip changes nothing" ;; *) bad "skip changed #$C's labels" ;; esac

eq "batch shows one result per selected issue" "$(printf '%s' "$OUT" | jq -c '.batch.results | sort')" \
  "$(printf '["%s:ok","%s:ok"]' "$E" "$F" | jq -c 'sort')"
eq "batch reports the count" "$(printf '%s' "$OUT" | jq -r .batch.status)" "2 approved"
for n in "$E" "$F"; do
  case ",$(labels_of "$n")," in *,needs-approval,*) bad "batch left needs-approval on #$n" ;; *) ok "batch approved #$n" ;; esac
  case "$(text_of "$n")" in *"Option 2 of 2: JSON files (effort: tiny) — the recommended option"*) ok "batch posted #$n's recommended option" ;; *) bad "batch text on #$n" ;; esac
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
