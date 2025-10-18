# Quick Install Guide - Claude Code Plugins

## One-Line Install

### Complete Suite (Recommended)
```bash
claude plugin install github:laird/agents#agent-protocols-complete
```

### Individual Plugins
```bash
# SPARC Workflow
claude plugin install github:laird/agents#sparc-workflow

# Testing Framework
claude plugin install github:laird/agents#testing-framework

# Documentation System
claude plugin install github:laird/agents#documentation-system

# Security Scanner
claude plugin install github:laird/agents#security-scanner

# Architecture Advisor
claude plugin install github:laird/agents#architecture-advisor
```

## Quick Commands

### SPARC Workflow
```bash
/sparc-modes                          # List available modes
/sparc-tdd "feature description"      # Run TDD workflow
/sparc-pipeline "task description"    # Full pipeline
```

### Agent Spawning
```bash
# Coordinator
claude agent spawn migration-coordinator --task "your task"

# Architect
claude agent spawn architect-agent --task "research and create ADR"

# Coder
claude agent spawn coder-agent --task "implement feature"

# Tester
claude agent spawn tester-agent --criteria "pass_rate >= 95%"

# Documentation
claude agent spawn documentation-agent --task "create guide"

# Security
claude agent spawn security-agent --task "vulnerability scan"
```

### Automation Scripts
```bash
# Log to HISTORY.md
./scripts/append-to-history.sh "Title" "What" "Why" "Impact"

# Capture test baseline
./scripts/capture-test-baseline.sh

# Run stage tests
./scripts/run-stage-tests.sh stage-1

# Validate stage
./scripts/validate-migration-stage.sh stage-1
```

## Marketplace Access
```bash
# Add marketplace
claude marketplace add github:laird/agents

# Browse plugins
claude plugin browse agent-protocols-marketplace

# Update plugins
claude plugin update --all
```

## More Info

- **Full Guide**: `docs/PLUGIN-INSTALLATION.md`
- **Summary**: `docs/MARKETPLACE-SUMMARY.md`
- **Protocols**: `00-PROTOCOL-INDEX.md`
