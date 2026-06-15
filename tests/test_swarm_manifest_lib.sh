#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)/plugins/autocoder/scripts"
source "$SCRIPT_DIR/swarm-manifest-lib.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

worker1=$(manifest_worker_json 1 "/tmp/w1" "interactive" "agent-input" true "session:%1" "" paused)
worker2=$(manifest_worker_json 2 "/tmp/w2" "interactive" "agent-input" true "session:%2" "" paused)
workers=$(printf '%s\n%s\n' "$worker1" "$worker2" | json_array_from_lines)
manager=$(manifest_manager_json "shell" false shell ".autocoder/swarm/test-session.ready.txt" "session:%0" "")

MANIFEST="$TMP/$SWARM_STATE_DIR/test-session.json"
write_paused_manifest "$MANIFEST" test-session "$TMP" project claude tmux file configured "" "$TMP/.issues" task-1 main "$workers" "$manager"

state=$(manifest_get "$MANIFEST" 'm.get("state")')
[ "$state" = "paused" ] || { echo "FAIL: state should be paused" >&2; exit 1; }

manifest_update_worker_state "$MANIFEST" 1 started
worker_state=$(manifest_get "$MANIFEST" 'next(w for w in m["workers"] if w["number"] == 1)["state"]')
swarm_state=$(manifest_get "$MANIFEST" 'm.get("state")')
[ "$worker_state" = "started" ] || { echo "FAIL: worker 1 should be started" >&2; exit 1; }
[ "$swarm_state" = "partial" ] || { echo "FAIL: swarm should be partial" >&2; exit 1; }

manifest_update_worker_state "$MANIFEST" 2 started
swarm_state=$(manifest_get "$MANIFEST" 'm.get("state")')
[ "$swarm_state" = "running" ] || { echo "FAIL: swarm should be running" >&2; exit 1; }

worker3=$(manifest_worker_json 3 "/tmp/w3" "interactive" "agent-input" true "session:%3" "" paused)
manifest_add_worker_json "$MANIFEST" "$worker3"
count=$(manifest_get "$MANIFEST" 'len(m.get("workers", []))')
[ "$count" = "3" ] || { echo "FAIL: worker should be added" >&2; exit 1; }

manifest_remove_workers "$MANIFEST" 1 3
count=$(manifest_get "$MANIFEST" 'len(m.get("workers", []))')
[ "$count" = "1" ] || { echo "FAIL: workers should be removed" >&2; exit 1; }
remaining=$(manifest_get "$MANIFEST" 'm.get("workers", [])[0].get("number")')
[ "$remaining" = "2" ] || { echo "FAIL: worker 2 should remain" >&2; exit 1; }
swarm_state=$(manifest_get "$MANIFEST" 'm.get("state")')
[ "$swarm_state" = "running" ] || { echo "FAIL: swarm should remain running with started worker" >&2; exit 1; }

echo "ok swarm-manifest-lib"
