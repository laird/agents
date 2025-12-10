---
description: Analyze project for modernization readiness
---

# Project Assessment Workflow

This workflow orchestrates the **Architect**, **Security**, and **Documentation** agents to assess the project.

1. **Project Discovery**
    Run the following commands to gather project statistics:

    ```bash
    # Count lines of code
    bash -c 'find . -name "*.cs" -o -name "*.js" -o -name "*.py" -o -name "*.java" | xargs wc -l'
    
    # Check git history
    bash -c 'git log --reverse --format="%ai" | head -1'
    bash -c 'git log --format="%ai" | head -1'
    bash -c 'git shortlog -sn | head -10'
    ```

2. **Security Assessment**
    Switch to the **Security** rule:
    - Run dependency vulnerability scans (npm audit, dotnet list package --vulnerable, pip-audit).
    - Identify CRITICAL and HIGH severity issues.
    - Calculate a preliminary Security Score (0-100).

3. **Technical & Architecture Assessment**
    Switch to the **Architect** rule:
    - Identify current vs target framework versions.
    - Analyze dependency health (outdated/deprecated packages).
    - Review code structure and patterns.
    - Document technical risks and viability.

4. **Generate Assessment Report**
    Switch to the **Documentation** rule:
    - Consolidate findings from Security and Architect.
    - Create `ASSESSMENT.md` following the template.
    - Include: Executive Summary, Technical Viability, Risk Profile, and Recommendation (GO/NO-GO).
