# Autocoder Plugin Help

The **Autocoder** plugin provides autonomous GitHub issue resolution with intelligent testing, proposal management, and continuous quality improvement.

## Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                    AUTOCODER WORKFLOW                           │
│                                                                 │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐      │
│  │  ISSUES      │    │  DESIGN      │    │  PROPOSALS   │      │
│  │              │    │              │    │              │      │
│  │ /fix  │    │ /brainstorm  │    │ /list-       │      │
│  │ /fix  │    │   -issue     │    │  proposals   │      │
│  │   -loop      │    │              │    │ /approve-    │      │
│  │ /stop-loop   │    │ /list-needs  │    │  proposal    │      │
│  │              │    │   -design    │    │              │      │
│  └──────────────┘    │ /list-needs  │    └──────────────┘      │
│                      │   -feedback  │                          │
│  ┌──────────────┐    └──────────────┘                          │
│  │  TESTING     │                                              │
│  │              │                                              │
│  │ /full-       │                                              │
│  │  regression  │                                              │
│  │   -test      │                                              │
│  │ /improve-    │                                              │
│  │  test-       │                                              │
│  │  coverage    │                                              │
│  └──────────────┘                                              │
└─────────────────────────────────────────────────────────────────┘
```

## Commands by Category

### Issue Resolution

| Command | Purpose |
|---------|---------|
| `/fix` | Fix a single issue or start autonomous resolution |
| `/fix-loop` | Run continuous issue resolution (with sleep between cycles) |
| `/review-blocked` | Interactive review of blocked issues (run in parallel with fix-loop) |
| `/stop-loop` | Stop the continuous loop |

### Design & Brainstorming

| Command | Purpose |
|---------|---------|
| `/brainstorm-issue [number]` | Brainstorm design for an issue |
| `/list-needs-design` | List issues needing design work |
| `/list-needs-feedback` | List issues needing human feedback |

### Proposal Management

| Command | Purpose |
|---------|---------|
| `/list-proposals` | List AI-generated proposals awaiting approval |
| `/approve-proposal <number>` | Approve a proposal for implementation |

### Testing & Quality

| Command | Purpose |
|---------|---------|
| `/full-regression-test` | Run comprehensive test suite |
| `/improve-test-coverage` | Analyze and improve test coverage |

### Setup

| Command | Purpose |
|---------|---------|
| `/install` | Install stop hook and parallel agent scripts (interactive setup) |

## Workflow Patterns

### Pattern 1: One-Shot Issue Resolution

```
/fix 123
```

Fixes issue #123, then stops.

### Pattern 2: Priority-Based Resolution

```
/fix
```

Finds the highest priority issue (P0→P1→P2→P3) and fixes it.

### Pattern 3: Continuous Autonomous Mode

```
/install    # First time only (approves stop hook)
/fix-loop
```

Runs continuously:
1. Triages unprioritized issues
2. Fixes bugs in priority order
3. Runs regression tests when no bugs
4. Implements approved enhancements
5. Creates proposals for new improvements
6. Sleeps when idle, then repeats

Stop with: `/stop-loop`

### Pattern 4: Design-First Workflow

```
/list-needs-design           # Find issues needing design
/brainstorm-issue 45         # Brainstorm design for issue #45
# Review brainstorming results on GitHub
gh issue edit 45 --remove-label "needs-design"  # Mark design complete
/fix 45               # Implement the designed solution
```

### Pattern 5: Proposal Review Workflow

```
/list-proposals              # See pending AI proposals
# Review proposals on GitHub
/approve-proposal 67         # Approve proposal #67
/fix                  # Implements approved proposals
```

### Pattern 6: Parallel Planning + Execution

```bash
# Terminal 1: Run fix-loop continuously
/fix-loop

# Terminal 2: Review blocked issues as they appear (non-blocking)
/review-blocked
```

When fix-loop encounters issues it can't handle (architectural decisions, unclear requirements, etc.), it adds blocking labels and continues. In a separate session, use `/review-blocked` to interactively:
1. See overview of all blocked issues by category and priority
2. Review highest priority blocked issue with 2-3 recommended approaches
3. Approve (removes blocking label), explore further, reject, or skip
4. Continue to next blocked issue

This allows continuous autonomous work while you provide guidance on complex decisions.

## Priority System

Issues are prioritized by labels:

| Priority | Description | Examples |
|----------|-------------|----------|
| **P0** | Critical | System down, data loss, security vulnerability |
| **P1** | High | Major feature broken, no workaround |
| **P2** | Medium | Feature partially broken, workaround exists |
| **P3** | Low | Minor issues, cosmetic, nice-to-have |

Unlabeled issues are triaged automatically when `/fix` runs.

## Label System

### Priority Labels
| Label | Meaning |
|-------|---------|
| `P0` | Critical priority (system down, security, data loss) |
| `P1` | High priority (major feature broken, no workaround) |
| `P2` | Medium priority (feature degraded, workaround exists) |
| `P3` | Low priority (minor issue, cosmetic) |

### Blocking Labels
These indicate why fix-loop cannot autonomously work on an issue:

| Label | When Applied | Example |
|-------|--------------|---------|
| `needs-approval` | Architectural decisions, major changes, security implications | "Should we migrate from REST to GraphQL?" |
| `needs-design` | Requirements unclear, multiple valid approaches | "Add user dashboard" (what features? layout?) |
| `needs-clarification` | Incomplete information, missing context | "Fix the bug in checkout" (which bug?) |
| `too-complex` | Beyond autonomous capability, requires deep expertise | "Refactor entire auth system" |

**Note**: Blocking labels are independent from priority. An issue can have both `P0` + `needs-design`.

### Status Labels
| Label | Meaning |
|-------|---------|
| `proposal` | AI-generated, awaiting human approval |
| `enhancement` | Feature improvement |
| `bug` | Something isn't working |
| `test-failure` | Created from test failure |
| `working` | Currently claimed by an agent (concurrency lock) |

## Issue Complexity

The plugin automatically detects issue complexity:

**Simple Issues** (direct fix):
- Single file changes
- Configuration tweaks
- Small bug fixes
- Clear, specific fixes

**Complex Issues** (uses brainstorming/planning skills if available):
- Multiple test failures (>10)
- Feature implementations
- Multi-file refactoring
- Architecture changes

## Configuration

First run of `/fix` auto-creates configuration in your `CLAUDE.md`:

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

Customize these commands for your project.

## Quick Reference

```bash
# Start fixing issues
/fix

# Fix specific issue
/fix 123

# Run continuously
/fix-loop

# Stop continuous mode
/stop-loop

# Review blocked issues (run in parallel with fix-loop)
/review-blocked

# Review proposals
/list-proposals

# Approve a proposal
/approve-proposal 45

# Find issues needing design
/list-needs-design

# Brainstorm an issue
/brainstorm-issue 67

# Find issues needing feedback
/list-needs-feedback

# Run full test suite
/full-regression-test

# Improve test coverage
/improve-test-coverage
```

## Tips

1. **Install the stop hook** before using `/fix-loop`
2. **Run `/review-blocked` in parallel** - fix-loop will add blocking labels when it needs guidance, review them separately without interrupting autonomous work
3. **Review proposals** regularly - they won't auto-implement
4. **Use labels** to control what gets worked on
5. **Customize test commands** in CLAUDE.md for your project
6. **Brainstorm first** for complex issues needing design

## See Also

- `/modernize-help` - Help for the Modernize plugin
- GitHub Labels documentation
- Project's `CLAUDE.md` for configuration
