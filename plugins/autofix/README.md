# Autofix Plugin

**Workflow orchestrator** for autonomous issue resolution. This plugin manages the process of working through issues from project management systems - it does not implement fixes itself, but delegates to other skills.

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                  Autofix Plugin                     │
│         (Workflow Orchestration Only)               │
├─────────────────────────────────────────────────────┤
│  • Fetches and prioritizes issues                   │
│  • Detects issue complexity                         │
│  • Delegates work to appropriate skills             │
│  • Manages git branches and commits                 │
│  • Updates issue status and comments                │
│  • Runs continuous loop until stopped               │
└───────────────────┬─────────────────────────────────┘
                    │ delegates to
                    ▼
┌─────────────────────────────────────────────────────┐
│              Other Skills (do the work)             │
├─────────────────────────────────────────────────────┤
│  • superpowers:systematic-debugging                 │
│  • superpowers:brainstorming                        │
│  • superpowers:writing-plans                        │
│  • superpowers:executing-plans                      │
│  • superpowers:verification-before-completion       │
│  • (direct fixes for simple issues)                 │
└─────────────────────────────────────────────────────┘
```

## Commands

### `/full-regression-test`

Run the complete regression test suite and create GitHub issues for failures:

```bash
/full-regression-test
```

**What it does:**
1. Loads test configuration from CLAUDE.md
2. Runs build verification
3. Runs unit tests
4. Runs E2E tests (if configured)
5. Analyzes failures and assigns priorities (P0-P3)
6. Creates/updates GitHub issues for each failure
7. Generates a detailed markdown report

**Use cases:**
- Standalone health check for a project
- Called by `/fix-github` when no priority bugs exist
- Pre-release validation

---

### `/fix-github [issue_number]`

Continuous GitHub issue resolver that orchestrates:

**Usage:**
```bash
# Automatic mode - processes all priority-labeled issues in order
/fix-github

# Targeted mode - work on a specific issue immediately
/fix-github 223
```

**Modes:**
- **Automatic**: Fetches all open issues with P0-P3 labels, processes highest priority first
- **Targeted**: Skips priority selection, immediately starts on the specified issue (useful for debugging a specific problem or working on issues without priority labels)

**Workflow Phases:**

1. **Bug Fixing Phase** (highest priority)
   - Creates priority labels (P0-P3) on first run
   - Fetches and prioritizes open bug issues
   - Delegates to appropriate skill based on complexity
   - Commits, merges, closes with explanation

2. **Regression Testing Phase**
   - Runs `/full-regression-test` when no priority bugs exist
   - Creates GitHub issues for test failures
   - Loops back to bug fixing if failures found

3. **Enhancement Phase** (when no bugs)
   - Implements existing enhancement issues using superpowers skills
   - Creates detailed implementation plan using superpowers:writing-plans
   - Executes plan using superpowers:executing-plans
   - Runs tests after implementation
   - Creates bug issues for any test failures (returns to bug fixing)
   - Commits and closes enhancement on success

4. **Propose New Enhancements** (lowest priority)
   - Only runs when no bugs AND no existing enhancements
   - Uses superpowers:brainstorming to identify improvements
   - Creates enhancement issues with implementation plans
   - Loops back to Enhancement Phase to implement

5. **Continuous Loop** - Never stops until manually interrupted

**Requirements**: GitHub CLI (`gh`) authenticated with repo access.

## Extending to Other Systems

The `/fix-github` command is a reference implementation. Similar commands can orchestrate issues from other systems:

| Command | System | Tool |
|---------|--------|------|
| `/fix-jira` | Jira | REST API or CLI |
| `/fix-linear` | Linear | GraphQL API |
| `/fix-azdo` | Azure DevOps | Azure CLI |
| `/fix-gitlab` | GitLab | `glab` CLI |
| `/fix-shortcut` | Shortcut | REST API |

### Creating a New Integration

Create a command file (e.g., `commands/fix-jira.md`) that handles:

1. **Authentication** with the system's API/CLI
2. **Fetching** issues filtered by priority
3. **Priority mapping** (system's scheme → P0-P3)
4. **Branch management** for each issue
5. **Status updates** to the issue tracker
6. **Closing** with resolution details
7. **Continuous loop** (never stops)

The command orchestrates; skills do the actual work.

## Configuration

Project-specific settings in `CLAUDE.md`:

```markdown
## Automated Testing & Issue Management

### Regression Test Suite
```bash
npm test
```

### Build Verification
```bash
npm run build
```
```

Defaults used if not configured.

## Files Created

- `.github/.priority-labels-configured` - Sentinel (one-time setup complete)
