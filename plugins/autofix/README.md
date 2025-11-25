# Autofix Plugin

Autonomous issue resolution plugin for Claude Code. Analyzes, prioritizes, and systematically fixes issues from project management systems.

## Commands

### `/fix-github`

Autonomous GitHub issue resolver that:

1. Sets up priority labels (P0-P3) on first run
2. Fetches open issues with priority labels
3. Processes issues from highest to lowest priority
4. Uses appropriate strategy based on complexity:
   - **Simple issues**: Direct fix
   - **Complex issues**: Superpowers skills (systematic-debugging, brainstorming, etc.)
5. Commits fixes and closes issues with detailed explanations
6. When no priority issues remain, runs regression tests and creates issues for failures

**Requirements**: GitHub CLI (`gh`) authenticated with repo access.

## Extending to Other Systems

The `/fix-github` command is a reference implementation for GitHub Issues. Similar commands can be created for other project management systems:

- **Jira**: `/fix-jira` - Use Jira REST API or CLI
- **Linear**: `/fix-linear` - Use Linear GraphQL API
- **Azure DevOps**: `/fix-azdo` - Use Azure CLI
- **GitLab**: `/fix-gitlab` - Use GitLab CLI (`glab`)
- **Shortcut**: `/fix-shortcut` - Use Shortcut API

### Creating a New Integration

To add support for another system, create a new command file (e.g., `commands/fix-jira.md`) that:

1. **Authenticates** with the system's API/CLI
2. **Fetches issues** filtered by priority or status
3. **Sorts by priority** (map system's priority scheme to P0-P3)
4. **Creates work branches** for each issue
5. **Posts progress updates** to the issue
6. **Closes issues** with resolution details

The core fix logic (complexity detection, superpowers integration, verification) can be reused across integrations.

## Configuration

The command reads project-specific configuration from `CLAUDE.md`:

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

If no configuration exists, defaults are used and a template is added to `CLAUDE.md`.

## Files Created

- `.github/.priority-labels-configured` - Sentinel file indicating labels are set up (created once per project)
