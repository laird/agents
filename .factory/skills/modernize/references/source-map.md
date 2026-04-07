# Source Map

## Canonical Protocol Sources

- Assessment protocol: `plugins/modernize/commands/assess.md`
- Planning protocol: `plugins/modernize/commands/plan.md`
- Execution protocol: `plugins/modernize/commands/modernize.md`
- Retrospective protocol: `plugins/modernize/commands/retro.md`
- Improvement application: `plugins/modernize/commands/retro-apply.md`
- Help and overview: `plugins/modernize/commands/modernize-help.md`

## Specialist Definitions

- `plugins/modernize/agents/migration-coordinator.md`
- `plugins/modernize/agents/security.md`
- `plugins/modernize/agents/architect.md`
- `plugins/modernize/agents/coder.md`
- `plugins/modernize/agents/tester.md`
- `plugins/modernize/agents/documentation.md`

## Supporting Scripts

- `scripts/append-to-history.sh`
- `scripts/analyze-dependencies.sh`
- `scripts/capture-test-baseline.sh`
- `scripts/run-stage-tests.sh`
- `scripts/validate-migration-stage.sh`

## Quality Gates To Preserve

- Security score >= 45/100 and zero CRITICAL CVEs
- Build success at every stage
- 100% pass rate for applicable tests
- Blocking issues resolved before release
- Documentation updated as work happens
