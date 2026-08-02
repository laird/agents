# SRE Monitor Workflow

**Purpose**: Monitor production systems for failures; file or update GitHub issues for any problems found.

**When to run**: When there are no P0-P3 bugs or approved enhancements to work on (idle state). After each monitoring cycle, sleep 15–30 minutes before the next — unless a P0 is detected (act immediately).

## Configuration

Set these before running (or export them in your shell profile):

```bash
export SRE_PROJECT_ID="your-gcp-project-id"          # GCP project (if using Cloud Run / GCP Logging)
export SRE_SERVICE_NAME="your-service-name"           # Primary service to monitor
export SRE_SECONDARY_SERVICE="your-secondary-service" # Optional: secondary service
export SRE_BASE_URL="https://your-service.example.com" # API base URL for health checks
```

## Step 1: Check Production Logs (Last 30 Minutes)

Fetch recent logs and filter for known error patterns:

```bash
# GCP Cloud Run example — adapt to your logging provider
gcloud logging read \
  "resource.type=cloud_run_revision AND resource.labels.service_name=$SRE_SERVICE_NAME" \
  --project="$SRE_PROJECT_ID" \
  --limit=100 \
  --freshness=30m 2>&1 \
  | grep -iE "(error|warn|fatal|timeout|restart|lock|stall)" \
  | head -40

# Secondary service (if configured)
if [ -n "$SRE_SECONDARY_SERVICE" ]; then
  gcloud logging read \
    "resource.type=cloud_run_revision AND resource.labels.service_name=$SRE_SECONDARY_SERVICE" \
    --project="$SRE_PROJECT_ID" \
    --limit=60 \
    --freshness=30m 2>&1 \
    | grep -iE "(error|warn|fatal|timeout|restart|lock|stall)" \
    | head -30
fi
```

**Adapt for other providers:**
- AWS CloudWatch: `aws logs filter-log-events --log-group-name /your/service --start-time ...`
- Datadog: `datadog-cli logs search "service:$SRE_SERVICE_NAME status:error"`
- Local/file: `tail -n 500 /var/log/your-service.log | grep -iE "(error|warn|fatal)"`

### Error Severity Guide

| Pattern | Severity | Action |
|---------|----------|--------|
| Service completely unresponsive (no logs >10 min) | P0 | File immediately, page on-call |
| Worker permanently crashed (max restart attempts reached) | P1 | File if new issue |
| Job lock lost / job orphaned | P1 | File if new issue |
| Repeated transient errors (>10/30 min) | P2 | File or update existing issue |
| Occasional transient errors (<10/30 min) | P3 | Comment on existing issue if open |
| Single one-off error | — | Log, no action unless pattern repeats |

## Step 2: Check Service Health

```bash
# Health endpoint
curl -sf "$SRE_BASE_URL/health" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print('status:', d.get('status', 'unknown'))
for k, v in d.items():
    if k != 'status':
        print(f'  {k}: {v}')
" || echo "HEALTH CHECK FAILED"

# List active jobs / work items (adapt path to your API)
curl -sf "$SRE_BASE_URL/api/v1/jobs" | python3 -c "
import json, sys, time
items = json.load(sys.stdin)
if isinstance(items, dict):
    items = items.get('jobs', items.get('data', []))
now_ms = time.time() * 1000
for item in (items if isinstance(items, list) else []):
    updated = item.get('updated_at', 0)
    age_h = (now_ms - updated) / 3_600_000 if isinstance(updated, (int, float)) else 0
    status = item.get('status', '?')
    name = str(item.get('name', item.get('id', '?')))[:40]
    stale = ' ⚠️  STALE' if age_h > 2 else ''
    print(f'{name}  status={status}  age={age_h:.1f}h{stale}')
" 2>/dev/null || echo "(no job list endpoint — skip)"
```

## Step 3: Check Worker Health

```bash
# Filter recent logs for worker heartbeat / restart messages
SINCE=$(date -u -d '5 minutes ago' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
        || date -u -v-5M '+%Y-%m-%dT%H:%M:%SZ')

gcloud logging read \
  "resource.type=cloud_run_revision AND resource.labels.service_name=$SRE_SERVICE_NAME AND timestamp>=\"$SINCE\"" \
  --project="$SRE_PROJECT_ID" \
  --limit=50 2>&1 \
  | grep -iE "(worker|heartbeat|restart|health)" \
  | head -20
```

Expected healthy output: all workers show a heartbeat / health-check-passed message at their configured interval (e.g., every 30 s).

## Step 4: Assess and Act

### Before Filing — Check for Existing Issues

```bash
gh issue list --state open --json number,title,labels \
  | python3 -c "
import json, sys
for i in json.load(sys.stdin):
    print(f'#{i[\"number\"]} {i[\"title\"][:70]}')
" | grep -iE "(worker|lock|stall|timeout|health|restart)"
```

### Decision Logic

```
If new error pattern not in any open issue:
  → File a new GitHub issue (see template below)

If error pattern matches an existing open issue:
  → Comment on that issue with latest timestamp, frequency, and new context

If everything is healthy (no errors, workers green, jobs progressing):
  → Log "SRE check passed — no action required" and schedule next check
```

### File New Issue

```bash
gh issue create \
  --title "YOUR TITLE HERE" \
  --label "P1,sre" \
  --body "$(cat <<'BODY'
## SRE Alert

**Detected**: $(date -u)
**Service**: $SRE_SERVICE_NAME

## Error Pattern

\`\`\`
PASTE_ERROR_MESSAGE_HERE
\`\`\`

## Frequency

N occurrences in last 30 minutes

## Impact

Describe the user-visible or system impact.

## Sample Logs

\`\`\`
PASTE_SAMPLE_LOG_LINES_HERE
\`\`\`

*Filed by autocoder sre-monitor workflow*
BODY
)"
```

### Comment on Existing Issue

```bash
gh issue comment ISSUE_NUMBER --body "**SRE Update** $(date -u)

Continued occurrence: N times in last 30 min
Sample: \`ERROR_MESSAGE_HERE\`"
```

## Adapting This Workflow

Copy this file into your project and replace:

1. **Log provider** — swap `gcloud logging read` for your provider's CLI (`aws logs`, `datadog-cli`, `journalctl`, etc.)
2. **Health endpoint** — update `/health` path and response shape
3. **Job/work-item endpoint** — update `/api/v1/jobs` path and JSON field names
4. **Error patterns** — extend the `grep -iE` pattern to match your service's log vocabulary
5. **Severity table** — add rows for known recurring patterns with their issue numbers

## Integration with Fix Loop

This workflow is the **idle fallback** in the autocoder fix loop. After one complete monitoring cycle (steps 1–4), sleep 15–30 minutes before the next — unless a P0 is detected, in which case act immediately and re-check within 5 minutes.
