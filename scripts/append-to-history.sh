#!/bin/bash
# scripts/append-to-history.sh - Append migration activity to HISTORY.md
# Usage: ./scripts/append-to-history.sh "Title" "Details" "Context" "Impact"

set -e

TITLE=$1
DETAILS=$2
CONTEXT=$3
IMPACT=$4

if [ -z "$TITLE" ] || [ -z "$DETAILS" ]; then
    echo "Usage: $0 \"<title>\" \"<details>\" \"<context>\" \"<impact>\""
    echo ""
    echo "Example:"
    echo "  $0 \\"
    echo "    \"Stage 2 Complete: Core Library Migrated\" \\"
    echo "    \"Migrated RawRabbit to .NET 9.0. Updated RabbitMQ.Client...\" \\"
    echo "    \"Core is foundation for all projects\" \\"
    echo "    \"Ready for Stage 3\""
    exit 1
fi

HISTORY_FILE="docs/HISTORY.md"

# Create HISTORY.md if it doesn't exist
if [ ! -f "$HISTORY_FILE" ]; then
    mkdir -p "$(dirname "$HISTORY_FILE")"
    cat > "$HISTORY_FILE" << 'EOF'
# RawRabbit Migration History

This file contains a chronological log of all migration activities, decisions, and outcomes.

**Format**: Each entry includes timestamp, title, details, context, and impact.

---

EOF
fi

# Append entry with timestamp
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

cat >> "$HISTORY_FILE" << EOF
## $TITLE

**Timestamp**: $TIMESTAMP

**Details**: $DETAILS

**Context**: $CONTEXT

**Impact**: $IMPACT

---

EOF

echo "✅ Logged to HISTORY.md: $TITLE"
echo "   Timestamp: $TIMESTAMP"
