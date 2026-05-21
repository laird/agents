#!/usr/bin/env bash
#
# run-phase-experiment.sh — runner for fix-loop token-efficiency experiments.
#
# Phase 0 scaffold (per docs/specs/2026-05-21-fix-loop-token-efficiency-design.md
# §10 Phase 0 and §13.1). This validates inputs and prints what it WOULD do.
# Actual execution is gated behind --execute, which is stubbed until the
# Phase 2.0 PostSessionEnd hook probe resolves (spec §10 Phase 2.0).
#
# Usage:
#   run-phase-experiment.sh \
#       --fixture <name> \
#       --duration <minutes> \
#       --cadence <Nm|Nh> \
#       --cache-ttl <5m|1h> \
#       [--inject-at <seconds>] [--inject-fixture <name>] \
#       --output-dir <path> \
#       [--execute]
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
FIXTURE_DIR="${REPO_ROOT}/tests/fixtures"

# ---- defaults / flags ----
FIXTURE=""
DURATION=""
CADENCE=""
CACHE_TTL=""
INJECT_AT=""
INJECT_FIXTURE=""
OUTPUT_DIR=""
EXECUTE=0   # 0 = dry-run (default), 1 = real run (stubbed)

usage() {
  sed -n '3,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-2}"
}

die() { echo "error: $*" >&2; exit 2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --fixture)        FIXTURE="${2:-}"; shift 2 ;;
    --duration)       DURATION="${2:-}"; shift 2 ;;
    --cadence)        CADENCE="${2:-}"; shift 2 ;;
    --cache-ttl)      CACHE_TTL="${2:-}"; shift 2 ;;
    --inject-at)      INJECT_AT="${2:-}"; shift 2 ;;
    --inject-fixture) INJECT_FIXTURE="${2:-}"; shift 2 ;;
    --output-dir)     OUTPUT_DIR="${2:-}"; shift 2 ;;
    --execute)        EXECUTE=1; shift ;;
    -h|--help)        usage 0 ;;
    *)                die "unknown flag: $1" ;;
  esac
done

# ---- validate required flags ----
[[ -n "$FIXTURE"   ]] || die "--fixture is required"
[[ -n "$DURATION"  ]] || die "--duration is required (minutes, integer)"
[[ -n "$CADENCE"   ]] || die "--cadence is required (e.g., 4m, 55m, 1h)"
[[ -n "$CACHE_TTL" ]] || die "--cache-ttl is required (5m or 1h)"

# ---- validate values ----
[[ "$DURATION" =~ ^[0-9]+m?$ ]] || die "--duration must be integer minutes (e.g., 30 or 30m)"
DURATION_MIN="${DURATION%m}"

[[ "$CADENCE" =~ ^[0-9]+[mh]$ ]] || die "--cadence must match <N>m or <N>h (got: $CADENCE)"

case "$CACHE_TTL" in
  5m|1h) ;;
  *) die "--cache-ttl must be '5m' or '1h' (got: $CACHE_TTL)" ;;
esac

FIXTURE_PATH="${FIXTURE_DIR}/queue-state-${FIXTURE}.sh"
if [[ ! -f "$FIXTURE_PATH" ]]; then
  die "fixture not found: ${FIXTURE_PATH}
hint: fixtures are committed under tests/fixtures/queue-state-<name>.sh
      (Phase 2.0 task — see spec §10). Create one or pick another name."
fi

if [[ -n "$INJECT_AT" || -n "$INJECT_FIXTURE" ]]; then
  [[ -n "$INJECT_AT" && -n "$INJECT_FIXTURE" ]] \
    || die "--inject-at and --inject-fixture must be used together"
  [[ "$INJECT_AT" =~ ^[0-9]+$ ]] || die "--inject-at must be integer seconds"
  INJECT_PATH="${FIXTURE_DIR}/queue-state-${INJECT_FIXTURE}.sh"
  [[ -f "$INJECT_PATH" ]] || die "inject fixture not found: ${INJECT_PATH}"
fi

if [[ -z "$OUTPUT_DIR" ]]; then
  OUTPUT_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/autocoder/experiments/$(date +%Y%m%d-%H%M%S)-${FIXTURE}-${CADENCE}-${CACHE_TTL}"
fi

# ---- plan summary (always printed) ----
cat <<EOF
fix-loop phase-experiment runner
================================
fixture       : ${FIXTURE}   (${FIXTURE_PATH})
duration      : ${DURATION_MIN} minutes
cadence       : ${CADENCE}
cache_ttl     : ${CACHE_TTL}
inject_at     : ${INJECT_AT:-<none>}
inject_fixt   : ${INJECT_FIXTURE:-<none>}
output_dir    : ${OUTPUT_DIR}

would-produce:
  ${OUTPUT_DIR}/gate.jsonl
  ${OUTPUT_DIR}/session.jsonl
  ${OUTPUT_DIR}/joined.csv
  ${OUTPUT_DIR}/report.md
EOF

if [[ "$EXECUTE" -eq 0 ]]; then
  cat <<EOF

mode          : DRY-RUN (default)
would run     : a ${CADENCE}-cadence /loop against fixture '${FIXTURE}' for
                ${DURATION_MIN} min, configured for cache_control ttl=${CACHE_TTL},
                tee'ing gate-log records to ${OUTPUT_DIR}/gate.jsonl, then
                running analyze-gate-log.py to emit report.md.

re-run with --execute to actually run (currently stubbed; see below).
EOF
  exit 0
fi

# --execute path — STUBBED until Phase 2.0 PostSessionEnd hook probe resolves.
echo "TODO: actual execution requires PostSessionEnd hook verification per Phase 2.0"
exit 2
