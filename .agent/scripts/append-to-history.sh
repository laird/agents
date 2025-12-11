#!/bin/bash
# append-to-history.sh - Universal history logging for .NET projects

HISTORY_FILE="docs/HISTORY.md"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

# Create HISTORY.md if it doesn't exist
if [ ! -f "$HISTORY_FILE" ]; then
    mkdir -p docs
    echo "# Project History" > "$HISTORY_FILE"
    echo "" >> "$HISTORY_FILE"
    echo "This file tracks all significant changes, migrations, and decisions." >> "$HISTORY_FILE"
    echo "" >> "$HISTORY_FILE"
fi

# Validate parameters
if [ $# -ne 4 ]; then
    echo "Error: Requires exactly 4 parameters"
    echo "Usage: $0 \"TITLE\" \"WHAT_CHANGED\" \"WHY_CHANGED\" \"IMPACT\""
    exit 1
fi

# Append entry
cat >> "$HISTORY_FILE" << EOF

---

## $TIMESTAMP - $1

**What Changed**: $2

**Why Changed**: $3

**Impact**: $4

EOF

echo "✅ Entry added to $HISTORY_FILE"
