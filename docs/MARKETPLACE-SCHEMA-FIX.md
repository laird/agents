# Claude Code Plugin Marketplace Schema Fix

## Issue Summary

The plugin marketplace configuration was using the `displayName` field in both `marketplace.json` and individual `plugin.json` files, which is **not part of the official Claude Code plugin schema**. This caused validation errors when trying to use the repository as a Claude Code marketplace.

## Error Message

```
Invalid schema: plugins.0: Unrecognized key(s) in object: 'displayName',
plugins.1: Unrecognized key(s) in object: 'displayName', plugins.2:
Unrecognized key(s) in object: 'displayName', plugins.3: Unrecognized key(s)
in object: 'displayName', plugins.4: Unrecognized key(s) in object:
'displayName', plugins.5: Unrecognized key(s) in object: 'displayName'
```

## Root Cause

The `displayName` field is not a recognized field in the Claude Code plugin manifest schema. While it may seem intuitive to have a display name separate from the technical name, the official schema only supports these fields:

### Standard Plugin Manifest Fields

- `name` - Plugin identifier (required)
- `version` - Version number (e.g., "2.0.0")
- `description` - Brief plugin description (this serves as the display name)
- `author` - Author object with name, email, and url
- `homepage` - Plugin documentation URL
- `repository` - GitHub or git repository URL (must be string, not object)
- `license` - License type (e.g., "MIT")
- `keywords` - Array of searchable terms
- `commands` - Custom command paths
- `agents` - Custom agent paths
- `hooks` - Hook configuration file path
- `mcpServers` - MCP server configuration path

### Marketplace-Specific Fields

- `source` - Plugin location path
- `category` - Plugin category for organization
- `tags` - Tags for discovery
- `strict` - Whether plugin.json is required (default: true)

## Solution

### Changes Made

1. **Removed all `displayName` fields** from:
   - `.claude-plugin/marketplace.json`
   - All 6 plugin manifest files in `.claude-plugin/plugins/*/plugin.json`

2. **Simplified plugin.json files** to only include standard schema fields:
   - Removed custom fields: `protocols`, `scripts`, `features`, `requirements`
   - Fixed `repository` to be a string instead of an object
   - Kept only: `name`, `version`, `description`, `author`, `homepage`, `repository`, `license`, `keywords`, `commands`

3. **Updated documentation**:
   - Added "Claude Code Plugin Marketplace" section to README.md
   - Documented the schema fix and solution
   - Provided installation instructions
   - Listed all available plugins with categories

### Example: Before and After

**Before (Invalid):**
```json
{
  "name": "agent-protocols-complete",
  "displayName": "Complete Agent Protocols Suite",
  "version": "2.0.0",
  "repository": {
    "type": "git",
    "url": "https://github.com/laird/agents"
  },
  "protocols": [...],
  "scripts": [...],
  "features": {...}
}
```

**After (Valid):**
```json
{
  "name": "agent-protocols-complete",
  "version": "2.0.0",
  "description": "Complete suite of 9 production-validated protocols, 6 specialized agents, and 5 automation scripts for systematic software development",
  "author": {
    "name": "Agent Protocols Team",
    "email": "[email protected]"
  },
  "homepage": "https://github.com/laird/agents",
  "repository": "https://github.com/laird/agents",
  "license": "MIT",
  "keywords": [
    "protocols",
    "agents",
    "automation",
    "testing",
    "documentation",
    "migration",
    "sparc",
    "multi-agent"
  ]
}
```

## Validation Results

After the fix, all manifests pass validation:

```bash
$ claude plugin validate .claude-plugin/marketplace.json
✔ Validation passed with warnings

$ for plugin in .claude-plugin/plugins/*/plugin.json; do
    claude plugin validate "$plugin"
  done
✔ Validation passed with warnings
✔ Validation passed with warnings
✔ Validation passed with warnings
✔ Validation passed with warnings
✔ Validation passed with warnings
✔ Validation passed with warnings
```

## Testing from GitHub

The marketplace was successfully tested from GitHub:

```bash
# Add marketplace from GitHub
$ claude plugin marketplace add "https://raw.githubusercontent.com/laird/agents/master/.claude-plugin/marketplace.json"
✔ Successfully added marketplace: agent-protocols-marketplace

# List marketplaces
$ claude plugin marketplace list
Configured marketplaces:
  ❯ agent-protocols-marketplace
    Source: URL (https://raw.githubusercontent.com/laird/agents/master/.claude-plugin/marketplace.json)

# Update marketplace
$ claude plugin marketplace update agent-protocols-marketplace
✔ Successfully updated marketplace: agent-protocols-marketplace
```

## Installation Instructions

Users can now install plugins from this marketplace:

```bash
# Add the marketplace
claude plugin marketplace add "https://raw.githubusercontent.com/laird/agents/master/.claude-plugin/marketplace.json"

# Install the complete suite
claude plugin install agent-protocols-complete@agent-protocols-marketplace

# Or install individual components:
claude plugin install sparc-workflow@agent-protocols-marketplace
claude plugin install testing-framework@agent-protocols-marketplace
claude plugin install documentation-system@agent-protocols-marketplace
claude plugin install security-scanner@agent-protocols-marketplace
claude plugin install architecture-advisor@agent-protocols-marketplace
```

## Key Takeaways

1. **Use `description` for human-readable names** - The `description` field serves as the display name in Claude Code
2. **Only use standard schema fields** - Custom fields are not validated and will cause errors
3. **Repository must be a string** - Use `"repository": "url"` not `"repository": {"type": "git", "url": "..."}`
4. **Use `strict: false` for flexibility** - This allows marketplace entries to serve as complete plugin manifests
5. **Always validate before publishing** - Use `claude plugin validate` to catch schema errors early

## References

- [Claude Code Plugin Marketplaces Documentation](https://docs.claude.com/en/docs/claude-code/plugin-marketplaces)
- [Claude Code Plugins Reference](https://docs.claude.com/en/docs/claude-code/plugins-reference)
- [Official Anthropic Marketplace Example](https://github.com/anthropics/claude-code/blob/main/.claude-plugin/marketplace.json)

## Version Information

- **Fix Version**: v2.1
- **Fix Date**: 2025-10-18
- **Commit**: 2a3331a - "Fix Claude Code plugin marketplace schema validation errors"
- **Files Modified**: 8 files (marketplace.json, 6 plugin.json files, README.md)
- **Lines Changed**: +103 insertions, -358 deletions

---

**Status**: ✅ Fixed and validated from GitHub
