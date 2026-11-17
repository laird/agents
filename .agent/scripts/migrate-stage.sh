#!/bin/bash
# migrate-stage.sh - Execute a migration stage
#
# Usage: ./scripts/migrate-stage.sh <stage_number> <stage_name> [pattern]
#
# Orchestrates the migration of a specific stage, including validation.

set -e

STAGE_NUM="${1:?Stage number required}"
STAGE_NAME="${2:?Stage name required}"
PATTERN="${3:-}"

echo "=============================================="
echo "  Migration Stage $STAGE_NUM: $STAGE_NAME"
echo "=============================================="
echo ""
echo "Pattern: ${PATTERN:-<all>}"
echo "Started: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

# Step 1: Pre-migration validation
echo "--- Step 1: Pre-migration Validation ---"
./scripts/run-stage-tests.sh "$STAGE_NUM" "$STAGE_NAME" lenient || {
    echo "Warning: Pre-migration tests have failures"
}

# Step 2: Migration (placeholder - actual migration is done by agents)
echo ""
echo "--- Step 2: Migration ---"
echo "Migration for stage $STAGE_NUM should be performed by the appropriate agent."
echo "This script validates the stage before and after migration."

# Step 3: Post-migration validation
echo ""
echo "--- Step 3: Post-migration Validation ---"
./scripts/validate-migration-stage.sh "$STAGE_NUM" "$STAGE_NAME" || {
    echo ""
    echo "Stage $STAGE_NUM validation failed."
    echo "Please review and fix issues before proceeding."
    exit 1
}

# Step 4: Log completion
echo ""
echo "--- Step 4: Logging ---"
if [ -x "./scripts/append-to-history.sh" ]; then
    ./scripts/append-to-history.sh \
        "Migration Stage $STAGE_NUM: $STAGE_NAME Complete" \
        "Migrated ${PATTERN:-all components} for stage $STAGE_NUM" \
        "Part of systematic migration process" \
        "Stage $STAGE_NUM ready for next phase"
fi

echo ""
echo "=============================================="
echo "  Stage $STAGE_NUM: $STAGE_NAME COMPLETE"
echo "=============================================="
