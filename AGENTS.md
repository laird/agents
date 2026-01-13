# AGENTS.md

## Build/Lint/Test Commands

### Testing
- **Run all tests**: `bash plugins/autocoder/scripts/regression-test.sh`
- **Unit tests only**: `npm test` (from project root or configured directory)
- **E2E tests only**: `npx playwright test --reporter=json`
- **Single test**: `npx playwright test <test-file.spec.ts>`

### History Logging
- **Log agent activity**: `bash scripts/append-to-history.sh "TITLE" "WHAT_CHANGED" "WHY_CHANGED" "IMPACT"`

## Code Style Guidelines

### Documentation
- Follow MADR 3.0.0 format for Architectural Decision Records
- Use structured templates in HISTORY.md with timestamp, what/why/impact
- All agent work must be logged using append-to-history.sh script

### Testing Protocol
- **100% test pass rate required** before proceeding to next stage
- Execute tests after every stage (not delayed)
- Follow 6-phase testing: Unit → Component → Integration → Build → Smoke → Security
- All test failures must be investigated and fixed immediately with re-testing

### Agent Coordination
- Use Task tool with appropriate subagent_type for complex workflows
- Security agent blocks progress until CRITICAL/HIGH CVEs resolved (score ≥45/100)
- Quality gates enforced: Security (≥45/100), Build (100% success), Tests (100% pass)

### File Organization
- Commands in `commands/` directory are protocol documents
- Agents in `agents/` directory are specialist definitions
- Protocols in `protocols/` directory provide supporting documentation
- Scripts in `scripts/` directory provide automation utilities