# /fix reference: first-run merge mode setup

Moved out of the `/fix` command file (#240) because a worker rarely needs it.
The command keeps a pointer at each place this text used to be.

## First-Run: Configure Merge Mode

When `MERGE_MODE_NOT_CONFIGURED=true` is detected in the output of the `/fix` configuration block, you **MUST** prompt the user before proceeding:

1. Use AskUserQuestion to ask: *"How should completed issues be integrated? Options: **merge** (auto-merge feature branch to parent and push — fully autonomous) or **pr** (push feature branch and create a pull request for human review). Enter 'merge' or 'pr':"*
2. Set `MERGE_MODE` to the user's response (default to `merge` if unclear).
3. Append the setting to the project's GEMINI.md (or AGENTS.md if it exists) so it persists:

```bash
cat >> GEMINI.md << MERGE_MODE_CONFIG

### Merge Mode
\`\`\`
${MERGE_MODE}
\`\`\`
Options: \`merge\` (auto-merge to parent branch and push) or \`pr\` (push feature branch and create a pull request, then stop).
MERGE_MODE_CONFIG
echo "✅ Saved merge mode '$MERGE_MODE' to GEMINI.md"
```

4. Commit the GEMINI.md change so all agents share the setting.
