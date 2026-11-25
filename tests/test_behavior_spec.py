"""BEHAVIOR.md: the rule table, its citations, and its agreement with the analyst's registry (#395).

The citation grammar tested here is the one BEHAVIOR.md's "Citations" section defines.
"""

from __future__ import annotations

import importlib.util
import re
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
PLUGIN = ROOT / "plugins" / "autocoder"
BEHAVIOR = PLUGIN / "BEHAVIOR.md"
ROW_RE = re.compile(r"^\|\s*B\d+\s*\|")
CITATION_RE = re.compile(r"^`([^`]+)`\s*(.*)$")
HEADING_RE = re.compile(r"^#{1,6}\s+(.+?)\s*$", re.M)
QUALIFIER_RE = re.compile(r"\s*\([^()]*\)$")
PLAIN_SURFACES = {"gate", "integration branch", "tool"}


def parse_rules(text: str) -> list[dict]:
    rules = []
    for line in text.splitlines():
        if ROW_RE.match(line):
            cells = [c.strip() for c in line.strip().strip("|").split("|")]
            rules.append({"id": cells[0], "rule": cells[1], "source": cells[2], "signal": cells[3]})
    return rules


def citations(rules: list[dict]) -> list[tuple[str, Path, str | None]]:
    """(rule id, cited file, heading or None for a script) for every citation, `same` resolved."""
    out, previous = [], None
    for r in rules:
        source = previous if r["source"] == "same" else r["source"]
        previous = source
        for part in source.split(";"):
            m = CITATION_RE.match(part.strip())
            assert m, f"{r['id']}: {part.strip()!r} is not `<file>` <text>"
            name, text = m.groups()
            if name.endswith((".sh", ".py")):
                out.append((r["id"], PLUGIN / "scripts" / name, None))
            elif name == "CLAUDE.md":
                out.append((r["id"], ROOT / "CLAUDE.md", text))
            elif name.endswith(".md"):
                out.append((r["id"], PLUGIN / "commands" / name, text))
            else:
                pytest.fail(f"{r['id']}: {name} is neither a command, CLAUDE.md nor a script")
    return out


def headings(path: Path) -> set[str]:
    return {QUALIFIER_RE.sub("", h) for h in HEADING_RE.findall(path.read_text())}


def uncovered(rules: list[dict], cited: set[str]) -> set[str]:
    """Rules with a trace signal that no classifier cites; judged and retired rules need none."""
    return {r["id"] for r in rules
            if r["signal"] != "judge" and not r["rule"].startswith("Retired:") and r["id"] not in cited}


def sequential(ids: list[str]) -> bool:
    return ids == [f"B{n:02d}" for n in range(1, len(ids) + 1)]


def registry():
    spec = importlib.util.spec_from_file_location("analyze_traces", PLUGIN / "scripts" / "analyze-traces.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.classifiers()


RULES = parse_rules(BEHAVIOR.read_text())
CITATIONS = citations(RULES)


def test_ids_unique_and_sequential():
    assert len(RULES) >= 12
    assert sequential([r["id"] for r in RULES])


@pytest.mark.parametrize("rule_id,path,heading", CITATIONS, ids=[f"{r}-{p.name}" for r, p, _ in CITATIONS])
def test_citation_resolves(rule_id, path, heading):
    assert path.is_file(), f"{rule_id}: {path.relative_to(ROOT)} does not exist"
    if heading is not None:
        assert heading in headings(path), f"{rule_id}: no heading {heading!r} in {path.relative_to(ROOT)}"


def test_classifiers_cite_only_rules_in_the_spec():
    spec_ids = {r["id"] for r in RULES}
    for c in registry():
        assert set(c.rules) <= spec_ids, f"{c.id} cites {set(c.rules) - spec_ids}"
        for key, rules in c.key_rules.items():
            assert set(rules) <= set(c.rules), f"{c.id}:{key} cites a rule outside the classifier's"


def test_every_rule_with_a_trace_signal_has_a_classifier():
    cited = {rule for c in registry() for rule in c.rules}
    assert uncovered(RULES, cited) == set()


def test_classifier_surfaces_resolve():
    for c in registry():
        if c.surface in PLAIN_SURFACES:
            continue
        if c.surface.startswith("scripts/"):
            assert (PLUGIN / c.surface).is_file(), c.surface
            continue
        file, sep, heading = c.surface.partition(" § ")
        assert sep and file.startswith("commands/"), f"{c.id}: surface {c.surface!r} has no known form"
        assert heading in headings(PLUGIN / file), f"{c.id}: no heading {heading!r} in {file}"


def test_grammar_on_a_synthetic_table(tmp_path):
    table = "\n".join([
        "| Id | Rule | Source | Signal |", "|---|---|---|---|",
        "| B01 | One | `fix.md` Landing the Work | a gate |",
        "| B02 | Retired: two | same | a step |",
        "| B03 | Three | `merge-to-integration.sh` anything at all; `CLAUDE.md` Landing work | judge |",
    ])
    rules = parse_rules(table)
    assert sequential([r["id"] for r in rules])
    assert [(rid, p.name, h) for rid, p, h in citations(rules)] == [
        ("B01", "fix.md", "Landing the Work"), ("B02", "fix.md", "Landing the Work"),
        ("B03", "merge-to-integration.sh", None), ("B03", "CLAUDE.md", "Landing work")]
    assert uncovered(rules, set()) == {"B01"}
    assert not sequential(["B01", "B03"])

    doc = tmp_path / "doc.md"
    doc.write_text("## Verify Before Claiming (MANDATORY)\n### Step 3b: Nudge (#7134)\n# Plain\n")
    assert headings(doc) == {"Verify Before Claiming", "Step 3b: Nudge", "Plain"}
