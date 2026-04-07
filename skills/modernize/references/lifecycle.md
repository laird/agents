# Lifecycle

## Standard Flow

1. Assess modernization viability and write `ASSESSMENT.md`.
2. Create `PLAN.md` with phases, risks, and resource allocation.
3. Execute the modernization with specialist coordination and gate checks.
4. Run a retrospective and write improvement recommendations.
5. Apply approved improvements to the workflow itself.

## Specialist Roles

- Coordinator: orchestration, progress, escalation, gate ownership
- Security: vulnerability scanning and remediation
- Architect: ADRs and target-state decisions
- Coder: implementation and migration changes
- Tester: stage testing and validation
- Documentation: incremental documentation and release artifacts

## Execution Notes

- The quality gates are part of the product, not optional guidance.
- Prefer reusing existing protocol docs and scripts over duplicating detailed phase procedures in skill bodies.
- Replace Claude-specific slash-command language with direct task phrasing when executing the workflow.
