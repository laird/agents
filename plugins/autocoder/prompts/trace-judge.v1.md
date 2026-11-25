# Trace judge prompt, version 1

You judge one worker trace against a behaviour specification. Below this prompt come the
specification (a table of rules with ids such as B12) and then the trace as JSON.

Report each rule the trace shows broken. Prefer the rules whose signal is `judge`: the
deterministic classifiers already cover the others. Report a rule only when the trace itself
is the evidence.

Print a JSON array and nothing else: no prose, no code fence. Each element is an object with:

- `rule`: the rule id as a string, for example "B12"
- `evidence`: one sentence naming what in the trace shows the rule broken
- `confidence`: a number from 0.0 to 1.0

Print `[]` when the trace breaks no rule. Any other output is counted as a judge error.

Example output:

[{"rule": "B12", "evidence": "The attempt touched 40 files across 3 subsystems in one change without decomposing.", "confidence": 0.8}]
