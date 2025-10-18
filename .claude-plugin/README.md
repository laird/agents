# Claude Code Plugin Marketplace

This directory contains the Claude Code plugin marketplace configuration for the Agent Protocols repository.

## Structure

```
.claude-plugin/
├── marketplace.json              # Marketplace manifest
├── README.md                     # This file
└── plugins/                      # Individual plugin manifests
    ├── agent-protocols/          # Complete protocols suite
    │   └── plugin.json
    ├── sparc-workflow/           # SPARC methodology
    │   └── plugin.json
    ├── testing-framework/        # Testing protocols
    │   └── plugin.json
    ├── documentation-system/     # Documentation framework
    │   └── plugin.json
    ├── security-scanner/         # Security assessment
    │   └── plugin.json
    └── architecture-advisor/     # Architecture decisions
        └── plugin.json
```

## Marketplace Configuration

The `marketplace.json` defines:

- **Marketplace metadata**: Name, version, description, owner
- **Plugin catalog**: 6 specialized plugins
- **Categories**: Workflow, Testing, Documentation, Security, Architecture
- **Keywords**: For discovery and search

## Plugin Manifests

Each `plugin.json` includes:

- **Plugin metadata**: Name, version, description, author
- **Components**: Agents, protocols, scripts, commands, hooks
- **Features**: Capabilities and requirements
- **Dependencies**: Required tools and versions

## Installation

### Add Marketplace

```bash
# Add this marketplace to Claude Code
claude marketplace add github:laird/agents

# Browse available plugins
claude plugin browse agent-protocols-marketplace
```

### Install Plugins

```bash
# Install complete suite
claude plugin install github:laird/agents#agent-protocols-complete

# Install individual plugins
claude plugin install github:laird/agents#sparc-workflow
claude plugin install github:laird/agents#testing-framework
claude plugin install github:laird/agents#documentation-system
claude plugin install github:laird/agents#security-scanner
claude plugin install github:laird/agents#architecture-advisor
```

### Local Installation

```bash
# From repository root
claude plugin install ./.claude-plugin/plugins/agent-protocols
claude plugin install ./.claude-plugin/plugins/sparc-workflow
# etc.
```

## Available Plugins

### 1. Agent Protocols Complete (`agent-protocols-complete`)
- **Type**: Complete suite
- **Components**: 6 agents, 9 protocols, 5 scripts
- **Category**: Workflow & Orchestration
- **Use for**: Full systematic development framework

### 2. SPARC Workflow (`sparc-workflow`)
- **Type**: Methodology plugin
- **Components**: 5 slash commands, SPARC framework
- **Category**: Workflow & Orchestration
- **Use for**: Specification → Architecture → Implementation

### 3. Testing Framework (`testing-framework`)
- **Type**: QA plugin
- **Components**: Tester agent, 3 scripts, testing protocol
- **Category**: Testing & Quality Assurance
- **Use for**: Comprehensive testing with quality gates

### 4. Documentation System (`documentation-system`)
- **Type**: Documentation plugin
- **Components**: Documentation agent, 4 protocols, logging script
- **Category**: Documentation Systems
- **Use for**: HISTORY.md, ADRs, CHANGELOGs, guides

### 5. Security Scanner (`security-scanner`)
- **Type**: Security plugin
- **Components**: Security agent, CVE scanning
- **Category**: Security & Compliance
- **Use for**: Vulnerability scanning and remediation

### 6. Architecture Advisor (`architecture-advisor`)
- **Type**: Architecture plugin
- **Components**: Architect agent, ADR lifecycle
- **Category**: Architecture & Design
- **Use for**: Technology research and decision documentation

## Plugin Features

### Multi-Agent Coordination
- Hierarchical coordination (Migration Coordinator)
- Parallel execution (Multiple Coder agents)
- Sequential pipelines (Security → Development → Testing → Documentation)

### Quality Gates
- Test pass rate ≥95% (Unit), ≥90% (Integration)
- Security score ≥45
- Build success 100%
- CRITICAL/HIGH vulnerability blocking

### Automation
- HISTORY.md logging (append-to-history.sh)
- Test baseline tracking (capture-test-baseline.sh)
- Stage validation (validate-migration-stage.sh)
- Dependency analysis (analyze-dependencies.sh)

### Documentation
- 7 logging templates
- 7-stage ADR lifecycle
- Incremental documentation protocol
- Automated CHANGELOG and guide generation

## Requirements

- **Claude Code**: ≥2.0.0
- **npm**: ≥8.0.0 (for SPARC workflow)
- **Git**: For repository installations
- **claude-flow**: For multi-agent orchestration (optional)

## Validation

To validate marketplace structure:

```bash
# Check JSON syntax
jq . marketplace.json
jq . plugins/*/plugin.json

# Verify plugin references
ls -la plugins/*/plugin.json

# Test agent YAML references
ls -la ../generic-*-agent.yaml
```

## Customization

### Create Custom Plugin

1. Create plugin directory:
```bash
mkdir -p .claude-plugin/plugins/my-custom-plugin
```

2. Create `plugin.json`:
```json
{
  "name": "my-custom-plugin",
  "version": "1.0.0",
  "description": "My custom plugin",
  "author": { "name": "Your Name" },
  "agents": [...],
  "protocols": [...],
  "commands": [...]
}
```

3. Add to marketplace.json:
```json
{
  "plugins": [
    {
      "name": "my-custom-plugin",
      "source": "./plugins/my-custom-plugin",
      "description": "...",
      "category": "..."
    }
  ]
}
```

## Support

- **Installation Guide**: See `docs/PLUGIN-INSTALLATION.md`
- **Protocol Index**: See `00-PROTOCOL-INDEX.md`
- **Issues**: https://github.com/laird/agents/issues
- **Validation**: See `VALIDATION-REPORT.md`

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 2.0.0 | 2025-10-18 | Initial Claude Code plugin marketplace |

## License

MIT - See LICENSE file for details
