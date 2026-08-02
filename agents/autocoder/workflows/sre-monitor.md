# SRE Monitor Workflow

**Purpose**: Monitor production logs for failures and engagement processing issues; file or update GitHub issues

**When to run**: When there are no P0-P3 bugs or approved enhancements to work on (idle state)

## Setup: Production Tunnel

```bash
# Verify production proxy is running (port 8080)
curl -s http://localhost:8080/health | python3 -c "import json,sys; d=json.load(sys.stdin); print('health:', d.get('status'))"

# If not running, start it:
gcloud config configurations activate production
gcloud run services proxy dashboard-ui \
  --project=gp-ct-sbox-sat-gcp0c9-nextgenc \
  --region=us-central1 \
  --port=8080 \
  --tag=production > /tmp/gcloud-proxy-production.log 2>&1 &
sleep 3
curl -s http://localhost:8080/health
```

## Step 1: Check Production Logs (Last 30 Minutes)

```bash
# IMPORTANT: Keep gcloud command on ONE line — multiline with backslash-continuation breaks due to trailing spaces.
# Use --freshness flag instead of timestamp in filter. Use grep for filtering (--format flag also causes issues).
gcloud logging read "resource.type=cloud_run_revision AND resource.labels.service_name=dashboard-ui" --project=gp-ct-sbox-sat-gcp0c9-nextgenc --limit=100 --freshness=30m 2>&1 | grep -E "(error|warn|heartbeat|Max restart|lock|stalled|timeout|Worker health)" | head -40

# Also check thesis-validator (internal service, same binary, shares Redis/DB with dashboard-ui):
gcloud logging read "resource.type=cloud_run_revision AND resource.labels.service_name=thesis-validator" --project=gp-ct-sbox-sat-gcp0c9-nextgenc --limit=60 --freshness=30m 2>&1 | grep -E "(message:|component:|Max restart|Worker health|error|lock)" | head -30
```

### Known Error Patterns

| Pattern | Severity | GH Issue | Action |
|---------|----------|----------|--------|
| `Max restart attempts reached, not restarting` (worker factory) | P1 | File if new | Worker permanently dead; service degraded |
| `could not renew lock for job` (BullMQ) | P1 | File if new | Job orphaned; engagement may be stuck |
| `Missing K_SERVICE or GCP_PROJECT_ID` | P3 | #2174 | Comment with count if increasing |
| `One or more TimeSeries could not be written` (GCPMetrics) | P3 | #2173 | Comment with count if increasing |
| No log output for >10 min from service | P0 | File immediately | CPU/event-loop starvation |

## Step 2: Check Engagement Health

```bash
# List active engagements
curl -s http://localhost:8080/api/v1/engagements | python3 -c "
import json,sys
d=json.load(sys.stdin)
items=d if isinstance(d,list) else d.get('engagements',d.get('data',[]))
for e in (items if isinstance(items,list) else []):
    lid=e.get('lifecycle','?')
    sid=e.get('id','?')[:8]
    name=e.get('name','?')[:30]
    status=e.get('status','?')
    updated=e.get('updated_at','?')
    print(f'{sid} {name} lifecycle={lid} status={status} updated={updated}')
"

# Check for engagements stuck with no progress (stale activeJobIds, error stages)
curl -s http://localhost:8080/api/v1/engagements | python3 -c "
import json,sys,time
d=json.load(sys.stdin)
items=d if isinstance(d,list) else d.get('engagements',d.get('data',[]))
now_ms=time.time()*1000
for e in (items if isinstance(items,list) else []):
    updated=e.get('updated_at',0)
    if isinstance(updated,(int,float)):
        age_hours=(now_ms-updated)/3600000
        if age_hours > 2:
            print(f'STALE {age_hours:.1f}h: {e.get(\"id\",\"?\")[:8]} {e.get(\"name\",\"?\")[:40]}')
    stages=e.get('stages',{})
    for stage,v in stages.items() if isinstance(stages,dict) else []:
        if isinstance(v,dict) and v.get('status') == 'error':
            print(f'ERROR stage: {e.get(\"id\",\"?\")[:8]} {stage}={v.get(\"status\")}')
    active=e.get('activeJobIds',[])
    cur=e.get('currentJobId')
    if isinstance(active,list) and len(active)>1:
        print(f'STALE JOBS: {e.get(\"id\",\"?\")[:8]} activeJobIds={active} currentJobId={cur}')
"
```

## Step 3: Check Worker Health Across All Instances

```bash
FILTER='resource.type="cloud_run_revision" AND resource.labels.service_name="dashboard-ui"'
SINCE=$(date -u -d '5 minutes ago' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -v-5M '+%Y-%m-%dT%H:%M:%SZ')
gcloud logging read "$FILTER AND timestamp>=\"$SINCE\"" \
  --project=gp-ct-sbox-sat-gcp0c9-nextgenc \
  --limit=50 \
  --format='table(timestamp,jsonPayload.component,jsonPayload.level,jsonPayload.message)' \
  | grep -E "(WorkerFactory|heartbeat|restart)"
```

Expected healthy output: all worker factories show `Worker health check passed` every ~30s

## Step 4: Check `thesis-validator-staging` Service

```bash
FILTER='resource.type="cloud_run_revision" AND resource.labels.service_name="thesis-validator-staging"'
SINCE=$(date -u -d '15 minutes ago' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -v-15M '+%Y-%m-%dT%H:%M:%SZ')
gcloud logging read "$FILTER AND timestamp>=\"$SINCE\"" \
  --project=gp-ct-sbox-sat-gcp0c9-nextgenc \
  --limit=30 \
  --format='table(timestamp,jsonPayload.level,jsonPayload.message,jsonPayload.component)' \
  | grep -E "(error|warn|heartbeat|restart|Max restart)"
```

Note: `thesis-validator-staging` has persistent dead workers (tracked in separate issue). Only file new issue if behavior worsens (e.g., service stops responding entirely).

## Step 5: Assess and Act

### Existing Issue Numbers (check before filing new)

```bash
# Search existing issues for relevant keywords
gh issue list --state open --label "P0,P1,P2,P3" --json number,title,labels | \
  python3 -c "
import json,sys
for i in json.load(sys.stdin):
    print(f'#{i[\"number\"]} {i[\"title\"][:70]}')
" | grep -iE "(worker|heartbeat|lock|engagement|stall|stuck|vertex|expert)"
```

### Decision Logic

```
If new error pattern not in any open issue:
  → File new GH issue with:
     - Priority label based on severity table above
     - Title: short description of the pattern
     - Body: timestamp, error message, Cloud Run revision, frequency, engagement ID if applicable
     - Label: "sre" or appropriate component label

If error pattern matches existing open issue:
  → Comment on existing issue with:
     - Latest occurrence timestamp
     - Frequency in last 30 min
     - Any new context (engagement IDs affected, etc.)

If production is completely healthy (no errors, all workers green, engagements progressing):
  → Log a brief note and schedule next check in 30 minutes
```

### File New Issue Template

```bash
gh issue create \
  --title "TITLE" \
  --label "P1,sre" \
  --body "$(cat << 'EOF'
## SRE Alert

**Detected**: $(date -u)
**Service**: dashboard-ui (production)
**Revision**: REVISION_NAME

## Error Pattern

\`\`\`
ERROR_MESSAGE
\`\`\`

## Frequency

N occurrences in last 30 minutes

## Impact

DESCRIBE_IMPACT

## Relevant Logs

\`\`\`
SAMPLE_LOG_LINES
\`\`\`

*Filed by autocoder sre-monitor workflow*
EOF
)"
```

### Add Comment to Existing Issue

```bash
gh issue comment ISSUE_NUMBER --body "**SRE Update** $(date -u)

Continued occurrence: N times in last 30 min
Revision: dashboard-ui-REVISION
Sample: \`ERROR_MESSAGE\`"
```

## Integration with Fix Loop

This workflow runs as the **idle fallback** in the autocoder fix loop. After completing one SRE monitoring cycle (steps 1-5), wait 15-30 minutes before the next cycle, unless a P0 is detected (act immediately in that case).
