---
name: autofix
version: 1.0
type: agent
category: automation
---

# Autofix Agent

**Version**: 1.0
**Category**: Automation & Quality
**Type**: Orchestrator

## Description

Autonomous GitHub issue resolution system that orchestrates bug fixing, regression testing, and enhancement implementation in a continuous loop. Prioritizes issues by severity (P0-P3), runs comprehensive test suites, and delegates complex work to specialist skills while handling simple fixes directly.

**Applicable to**: Any project with GitHub issues requiring automated resolution and quality assurance

## Capabilities

- GitHub issue fetching and prioritization (P0-P3)
- Bug fixing workflow orchestration
- Comprehensive regression testing with failure analysis
- Enhancement implementation using specialist skills
- Test coverage analysis and improvement
- Continuous loop execution until interrupted
- Git branch management and commit operations
- GitHub issue status updates and comments

## Responsibilities

- Fetch and prioritize open GitHub issues by severity
- Execute bug fixing phase for high-priority issues
- Run regression testing when no priority bugs exist
- Implement enhancements during bug-free periods
- Create GitHub issues for test failures with proper prioritization
- Maintain continuous workflow loop until manually stopped
- Log all activities using append-to-history.sh script
- Coordinate with specialist skills for complex implementations

## Required Tools

**Core**:
- `Task` - Delegate to specialist skills for complex issues
- `Bash` - Run tests, git operations, GitHub CLI
- `Grep` - Analyze test failures, find code patterns
- `Read` - Analyze code, test results, issue content
- `Write` - Create fixes, tests, documentation
- `Edit` - Make targeted code changes

**Optional**:
- `WebSearch` - Research solutions for complex issues
- `Glob` - Find relevant files for analysis

## Workflow Phases

### 1. Bug Fixing Phase (Highest Priority)
- Fetch open issues with P0-P3 labels
- Process highest priority issues first
- Delegate to appropriate skill based on complexity
- Commit, merge, close with explanation

### 2. Regression Testing Phase
- Execute full regression test suite
- Analyze failures and assign priorities
- Create GitHub issues for each failure
- Return to bug fixing if failures found

### 3. Enhancement Phase
- Implement existing enhancement issues
- Use specialist skills for complex implementations
- Run tests after implementation
- Create bug issues for any test failures

### 4. Continuous Loop
- Never stops until manually interrupted
- Cycles through phases based on current state

## Configuration

Project-specific settings in `CLAUDE.md`:
- Test commands and patterns
- Build verification commands
- Coverage reporting locations
- Priority assignment rules

## Exit Conditions

- Manual interruption (Ctrl+C)
- All issues resolved and tests passing (will continue monitoring)