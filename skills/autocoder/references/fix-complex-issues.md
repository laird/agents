# /fix reference: complex issues

Moved out of the `/fix` command file (#240) because a worker rarely needs it.
The command keeps a pointer at each place this text used to be.

### Step 2B: Complex Issue - Use Superpowers (if available)

For complex issues requiring design and planning. If `SUPERPOWERS_AVAILABLE=true`, use superpowers skills. Otherwise, use direct problem-solving approaches.

**1. Systematic Debugging (if bugs)**

If the issue involves bugs or test failures:

```
# If superpowers available:
Use Skill tool: superpowers:systematic-debugging

# If superpowers NOT available:
# - Reproduce the issue and capture error output
# - Trace through code to identify root cause
# - Form and test hypotheses
# - Document findings before implementing fix
```

This will:
- Investigate root cause thoroughly
- Analyze patterns across failures
- Test hypotheses before implementing
- Ensure understanding before solutions

**2. Brainstorming (if new features)**

If the issue requires new feature design:

```
# If thorough-brainstorming available (preferred):
Use Skill tool: thorough-brainstorming

# If superpowers available (fallback):
Use Skill tool: superpowers:brainstorming

# If neither available:
# - Explore 2-3 design alternatives
# - List pros/cons for each approach
# - Identify open questions and assumptions
# - Select approach with clear rationale
```

This will:
- Explore design alternatives
- Clarify requirements through questions
- Validate assumptions
- Refine rough ideas into concrete designs

**3. Writing Plans (for implementation)**

After design is complete, create implementation plan:

```
# If thorough-writing-plans available (preferred):
Use Skill tool: thorough-writing-plans

# If superpowers available (fallback):
Use Skill tool: superpowers:writing-plans

# If neither available:
# - Break work into numbered tasks (5-15 tasks)
# - Specify exact file paths and changes for each
# - Include verification command for each task
# - Order tasks by dependency
```

This will:
- Break down into bite-sized tasks
- Specify exact file paths and changes
- Include verification steps
- Assume zero prior codebase knowledge

**4. Executing Plans**

Execute the plan in controlled batches:

```
# If superpowers available:
Use Skill tool: superpowers:executing-plans

# If superpowers NOT available:
# - Execute 3-5 tasks at a time
# - Run verification after each batch
# - Stop and reassess if verification fails
# - Track completed vs remaining tasks
```

This will:
- Load and review the plan critically
- Execute tasks in batches
- Report progress for review between batches
- Track completion systematically

**5. Verification**

Before claiming complete, verify the fix:

```
# If superpowers available:
Use Skill tool: superpowers:verification-before-completion

# If superpowers NOT available:
# - Run all verification commands
# - Capture and review output
# - Confirm success criteria are met
# - Run full test suite before committing
```

This will:
- Run verification commands
- Confirm output shows success
- Provide evidence before assertions
- Ensure tests pass before committing

## Example Workflow

### Simple Issue Example:
```
Issue #240: TypeScript compilation errors in disabled-features
→ Direct fix: Delete broken test files
→ Verify: $BUILD_COMMAND (from CLAUDE.md autocoder config)
→ Commit and close
```

### Complex Issue Example:
```
Issue #222: Review Management system broken (~30 test failures)
→ Complexity detected: >30 failures, multiple components
→ Use superpowers:systematic-debugging
  - Investigate root cause
  - Analyze test failure patterns
  - Identify common issues
→ Use thorough-brainstorming (preferred) or superpowers:brainstorming
  - Design fix approach
  - Validate assumptions
→ Use thorough-writing-plans (preferred) or superpowers:writing-plans
  - Create implementation plan
  - Break into tasks
→ Use superpowers:executing-plans
  - Execute in batches
  - Review between batches
→ Use superpowers:verification-before-completion
  - Run all tests
  - Confirm passing
→ Commit and close with evidence
```
