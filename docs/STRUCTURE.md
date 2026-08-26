# Repository Structure

Full annotated directory tree. For a quick summary see the [README](../README.md#repository-structure).

```
agents/
├── .agent/                              # Antigravity agent configuration (rules, workflows)
├── .claude-plugin/                      # Claude Code plugin configuration
├── .factory/                            # Droid (Factory) configuration
│   ├── settings.json                    # Hooks (stop hook for continuous operation)
│   ├── skills/
│   │   ├── autocoder/                   # Droid autocoder skill + references
│   │   └── modernize/                   # Droid modernize skill + references
│   └── droids/
│       ├── architect.md                 # Specialist subagent: architecture
│       ├── coder.md                     # Specialist subagent: implementation
│       ├── documentation.md             # Specialist subagent: documentation
│       ├── migration-coordinator.md     # Specialist subagent: orchestration
│       ├── security.md                  # Specialist subagent: security
│       └── tester.md                    # Specialist subagent: testing
├── .factory-plugin/                     # Droid plugin marketplace configuration
│   ├── marketplace.json                 # Marketplace metadata (2 plugins)
│   └── plugins/
│       ├── modernize/plugin.json        # Modernize plugin definition
│       └── autocoder/plugin.json        # Autocoder plugin definition
├── codex-plugins/                       # Codex-native plugin packaging (autocoder/, modernize/)
├── .agents/                             # Codex plugin registration (plugins/ manifest)
├── plugins/                             # Plugin implementations
│   ├── modernize/                       # Modernize plugin (6 commands, 6 agents, protocols)
│   │   ├── commands/
│   │   │   ├── help.md                  # Plugin help and workflow overview
│   │   │   ├── assess.md                # Assessment protocol
│   │   │   ├── plan.md                  # Planning protocol
│   │   │   ├── modernize.md             # Full modernization workflow
│   │   │   ├── retro.md                 # Retrospective analysis
│   │   │   └── retro-apply.md           # Improvement application
│   │   ├── agents/
│   │   │   ├── architect.md             # Technology decisions and ADRs
│   │   │   ├── coder.md                 # Implementation and fixes
│   │   │   ├── documentation.md         # User-facing guides
│   │   │   ├── migration-coordinator.md # Multi-stage orchestration
│   │   │   ├── security.md              # Vulnerability scanning
│   │   │   └── tester.md                # Comprehensive testing
│   │   └── protocols/                   # Protocol documentation (10 protocols)
│   │       ├── 00-PROTOCOL-INDEX.md     # Protocol index
│   │       ├── adr-lifecycle.md         # ADR lifecycle protocol
│   │       ├── agent-logging.md         # Agent logging protocol
│   │       ├── agents-overview.md       # Agents overview
│   │       ├── documentation-plan.md    # Documentation planning
│   │       ├── documentation-protocol.md
│   │       ├── incremental-documentation.md
│   │       ├── protocols-overview.md    # Protocols overview
│   │       ├── security-scanning-protocol.md
│   │       └── testing-protocol.md      # Testing protocol
│   └── autocoder/                       # Autocoder plugin (12 commands)
│       ├── commands/
│       │   ├── help.md                  # Plugin help and workflow overview
│       │   ├── fix.md                   # Autonomous issue resolution
│       │   ├── fix-loop.md              # Continuous autonomous resolution
│       │   ├── stop-loop.md             # Stop the continuous loop
│       │   ├── list-proposals.md        # View pending proposals
│       │   ├── approve-proposal.md      # Approve a proposal
│       │   ├── list-needs-design.md     # List issues needing design
│       │   ├── list-needs-feedback.md   # List issues needing feedback
│       │   ├── brainstorm-issue.md      # Brainstorm design for an issue
│       │   ├── full-regression-test.md  # Run comprehensive test suite
│       │   ├── improve-test-coverage.md # Analyze and improve coverage
│       │   ├── review-blocked.md        # Review and unblock labeled issues
│       │   ├── monitor-workers.md       # Monitor workers, dispatch idle agents, deploy
│       │   └── install.md               # Install all plugin components
│       ├── agents/
│       │   ├── architect.md             # Technology decisions and ADRs
│       │   ├── coder.md                 # Implementation and fixes
│       │   ├── documentation.md         # User-facing guides
│       │   ├── migration-coordinator.md # Multi-stage orchestration
│       │   ├── security.md              # Vulnerability scanning
│       │   └── tester.md                # Comprehensive testing
│       └── scripts/
│           ├── claude-worker-loop.sh    # Fresh Claude process per issue (clean context)
│           ├── issue-metrics.py         # Tokens/time/cost per issue from worker transcripts
│           ├── post-issue-metrics.sh    # Comment those metrics onto the issue (idempotent)
│           ├── start-parallel-agents.sh # Launch manager + N worker panes (tmux/cmux)
│           ├── join-parallel-agents.sh  # Attach to an existing swarm session
│           ├── end-parallel-agents.sh   # Tear down the swarm
│           ├── add-worker.sh            # Add a worker to a running swarm
│           ├── remove-worker.sh         # Remove a worker from a running swarm
│           ├── restart-worker.sh        # Restart an unhealthy worker
│           ├── start-issue-work.sh      # Atomic issue claim + branch setup (Codex)
│           ├── worker-launch-lib.sh     # Per-agent launch/loop configuration
│           ├── worker-health.sh         # Worker liveness checks for manager
│           ├── swarm-manifest-lib.sh    # Swarm state tracking
│           ├── issue-fns.sh             # issue_claim / issue_release / issue_update wrappers
│           ├── issue-source-lib.sh      # Issue backend detection (file/github/jira/ado)
│           ├── issues-file.py           # File-backend issue store
│           ├── issues-gh.sh             # GitHub-backend issue store
│           ├── issues-jira.sh           # Jira-backend issue store
│           ├── issues-ado.sh            # Azure DevOps-backend issue store
│           ├── merge-to-integration.sh  # Land worktree work on shared integration branch
│           ├── regression-test.sh       # Full test suite with GitHub integration
│           ├── fetch-blocked-issues.sh  # List blocked/needs-review issues
│           ├── add-blocking-label.sh    # Label an issue as blocked
│           ├── approve-blocked-issue.sh # Approve a blocked issue
│           └── reject-blocked-issue.sh  # Reject a blocked issue
├── skills/
│   ├── autocoder/                       # Codex/Gemini-native autocoder skill
│   ├── modernize/                       # Codex/Gemini-native modernize skill
│   └── improve/                         # Platform-neutral improve skill (all platforms)
│       └── SKILL.md                     # Validation & refinement loop protocol
├── docs/                                # Documentation
│   ├── STRUCTURE.md                     # This file
│   ├── CLAUDE-CODE.md                   # Claude Code platform guide
│   ├── ANTIGRAVITY.md                   # Antigravity/Gemini platform guide
│   ├── CODEX.md                         # Codex platform guide
│   ├── DROID.md                         # Droid platform guide
│   ├── jira-setup.md                    # Jira backend setup
│   ├── ado-setup.md                     # Azure DevOps backend setup
│   └── swarm-quickstart-{claude,gemini,codex,droid}.md
├── tests/                               # Test suites
│   ├── test_*.sh                        # Shell tests
│   └── fixtures/                        # Stateful fake servers (Jira, ADO)
├── scripts/                             # Top-level install and alias scripts
└── README.md
```

**Architecture notes:**

- Each plugin (`modernize`, `autocoder`) has its own `commands/`, `agents/`, and `scripts/` — fully independent, can be installed individually.
- Both plugins share the same 6 specialist agents (architect, coder, documentation, migration-coordinator, security, tester).
- Per-platform directories (`.agent/`, `.factory/`, `codex-plugins/`, `.agents/`) mirror the Claude Code `plugins/` content for their respective agent CLIs.
- `skills/improve/` is platform-neutral — it ships once and is referenced by all platforms.
