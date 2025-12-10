---
description: Create a detailed modernization plan
---

# Modernization Planning Workflow

This workflow orchestrates the **Migration Coordinator** and **Architect** to create a detailed execution plan.

1. **Review Assessment**
    Read `ASSESSMENT.md` to understand the project status, risks, and recommendations.

2. **Define Migration Strategy**
    Switch to **Migration Coordinator**:
    - Select a phasing strategy (Bottom-Up, Top-Down, or Risk-Based).
    - Define 4-8 distinct migration phases (e.g., Preparation, Security, Framework, API, Verification).
    - Estimate duration and resource requirements for each phase.

3. **Refine Technical Approach**
    Switch to **Architect**:
    - Identify key architectural decisions (ADRs) needed for each phase.
    - Validate feasibility of the proposed phasing.
    - Define technical milestones and quality gates.

4. **Generate Plan Document**
    Switch to **Documentation**:
    - Create `PLAN.md` file.
    - Include: Executive Summary, Phasing Schedule, Resource Plan, and Risk Mitigation Strategy.
